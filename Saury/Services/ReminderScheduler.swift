import Foundation
import UserNotifications

struct NotificationActionPayload: Codable {
    let itemID: UUID
    let action: ExpiryAction
}

/// 系统侧的通知投递（方案 §39）。这里只做三件事：把 `ReminderQueue`
/// 算出来的差额落到 UNUserNotificationCenter、注册通知按钮、维护 snooze 名额。
/// 谁该在什么时候提醒一律不由这一层决定，否则单元测试就没办法覆盖 §90 的场景。
@MainActor
final class ReminderScheduler {
    static let shared = ReminderScheduler()

    private let center = UNUserNotificationCenter.current()
    /// 本次启动注册过的按钮组；refill 只补新的，不整体替换。
    private var registeredCategories: [String: UNNotificationCategory] = [:]
    /// 上一条补排队列的任务。
    private var refillChain: Task<Void, Never>?

    private init() {}

    // MARK: - 权限

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            SauryLog.notificationFailed("申请通知权限", error)
            return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    // MARK: - 队列

    /// App 启动、场景回前台、新增/删除/编辑/处理之后各调一次（方案 §42）。
    /// 只补差额：队列里时刻没变的通知一条都不动，改日期不会牵动别的物品。
    func refillQueue(items: [ExpiryItem], now: Date = Date()) async {
        // 启动时这几处会挤在一起（种完数据、场景转前台、列表变化）。串行补，
        // 否则两个 refill 都以为队列是空的，会把同一批通知排好几遍。
        let previous = refillChain
        let current = Task {
            await previous?.value
            await self.performRefill(items: items, now: now)
        }
        refillChain = current
        await current.value
    }

