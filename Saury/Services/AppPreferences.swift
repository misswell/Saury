import Foundation

enum QJPreferences {
    static let defaultReminderDaysKey = "qijian.defaultReminderDays"
    static let defaultCurrencyCodeKey = "qijian.defaultCurrencyCode"

    static var defaultReminderDays: Int {
        let value = UserDefaults.standard.integer(forKey: defaultReminderDaysKey)
        return value > 0 ? value : 3
    }

    static var defaultCurrencyCode: String {
        UserDefaults.standard.string(forKey: defaultCurrencyCodeKey) ?? "CNY"
    }

    static func reminderOffsets(for cycle: RenewalCycle) -> [Int] {
        let day = defaultReminderDays * 24 * 60
        switch cycle {
        case .freeTrial:
            return [min(day, 3 * 24 * 60), 24 * 60, 3 * 60, 0]
        case .yearly:
            return [max(day, 7 * 24 * 60), 7 * 24 * 60, 24 * 60, 0]
        case .oneTime:
            return [day, 24 * 60, 0]
        default:
            return [day, 24 * 60, 0]
        }
    }
}
