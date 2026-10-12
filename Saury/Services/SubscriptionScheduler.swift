import Foundation
import UserNotifications

/// 订阅提醒的投递。每个订阅排「下一期」的提前提醒：扣费日 - reminderDays
/// 的 reminderHour 整点响；reminderDays 为 0 就在扣费当天响。
/// 只补差额：排进去的通知一条都不重复。
@MainActor
final class SubscriptionScheduler {
    static let shared = SubscriptionScheduler()

    private let center = UNUserNotificationCenter.current()
    private static let prefix = "saury.reminder."

    private init() {}

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

    struct DesiredReminder: Equatable {
        let subscriptionID: UUID
        let name: String
        let amountText: String?
        let fireAt: Date
    }

    /// 启动、回前台、数据变化后各调一次。
    func refill(
        subscriptions: [Subscription],
        defaultReminderDays: Int,
        hour: Int,
        enabled: Bool,
        now: Date = Date()
    ) async {
        let desired: [DesiredReminder]
        if enabled {
            desired = subscriptions.compactMap { subscription in
                guard subscription.isTracked, subscription.cycle.isRecurring else { return nil }
                let days = subscription.reminderDays
                guard let chargeDate = BillingMath.nextChargeDate(for: subscription, onOrAfter: now) else { return nil }
                let calendar = BillingMath.calendar
                var fireDate = calendar.date(
                    byAdding: .day,
                    value: -days,
                    to: chargeDate
                ) ?? chargeDate
                if days == 0 {
                    fireDate = chargeDate
                }
                var components = DateComponents()
                components.year = calendar.component(.year, from: fireDate)
                components.month = calendar.component(.month, from: fireDate)
                components.day = calendar.component(.day, from: fireDate)
                components.hour = hour
                components.minute = 0
                guard let triggerDate = calendar.date(from: components), triggerDate >= calendar.startOfDay(for: now) else { return nil }
                return DesiredReminder(
                    subscriptionID: subscription.id,
                    name: subscription.name,
                    amountText: subscription.myAmount.formatted,
                    fireAt: triggerDate
                )
            }
        } else {
            desired = []
        }

        let pending = await pendingReminderIdentifiers()
        let desiredIDs = Set(desired.map { identifier(for: $0) })
        let stale = pending.subtracting(desiredIDs)
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(stale))
        }
        let existing = pending.intersection(desiredIDs)
        for reminder in desired where !existing.contains(identifier(for: reminder)) {
            add(reminder)
        }
    }

    private func add(_ reminder: DesiredReminder) {
        let content = UNMutableNotificationContent()
        content.title = "订阅即将扣费"
        if let amountText = reminder.amountText {
            content.body = "「\(reminder.name)」将在 \(QJFormat.countdown(reminder.fireAt)) 后扣费 \(amountText)。"
        } else {
            content.body = "「\(reminder.name)」将在 \(QJFormat.countdown(reminder.fireAt)) 后扣费。"
        }
        content.sound = .default
        let components = BillingMath.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.fireAt)
        let request = UNNotificationRequest(
            identifier: identifier(for: reminder),
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
        center.add(request) { error in
            if let error { SauryLog.notificationFailed("排订阅提醒", error) }
        }
    }

    private func identifier(for reminder: DesiredReminder) -> String {
        let day = BillingMath.calendar.startOfDay(for: reminder.fireAt).timeIntervalSince1970
        return Self.prefix + reminder.subscriptionID.uuidString + "-" + String(day)
    }

    private func pendingReminderIdentifiers() async -> Set<String> {
        let requests = await center.pendingNotificationRequests()
        return Set(requests.map(\.identifier).filter { $0.hasPrefix(Self.prefix) })
    }

    /// 设置页的预览通知。
    func sendPreview(after seconds: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = "订阅即将扣费"
        content.body = "「ChatGPT」将在 3 天后扣费 $20.00。"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        center.add(UNNotificationRequest(identifier: Self.prefix + "preview", content: content, trigger: trigger))
    }

    func cancelAll() {
        let center = self.center
        center.getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }
}
