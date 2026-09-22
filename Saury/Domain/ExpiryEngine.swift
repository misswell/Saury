import Foundation

/// 过期域的唯一计算入口（方案 §10）。View 不允许再自己算天数、
/// 分级或下一次提醒，否则同一个物品会在两个页面显示成两个结论。
enum ExpiryEngine {
    /// 业务日期一律按「日历天」比较：同一天的早晚不改变剩余天数。
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    // MARK: - 真正会过期的那一天

    /// 包装日期、生产日期 + 保质期、开封后有效期，取最早的那个。
    static func effectiveExpiryDate(for item: ExpiryItem, calendar: Calendar = ExpiryEngine.calendar) -> Date {
        var result = item.expiryDate
        if let manufactureDate = item.manufactureDate, let shelfLife = item.shelfLifeDays, shelfLife > 0,
           let derived = calendar.date(byAdding: .day, value: shelfLife, to: manufactureDate) {
            result = min(result, derived)
        }
        if let openedDate = item.openedDate, let afterOpening = item.afterOpeningDays, afterOpening > 0,
           let derived = calendar.date(byAdding: .day, value: afterOpening, to: openedDate) {
            result = min(result, derived)
        }
        return result
    }

    // MARK: - 剩余天数

    static func daysRemaining(to date: Date, from referenceDate: Date = Date(), calendar: Calendar = ExpiryEngine.calendar) -> Int {
        let start = calendar.startOfDay(for: referenceDate)
        let end = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    static func daysRemaining(for item: ExpiryItem, from referenceDate: Date = Date(), calendar: Calendar = ExpiryEngine.calendar) -> Int {
        daysRemaining(to: effectiveExpiryDate(for: item, calendar: calendar), from: referenceDate, calendar: calendar)
    }

    static func urgency(for item: ExpiryItem, from referenceDate: Date = Date(), calendar: Calendar = ExpiryEngine.calendar) -> ExpiryUrgency {
        ExpiryUrgency(daysRemaining: daysRemaining(for: item, from: referenceDate, calendar: calendar))
    }

    static func isExpired(_ item: ExpiryItem, at referenceDate: Date = Date(), calendar: Calendar = ExpiryEngine.calendar) -> Bool {
        daysRemaining(for: item, from: referenceDate, calendar: calendar) < 0
    }

    /// 到期日落在参考日之后多少天内（含当天）。
    static func isExpiringWithinDays(_ days: Int, item: ExpiryItem, from referenceDate: Date = Date(), calendar: Calendar = ExpiryEngine.calendar) -> Bool {
        let remaining = daysRemaining(for: item, from: referenceDate, calendar: calendar)
        return remaining >= 0 && remaining <= days
    }

    // MARK: - 重复周期

    /// 推进到下一次到期/续费。锚点日不存在的月份会被钳到当月最后一天，
    /// 1 月 31 日按月续费落在 2 月 28 日，而不是滚到 3 月 3 日。
    static func nextOccurrence(
        after date: Date,
        recurrence: ExpiryRecurrence,
        intervalMonths: Int? = nil,
        anchorDay: Int? = nil,
        calendar: Calendar = ExpiryEngine.calendar
    ) -> Date? {
        switch recurrence {
        case .none:
            return nil
        case .weekly:
            return calendar.date(byAdding: .day, value: 7, to: date)
        case .monthly, .quarterly, .everySixMonths, .yearly, .custom:
            let months: Int
            switch recurrence {
            case .monthly: months = 1
            case .quarterly: months = 3
            case .everySixMonths: months = 6
            case .yearly: months = 12
            case .custom: months = max(intervalMonths ?? 1, 1)
            default: return nil
            }
            let source = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            let firstOfMonth = calendar.date(from: DateComponents(
                year: source.year, month: source.month, day: 1,
                hour: source.hour, minute: source.minute, second: source.second
            )) ?? date
            guard let targetMonth = calendar.date(byAdding: .month, value: months, to: firstOfMonth) else { return nil }
            let components = calendar.dateComponents([.year, .month], from: targetMonth)
            guard let year = components.year, let month = components.month,
                  let dayRange = calendar.range(of: .day, in: .month, for: targetMonth) else { return nil }
            let day = min(max(anchorDay ?? source.day ?? 1, 1), dayRange.count)
            return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: source.hour, minute: source.minute, second: source.second))
        }
    }

    static func nextOccurrence(for item: ExpiryItem, calendar: Calendar = ExpiryEngine.calendar) -> Date? {
        nextOccurrence(
            after: effectiveExpiryDate(for: item, calendar: calendar),
            recurrence: item.recurrence,
            intervalMonths: item.recurrenceMonths,
            anchorDay: item.anchorDay,
            calendar: calendar
        )
    }

    // MARK: - 提醒

    /// 提前 N 分钟对应的通知时刻。按天/按周提前时落在当天的默认提醒时间，
    /// 按小时提前则贴着到期时刻倒推，否则「提前 3 小时」会变成半夜提醒。
    static func notificationDate(
        forExpiry expiryDate: Date,
        minutesBefore: Int,
        preferredHour: Int = ReminderPolicy.reminderHour,
        calendar: Calendar = ExpiryEngine.calendar
    ) -> Date {
        if minutesBefore == 0 {
            return atHour(preferredHour, on: expiryDate, calendar: calendar)
        }
        if minutesBefore % (24 * 60) == 0 {
            let day = calendar.date(byAdding: .day, value: -(minutesBefore / (24 * 60)), to: expiryDate) ?? expiryDate
            return atHour(preferredHour, on: day, calendar: calendar)
        }
        return calendar.date(byAdding: .minute, value: -minutesBefore, to: expiryDate) ?? expiryDate
    }

    private static func atHour(_ hour: Int, on date: Date, calendar: Calendar) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = hour
        components.minute = 0
        return calendar.date(from: components) ?? date
    }

    /// 一次到期日对应的全部通知时刻，按时间先后排列。
    static func notificationDates(
        for item: ExpiryItem,
        preferredHour: Int = ReminderPolicy.reminderHour,
        calendar: Calendar = ExpiryEngine.calendar
    ) -> [Date] {
        let expiry = effectiveExpiryDate(for: item, calendar: calendar)
        return item.reminderOffsets
            .map { notificationDate(forExpiry: expiry, minutesBefore: $0, preferredHour: preferredHour, calendar: calendar) }
            .sorted()
    }

    /// 下一次真正的提醒：算出全部通知时刻，过滤掉已经过去的，取最早的一个（方案 §46）。
    static func nextReminderDate(
        for item: ExpiryItem,
        now: Date = Date(),
        preferredHour: Int = ReminderPolicy.reminderHour,
        calendar: Calendar = ExpiryEngine.calendar
    ) -> Date? {
        notificationDates(for: item, preferredHour: preferredHour, calendar: calendar).first { $0 > now }
    }
}

extension ExpiryItem {
    var effectiveExpiryDate: Date { ExpiryEngine.effectiveExpiryDate(for: self) }
    var daysRemaining: Int { ExpiryEngine.daysRemaining(for: self) }
    var urgency: ExpiryUrgency { ExpiryEngine.urgency(for: self) }
    var isExpired: Bool { ExpiryEngine.isExpired(self) }
    var nextOccurrence: Date? { ExpiryEngine.nextOccurrence(for: self) }
    var nextReminderDate: Date? { ExpiryEngine.nextReminderDate(for: self) }
}
