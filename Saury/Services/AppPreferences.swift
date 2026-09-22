import Foundation

enum QJPreferences {
    static let defaultReminderDaysKey = "qijian.defaultReminderDays"
    static let defaultCurrencyCodeKey = "qijian.defaultCurrencyCode"
    static let reminderHourKey = "qijian.reminderHour"
    static let itemSortKey = "qijian.itemSort"

    static var defaultReminderDays: Int {
        let value = UserDefaults.standard.integer(forKey: defaultReminderDaysKey)
        return value > 0 ? value : 3
    }

    static var defaultCurrencyCode: String {
        UserDefaults.standard.string(forKey: defaultCurrencyCodeKey) ?? "CNY"
    }

    /// 通知落在当天的几点（方案 §44）。不再硬编码 10:00。
    static var reminderHour: Int {
        let stored = UserDefaults.standard.object(forKey: reminderHourKey) as? Int
        guard let stored else { return 9 }
        return min(max(stored, 0), 23)
    }

    /// 排序选择要跨启动保留（方案 §18）。
    static var itemSort: ItemSort {
        get {
            guard let raw = UserDefaults.standard.string(forKey: itemSortKey) else { return .earliestExpiry }
            return ItemSort(rawValue: raw) ?? .earliestExpiry
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: itemSortKey) }
    }
}
