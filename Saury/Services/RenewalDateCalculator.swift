import Foundation

struct RenewalDateCalculator {
    static var defaultCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    static func nextDate(
        after date: Date,
        cycle: RenewalCycle,
        intervalMonths: Int = 1,
        anchorDay: Int? = nil,
        calendar: Calendar = defaultCalendar
    ) -> Date? {
        switch cycle {
        case .oneTime:
            return nil
        case .monthly, .yearly, .customMonths, .freeTrial:
            let months: Int
            switch cycle {
            case .monthly: months = max(intervalMonths, 1)
            case .yearly: months = max(intervalMonths, 1) * 12
            case .customMonths: months = max(intervalMonths, 1)
            case .freeTrial: months = max(intervalMonths, 1)
            case .oneTime: months = 0
            }
            let source = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            let firstOfMonth = calendar.date(from: DateComponents(year: source.year, month: source.month, day: 1, hour: source.hour, minute: source.minute, second: source.second)) ?? date
            guard let targetMonth = calendar.date(byAdding: .month, value: months, to: firstOfMonth) else { return nil }
            let targetMonthComponents = calendar.dateComponents([.year, .month], from: targetMonth)
            guard let targetYear = targetMonthComponents.year, let targetMonthValue = targetMonthComponents.month,
                  let dayRange = calendar.range(of: .day, in: .month, for: targetMonth) else { return nil }
            let day = min(max(anchorDay ?? source.day ?? 1, 1), dayRange.count)
            return calendar.date(from: DateComponents(
                year: targetYear,
                month: targetMonthValue,
                day: day,
                hour: source.hour,
                minute: source.minute,
                second: source.second
            ))
        }
    }

    static func nextDate(for item: RenewalItem, calendar: Calendar = defaultCalendar) -> Date? {
        nextDate(after: item.nextRenewalDate, cycle: item.cycle, intervalMonths: item.intervalMonths, anchorDay: item.anchorDay, calendar: calendar)
    }

    static func daysUntil(_ date: Date, from referenceDate: Date = Date(), calendar: Calendar = defaultCalendar) -> Int {
        let start = calendar.startOfDay(for: referenceDate)
        let end = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    static func notificationDate(
        for renewalDate: Date,
        minutesBefore: Int,
        preferredHour: Int = 10,
        calendar: Calendar = defaultCalendar
    ) -> Date {
        if minutesBefore == 0 {
            var components = calendar.dateComponents([.year, .month, .day], from: renewalDate)
            components.hour = preferredHour
            components.minute = 0
            return calendar.date(from: components) ?? renewalDate
        }
        if minutesBefore % (24 * 60) == 0 {
            let days = minutesBefore / (24 * 60)
            let day = calendar.date(byAdding: .day, value: -days, to: renewalDate) ?? renewalDate
            var components = calendar.dateComponents([.year, .month, .day], from: day)
            components.hour = preferredHour
            components.minute = 0
            return calendar.date(from: components) ?? day
        }
        return calendar.date(byAdding: .minute, value: -minutesBefore, to: renewalDate) ?? renewalDate
    }

    static func isDueSoon(_ date: Date, within days: Int = 30, referenceDate: Date = Date(), calendar: Calendar = defaultCalendar) -> Bool {
        let value = daysUntil(date, from: referenceDate, calendar: calendar)
        return value >= 0 && value <= days
    }
}