    private func performRefill(items: [ExpiryItem], now: Date) async {
        ensureCategories(for: items)
        let changes = ReminderQueue.delta(
            pending: await pendingEntries(),
            desired: ReminderQueue.candidates(for: items, now: now)
        )
        if !changes.toRemove.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: changes.toRemove)
        }
        for candidate in changes.toAdd {
            await add(candidate: candidate)
        }
        await trimSnoozes()
    }

    /// 删除物品：它的到期提醒和还没响的 snooze 一起撤掉。
    func cancel(itemID: UUID) async {
        let identifiers = await pendingEntries().map(\.identifier).filter {
            NotificationIdentifier.itemID(for: $0) == itemID
        }
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    /// 一个物品最多只留一条待投递 snooze：连着推迟两次不该响两遍。
    func scheduleSnooze(for item: ExpiryItem, choice: SnoozeChoice = .tomorrow) async {
        let group = NotificationIdentifier.snoozeGroup(itemID: item.id)
        let stale = await pendingEntries().map(\.identifier).filter { $0.hasPrefix(group) }
        center.removePendingNotificationRequests(withIdentifiers: stale)

        ensureCategories(for: [item])
        let fireAt = choice.fireDate()
        let content = baseContent(for: item)
        content.body = snoozeBody(for: item, at: fireAt)
        content.userInfo[ReminderCategory.fireAtKey] = fireAt.timeIntervalSince1970
        let request = UNNotificationRequest(
            identifier: NotificationIdentifier.snooze(itemID: item.id),
            content: content,
            trigger: trigger(for: fireAt)
        )
        await add(request: request, operation: "排 snooze")
    }

    // MARK: - 单条投递

    private func add(candidate: ReminderQueue.Candidate) async {
        let content = baseContent(for: candidate.item)
        content.body = reminderBody(for: candidate.item, offset: candidate.offset)
        content.userInfo[ReminderCategory.fireAtKey] = candidate.fireAt.timeIntervalSince1970
        let request = UNNotificationRequest(
            identifier: candidate.identifier,
            content: content,
            trigger: trigger(for: candidate.fireAt)
        )
        await add(request: request, operation: "排提醒")
    }

    private func add(request: UNNotificationRequest, operation: String) async {
        do {
            try await center.add(request)
        } catch {
            SauryLog.notificationFailed(operation, error)
        }
    }

    private func baseContent(for item: ExpiryItem) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = item.name
        content.sound = .default
        content.categoryIdentifier = ReminderCategory.identifier(for: item)
        content.userInfo = [ReminderCategory.itemIDKey: item.id.uuidString]
        return content
    }

    private func trigger(for date: Date) -> UNCalendarNotificationTrigger {
        let components = ExpiryEngine.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }

    private func pendingEntries() async -> [ReminderQueue.Pending] {
        await center.pendingNotificationRequests().map { request in
            let stamp = request.content.userInfo[ReminderCategory.fireAtKey] as? TimeInterval
            return ReminderQueue.Pending(
                identifier: request.identifier,
                fireAt: stamp.map { Date(timeIntervalSince1970: $0) }
            )
        }
    }

    /// snooze 也只留最近若干条（方案 §41）：位置是普通提醒让出来的，
    /// 但真塞满时先牺牲最晚的那几条。
    private func trimSnoozes() async {
        let snoozes = await center.pendingNotificationRequests()
            .filter { NotificationIdentifier.isSnooze($0.identifier) }
            .compactMap { request -> (String, Date)? in
                guard let stamp = request.content.userInfo[ReminderCategory.fireAtKey] as? TimeInterval else { return nil }
                return (request.identifier, Date(timeIntervalSince1970: stamp))
            }
            .sorted { $0.1 < $1.1 }
        let excess = snoozes.dropFirst(ReminderQueue.snoozeCapacity).map(\.0)
        guard !excess.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: excess)
    }

    // MARK: - 文案与按钮

    /// 有价格的物品把金额放进正文，没有价格的（一盒牛奶、一本护照）不要出现「¥0.00」。
    private func reminderBody(for item: ExpiryItem, offset: Int) -> String {
        let lead = offset == 0 ? "今天到期" : "还有 \(offset.titleText) 到期"
        if item.recurrence.isRecurring {
            return item.hasPrice
                ? "\(lead)，将支出 \(item.formattedPrice)。现在决定要不要继续。"
                : "\(lead)。现在决定要不要继续。"
        }
        let advice = deadlineText(item.actionDeadline) ?? item.category.handlingNote
        return item.hasPrice ? "\(lead)（\(item.formattedPrice)）。\(advice)" : "\(lead)。\(advice)"
    }

    private func snoozeBody(for item: ExpiryItem, at date: Date) -> String {
        let when = date.qjShortDateTimeText
        let remaining = item.daysRemaining
        if remaining < 0 { return "已经过期 \(abs(remaining)) 天。你定的复查时间是 \(when)。" }
        if remaining == 0 { return "今天到期。你定的复查时间是 \(when)。" }
        return "距离到期还有 \(remaining) 天。你定的复查时间是 \(when)。"
    }

    private func deadlineText(_ deadline: Date?) -> String? {
        guard let deadline else { return nil }
        let days = ExpiryEngine.daysRemaining(to: deadline)
        guard days >= 0 else { return "已过最晚处理日，尽快处理。" }
        return days == 0 ? "今天是最晚处理日。" : "最晚要在 \(deadline.qjDateText) 前处理。"
    }

    /// 按钮集合按「动作分组 + 分类」注册，标题直接复用 App 里的那句话，
    /// 所以锁屏上的「吃完」和列表里左滑的「吃完」是同一个动作。
    /// 只增不减：已经投递出去的通知还得留着按钮。
    private func ensureCategories(for items: some Sequence<ExpiryItem>) {
        var changed = false
        for item in items {
            let identifier = ReminderCategory.identifier(for: item)
            guard registeredCategories[identifier] == nil else { continue }
            registeredCategories[identifier] = makeCategory(for: item)
            changed = true
        }
        guard changed else { return }
        center.setNotificationCategories(Set(registeredCategories.values))
    }

    private func makeCategory(for item: ExpiryItem) -> UNNotificationCategory {
        let actions = ReminderCategory.actions(for: item).map { action in
            UNNotificationAction(
                identifier: ReminderCategory.actionIdentifier(action),
                title: action.title(forCategory: item.category),
                options: [.foreground]
            )
        }
        return UNNotificationCategory(
            identifier: ReminderCategory.identifier(for: item),
            actions: actions,
            intentIdentifiers: [],
            options: []
        )
    }
}

private extension Int {
    var titleText: String {
        if self >= 24 * 60 { return "\(self / (24 * 60)) 天" }
        return "\(Swift.max(self / 60, 1)) 小时"
    }
}
