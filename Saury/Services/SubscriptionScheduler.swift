import Foundation
import UserNotifications

/// 把「应当存在的通知」变成系统里真正挂着的那几条。
///
/// 抽成协议只为了一件事：对账规则（`ReminderPlan`）能拿假件跑完全部日期边界，
/// 而不必为了验证「改金额之后旧文案会不会留着」去真点一台设备的通知中心。
/// 生产路径只有 `UserNotificationDelivery` 这一个实现。
protocol ReminderDelivery {
    /// 现在挂着的、属于订阅提醒这一族的标识。
    func pendingIdentifiers() async -> Set<String>
    /// 系统当前会不会真把通知挂起来（由授权状态决定）。
    ///
    /// 单独问一句，而不是靠 `add` 的返回值判断：模拟器实测 `notDetermined` 时
    /// `add` **不报错**，请求却压根不挂在系统里。只看「有没有报错」就会把
    /// 「没授权」记成「已排好」，签名表跟着写下「这条排过了」，之后永远不再补。
    func canDeliver() async -> Bool
    /// 排一条。返回系统是否收下 —— 超载、真报错都会被拒。
    @discardableResult
    func add(_ reminder: ReminderPlan.Desired) async -> Bool
    func remove(_ identifiers: [String]) async
}

/// 订阅提醒的投递。计算全在 `ReminderPlan`，留痕全在 `ReminderLedger`，
/// 这一层只做三件事：问系统现在挂着什么、把该撤的撤掉、把该排的排上。
@MainActor
final class SubscriptionScheduler {
    static let shared = SubscriptionScheduler()

    private let center = UNUserNotificationCenter.current()
    private let delivery: any ReminderDelivery
    private let ledger: ReminderLedger

    init(delivery: (any ReminderDelivery)? = nil, ledger: ReminderLedger? = nil) {
        self.delivery = delivery ?? UserNotificationDelivery(center: center)
        self.ledger = ledger ?? ReminderLedger.shared
    }

    /// 一次重排的结果。日志和测试都看这个，不看「函数有没有返回」。
    struct Report: Equatable {
        var added = 0
        var removed = 0
        /// 系统拒收的条数（没授权、超出容量）。不报错、不假装。
        var rejected = 0
        /// 因为超出条数上限而没能排进去的订阅数。
        var droppedByCapacity = 0
    }

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

