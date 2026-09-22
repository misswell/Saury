import Foundation
import UserNotifications

struct NotificationActionPayload: Codable {
    let renewalItemID: UUID
    let action: DecisionAction
}

@MainActor
final class ReminderScheduler {
    static let shared = ReminderScheduler()

    private let center = UNUserNotificationCenter.current()
    private let managedPrefix = "qijian.renewal."
    private let snoozePrefix = "qijian.snooze."

    private init() {
        registerNotificationCategories()
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func rescheduleAll(items: [RenewalItem], now: Date = Date()) async {
        let requests = await center.pendingNotificationRequests()
        let managedIDs = requests.map(\.identifier).filter { $0.hasPrefix(managedPrefix) || $0.hasPrefix(snoozePrefix) }
        center.removePendingNotificationRequests(withIdentifiers: managedIDs)

        var candidates: [(date: Date, item: RenewalItem, offset: Int)] = []
        let calendar = RenewalDateCalculator.defaultCalendar
        for item in items where item.status == .active {
            for offset in item.reminderOffsets {
                let date = RenewalDateCalculator.notificationDate(for: item.nextRenewalDate, minutesBefore: offset, calendar: calendar)
                if date > now.addingTimeInterval(30) {
                    candidates.append((date, item, offset))
                }
            }
        }

        for candidate in candidates.sorted(by: { $0.date < $1.date }).prefix(60) {
            await scheduleReminder(for: candidate.item, offset: candidate.offset, at: candidate.date)
        }
    }

    func scheduleReminder(for item: RenewalItem, offset: Int, at date: Date) async {
        let content = UNMutableNotificationContent()
        content.title = item.name
        content.body = offset == 0
            ? "今天将续费 \(item.formattedAmount) ，现在决定要不要继续。"
            : "还有 \(offset.titleText) 到期，留一点时间决定要不要继续。"
        content.sound = .default
        content.categoryIdentifier = "qijian.renewal.reminder"
        content.userInfo = ["renewalItemID": item.id.uuidString]
        let components = RenewalDateCalculator.defaultCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: "\(managedPrefix)\(item.id.uuidString).\(offset)", content: content, trigger: trigger)
        try? await center.add(request)
    }

    func scheduleSnooze(for item: RenewalItem) async {
        let content = UNMutableNotificationContent()
        content.title = item.name
        content.body = "这是你昨天留下的提醒，距离到期还有 \(RenewalDateCalculator.daysUntil(item.nextRenewalDate)) 天。"
        content.sound = .default
        content.categoryIdentifier = "qijian.renewal.reminder"
        content.userInfo = ["renewalItemID": item.id.uuidString]
        let triggerDate = Date().addingTimeInterval(24 * 60 * 60)
        let components = RenewalDateCalculator.defaultCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: triggerDate)
        let request = UNNotificationRequest(identifier: "\(snoozePrefix)\(item.id.uuidString)", content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
        try? await center.add(request)
    }

    private func registerNotificationCategories() {
        let cancel = UNNotificationAction(identifier: "qijian.action.cancel", title: "已取消续费", options: [.foreground])
        let continueAction = UNNotificationAction(identifier: "qijian.action.continue", title: "继续订阅", options: [.foreground])
        let snooze = UNNotificationAction(identifier: "qijian.action.snooze", title: "明天提醒", options: [.foreground])
        let category = UNNotificationCategory(identifier: "qijian.renewal.reminder", actions: [cancel, continueAction, snooze], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }
}

private extension Int {
    var titleText: String {
        if self >= 24 * 60 { return "\(self / (24 * 60)) 天"
        }
        return "\(Swift.max(self / 60, 1)) 小时"
    }
}

extension RenewalItem {
    var formattedAmount: String {
        let amount = Decimal(amountMinorUnits) / 100
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.locale = Locale(identifier: currencyCode == "CNY" ? "zh_CN" : Locale.current.identifier)
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "\(currencyCode) \(amount)"
    }
}
