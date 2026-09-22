import Foundation

/// 每个分类该提前多久提醒（方案 §43）。模板给的是「还来得及做决定」的时间：
/// 证件要办手续所以最早，食品只需要扔掉所以最晚。
enum ReminderPolicy {
    private static let minute = 60
    private static let day = 24 * 60

    static func templateOffsets(for category: ExpiryCategory) -> [Int] {
        switch category {
        case .food: return [3 * day, day, 0]
        case .medicine: return [30 * day, 7 * day, day, 0]
        case .supplement: return [30 * day, 7 * day, day, 0]
        case .skincare, .cosmetic: return [30 * day, 7 * day, 0]
        case .household: return [7 * day, day, 0]
        case .document, .warranty: return [90 * day, 30 * day, 7 * day, day]
        case .subscription: return [7 * day, 3 * day, day, 0]
        case .filter: return [30 * day, 7 * day, day, 0]
        case .pet: return [7 * day, 3 * day, day, 0]
        case .other: return [7 * day, day, 0]
        }
    }

    /// 通知统一落在用户选定的时间点（方案 §44）。
    static var reminderHour: Int { QJPreferences.reminderHour }

    /// 设置里「并入默认提醒计划」的提前天数档位。
    static let defaultDayChoices = [1, 3, 7, 14, 30]

    /// 新建物品用的计划：分类模板，再并入用户在设置里选的提前天数。
    static func defaultOffsets(for category: ExpiryCategory) -> [Int] {
        normalized(templateOffsets(for: category) + [QJPreferences.defaultReminderDays * day])
    }

    /// 提醒计划里可以勾选的档位。
    static func presets(for category: ExpiryCategory) -> [ReminderPreset] {
        let ladder = [90 * day, 30 * day, 14 * day, 7 * day, 3 * day, day, 3 * minute, 0]
        return normalized(Set(templateOffsets(for: category)).union(ladder)).map(ReminderPreset.init(minutesBefore:))
    }

    /// 去重并从最早到最晚排列，当天始终在最后。
    /// 去重是必须的：设置里的默认提前天数经常和分类模板撞车，
    /// 留下重复就会为同一个时刻排两条通知。
    private static func normalized(_ offsets: some Sequence<Int>) -> [Int] {
        Array(Set(offsets)).sorted(by: >)
    }
}