    /// 系统在这个授权状态下会不会真的把提醒挂起来。
    ///
    /// 依据是模拟器实测：`notDetermined` 时 `center.add(_:)` 一条都不报错，
    /// 但挂起列表读回来是空的 —— 我们却记成「排入 3 条」，签名表还写下
    /// 「这 3 条已经排好了」。下一轮对账拿签名一比：内容没变，于是连试都不试，
    /// 用户就会在毫无提示的日子被扣一笔钱。所以「没报错」不能当「排上了」。
    static func deliversReminders(under status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined, .denied: return false
        @unknown default: return false
        }
    }

    /// 启动、回前台、数据或设置变化后各调一次。
    ///
    /// 这里不收 `defaultReminderDays`：那是「新建订阅默认提前几天」，
    /// 属于表单的默认值，和「现在该排哪些通知」无关。上一版把它当参数收着却
    /// 一次都没用 —— 设置页那句「按每个订阅的设置提醒你」才是真的行为。
    @discardableResult
    func refill(subscriptions: [Subscription],
                hour: Int,
                enabled: Bool,
                now: Date = Date()) async -> Report {
        let plan = ReminderPlan.desired(subscriptions: subscriptions,
                                        globalEnabled: enabled,
                                        hour: hour,
                                        ledger: ledger,
                                        now: now)
        let pending = await delivery.pendingIdentifiers()
        let reconciliation = ReminderPlan.reconcile(desired: plan.entries,
                                                    pendingIdentifiers: pending,
                                                    storedSignatures: ledger.signatures)
        var report = Report(droppedByCapacity: plan.droppedByCapacity)

        if !reconciliation.toRemove.isEmpty {
            await delivery.remove(reconciliation.toRemove)
            report.removed = reconciliation.toRemove.count
        }
        // 签名表只记「我们真的排进去了的那些」。系统拒收的不能写进去，
        // 否则下一轮以为已经挂好了，永远不会再试一次。
        var stored = reconciliation.signatures
        if !reconciliation.toAdd.isEmpty {
            let deliverable = await delivery.canDeliver()
            if !deliverable {
                // 没授权：一条都不排，也不假装排了。用户去系统设置里允许之后，
                // 下一次重排（回前台 / 改设置 / 改订阅）自然会把这一批补上。
                report.rejected = reconciliation.toAdd.count
                for reminder in reconciliation.toAdd { stored[reminder.identifier] = nil }
                SauryLog.notificationSkipped(
                    "系统还没有允许通知，\(reconciliation.toAdd.count) 条提醒没有排（允许后会自动补排）")
            } else {
                for reminder in reconciliation.toAdd {
                    if await delivery.add(reminder) {
                        report.added += 1
                    } else {
                        report.rejected += 1
                        stored[reminder.identifier] = nil
                    }
                }
            }
        }
        ledger.setSignatures(stored)
        ledger.pruneExpired(now: now)

        SauryLog.notificationScheduled(
            "重排：排入 \(report.added)、撤回 \(report.removed)、拒收 \(report.rejected)、"
            + "超出条数上限没排 \(report.droppedByCapacity)（订阅 \(subscriptions.count) 条，"
            + "总开关\(enabled ? "开" : "关")）")
        if report.rejected > 0 {
            SauryLog.notificationSkipped("有 \(report.rejected) 条提醒没能排进去（未授权或超出系统容量）")
        }
        if report.droppedByCapacity > 0 {
            SauryLog.notificationSkipped("超出系统条数上限，\(report.droppedByCapacity) 条较远的提醒没有排")
        }
        return report
    }

    /// 设置页的预览通知：走和真实提醒同一个正文渲染，这样「预览」预览的
    /// 就是将来真正会看到的那句话。
    func sendPreview(subscription: Subscription?, after seconds: TimeInterval) {
        let sample = subscription ?? Subscription(name: "示例订阅", priceMinorUnits: 2_500,
                                                  currencyCode: "CNY", cycle: .monthly)
        let calendar = BillingMath.calendar
        let chargeDate = calendar.date(byAdding: .day, value: 3, to: calendar.startOfDay(for: Date()))
            ?? Date()
        let fireAt = calendar.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        let reminder = ReminderPlan.Desired(
            subscriptionID: sample.id,
            identifier: Self.previewIdentifier,
            name: sample.name,
            body: ReminderPlan.body(for: sample, chargeDate: chargeDate, fireAt: fireAt),
            chargeDate: chargeDate,
            fireAt: fireAt,
            signature: "",
            isSnoozed: false
        )
        let content = UNMutableNotificationContent()
        content.title = "订阅即将扣费"
        content.body = reminder.body
        content.sound = .default
        content.userInfo = Self.userInfo(for: reminder)
        content.categoryIdentifier = ReminderActions.categoryIdentifier
        center.add(UNNotificationRequest(identifier: reminder.identifier,
                                         content: content,
                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds,
                                                                                    repeats: false)))
    }

    /// 一次性提醒的预览。
    ///
    /// 标识故意不带 `saury.reminder.` 前缀：对账只清理自己那一族，
    /// 预览是「三秒后响一次给你看一眼」，下一轮重排把它撤掉就成了用户按了没反应。
    static let previewIdentifier = "saury.preview.subscription"

    static func userInfo(for reminder: ReminderPlan.Desired) -> [String: String] {
        [
            "subscriptionID": reminder.subscriptionID.uuidString,
            "chargeDate": String(Int(reminder.chargeDate.timeIntervalSince1970.rounded())),
            // 签名跟着通知走：点「稍后提醒」时重建的那一条内容一个字都没变，
            // 签名也就不该重新计算一遍（重新算要拿订阅对象，而通知处理的时候
            // 库可能压根还没开起来）。
            "signature": reminder.signature,
        ]
    }
}

/// 真实实现：`UNUserNotificationCenter`。
/// 标识过滤只认 `saury.reminder.` 这一族，别的（小组件、将来别的功能）一律不动。
@MainActor
final class UserNotificationDelivery: ReminderDelivery {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter) { self.center = center }

    func pendingIdentifiers() async -> Set<String> {
        let requests = await center.pendingNotificationRequests()
        return Set(requests.map(\.identifier).filter(ReminderPlan.isReminderIdentifier(_:)))
    }

    func canDeliver() async -> Bool {
        SubscriptionScheduler.deliversReminders(
            under: await center.notificationSettings().authorizationStatus)
    }

    @discardableResult
    func add(_ reminder: ReminderPlan.Desired) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = "订阅即将扣费"
        content.body = reminder.body
        content.sound = .default
        content.categoryIdentifier = ReminderActions.categoryIdentifier
        content.userInfo = SubscriptionScheduler.userInfo(for: reminder)
        let components = BillingMath.calendar.dateComponents([.year, .month, .day, .hour, .minute],
                                                             from: reminder.fireAt)
        let request = UNNotificationRequest(identifier: reminder.identifier,
                                            content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: components,
                                                                                   repeats: false))
        do {
            try await center.add(request)
            return true
        } catch {
            SauryLog.notificationFailed("排订阅提醒", error)
            return false
        }
    }

    func remove(_ identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}
