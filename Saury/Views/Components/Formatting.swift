import Foundation

/// 日期文案。界面上的「10月11日 周日」「2026年10月11日」都从这一处出。
enum QJFormat {
    static let weekdaySymbols = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    static func shortDate(_ date: Date) -> String {
        let calendar = BillingMath.calendar
        return "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
    }

    static func shortDateWithWeekday(_ date: Date) -> String {
        "\(shortDate(date)) \(weekdaySymbols[calendarWeekday(date) - 1])"
    }

    static func longDate(_ date: Date) -> String {
        let calendar = BillingMath.calendar
        return "\(calendar.component(.year, from: date))年\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
    }

    static func yearMonth(_ date: Date) -> String {
        let calendar = BillingMath.calendar
        return "\(calendar.component(.year, from: date))年\(calendar.component(.month, from: date))月"
    }

    /// 今天 / 明天 / 其余用短日期。
    static func relativeDay(_ date: Date, now: Date = Date()) -> String {
        let days = BillingMath.daysUntil(date, from: now)
        if days == 0 { return "今天" }
        if days == 1 { return "明天" }
        if days == 2 { return "后天" }
        return shortDate(date)
    }

    /// 还有 N 天；0 天 = 今天。
    static func countdown(_ date: Date, now: Date = Date()) -> String {
        let days = BillingMath.daysUntil(date, from: now)
        if days < 0 { return "已过 \(abs(days)) 天" }
        if days == 0 { return "今天" }
        return "还有 \(days) 天"
    }

    static func monthDayShort(_ date: Date) -> String {
        let calendar = BillingMath.calendar
        return "\(calendar.component(.month, from: date)).\(calendar.component(.day, from: date))"
    }

    private static func calendarWeekday(_ date: Date) -> Int {
        BillingMath.calendar.component(.weekday, from: date)
    }
}
