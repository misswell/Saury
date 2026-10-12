import Foundation

/// 扣费日期的全部算法。锚点日的规则和旧续费引擎一致：
/// 1 月 31 日的月付被钳到 2 月 28 日，下一次仍回到 31 日 ——
/// 所以锚点日跟着「开始日是几号」走，不跟当前期走。
enum BillingMath {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// 下一次扣费日。`onOrAfter` 为 true 时，当天本身也算（「今天扣费」）。
    static func nextChargeDate(for subscription: Subscription, onOrAfter reference: Date = Date()) -> Date? {
        guard subscription.state != .inactive, subscription.cycle.isRecurring else { return nil }
        let next = advance(
            from: subscription.startDate,
            cycle: subscription.cycle,
            months: subscription.customMonths,
            anchorDay: subscription.anchorDay,
            onOrAfter: reference
        )
        // 推出来的日子已经越过结束日，等于没有下一次。
        if let next, let endDate = subscription.endDate,
           calendar.startOfDay(for: next) > calendar.startOfDay(for: endDate) {
            return nil
        }
        return next
    }

    /// 从锚点出发一路推进，直到落在 reference 当天或之后。
    /// 所有调用方都用「含当天」语义：循环用 `<` 比较，落在 limit 上也会停。
    static func advance(
        from anchor: Date,
        cycle: BillingCycle,
        months customMonths: Int,
        anchorDay: Int? = nil,
        onOrAfter reference: Date
    ) -> Date? {
        let calendar = BillingMath.calendar
        guard cycle.isRecurring else { return nil }

        let anchorDayValue = anchorDay ?? calendar.component(.day, from: anchor)
        var current = calendar.startOfDay(for: anchor)
        let limit = calendar.startOfDay(for: reference)
        // 防御：极端的旧数据（开始时间在几年前）也不该卡死循环，最多推 1200 个周期。
        var guardCounter = 0
        while current < limit {
            guardCounter += 1
            if guardCounter > 1200 { return nil }
            guard let next = step(from: current, cycle: cycle, months: customMonths, anchorDay: anchorDayValue) else { return nil }
            current = next
        }
        return current
    }

    /// 推进一个周期，按锚点日回位（31 号 → 2 月 28 日 → 3 月 31 日）。
    static func step(from date: Date, cycle: BillingCycle, months customMonths: Int, anchorDay: Int? = nil) -> Date? {
        let calendar = BillingMath.calendar
        switch cycle {
        case .weekly:
            return calendar.date(byAdding: .day, value: 7, to: date)
        case .monthly, .quarterly, .semiannual, .yearly, .custom:
            let months: Int
            switch cycle {
            case .monthly: months = 1
            case .quarterly: months = 3
            case .semiannual: months = 6
            case .yearly: months = 12
            case .custom: months = max(customMonths, 1)
            default: months = 1
            }
            let day = anchorDay ?? calendar.component(.day, from: date)
            guard let shifted = calendar.date(byAdding: .month, value: months, to: date) else { return nil }
            return calendar.date(withAnchorDay: day, inMonthOf: shifted)
        case .oneTime:
            return nil
        }
    }

    /// [start, end) 之间的扣费日（start 含、end 不含）。
    static func chargeDates(for subscription: Subscription, from start: Date, to end: Date) -> [Date] {
        guard subscription.cycle.isRecurring, subscription.state != .inactive else { return [] }
        let calendar = BillingMath.calendar
        var results: [Date] = []
        var current = calendar.startOfDay(for: subscription.startDate)
        let stop = calendar.startOfDay(for: end)
        let floor = calendar.startOfDay(for: start)
        let anchor = subscription.anchorDay
        var guardCounter = 0
        while current < stop {
            guardCounter += 1
            if guardCounter > 2400 { break }
            if current >= floor { results.append(current) }
            guard let next = step(from: current, cycle: subscription.cycle, months: subscription.customMonths, anchorDay: anchor) else { break }
            current = next
        }
        return results
    }

    /// 一个周期多长（天）。周付 7 天，其余按月估 30.44 —— 只用于进度条这类显示。
    static func approximateCycleDays(for subscription: Subscription) -> Double {
        switch subscription.cycle {
        case .weekly: return 7
        case .monthly: return 30.44
        case .quarterly: return 91.3
        case .semiannual: return 182.6
        case .yearly: return 365.25
        case .custom: return Double(subscription.customMonths) * 30.44
        case .oneTime: return 1
        }
    }

    /// 折算到每月的金额（自己那份）。一次性返回 nil —— 它不进月均。
    static func monthlyNormalized(_ subscription: Subscription) -> Money? {
        guard subscription.cycle.isRecurring else { return nil }
        let mine = subscription.myAmount
        switch subscription.cycle {
        case .weekly:
            return Money(minorUnits: Int((Double(mine.minorUnits) * 52.0 / 12.0).rounded()), currencyCode: mine.currencyCode)
        case .monthly:
            return mine
        case .quarterly:
            return Money(minorUnits: Int((Double(mine.minorUnits) / 3.0).rounded()), currencyCode: mine.currencyCode)
        case .semiannual:
            return Money(minorUnits: Int((Double(mine.minorUnits) / 6.0).rounded()), currencyCode: mine.currencyCode)
        case .yearly:
            return Money(minorUnits: Int((Double(mine.minorUnits) / 12.0).rounded()), currencyCode: mine.currencyCode)
        case .custom:
            return Money(minorUnits: Int((Double(mine.minorUnits) / Double(max(subscription.customMonths, 1))).rounded()), currencyCode: mine.currencyCode)
        case .oneTime:
            return nil
        }
    }

    static func daysUntil(_ date: Date, from reference: Date = Date()) -> Int {
        let calendar = BillingMath.calendar
        let start = calendar.startOfDay(for: reference)
        let target = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: start, to: target).day ?? 0
    }

    /// 是否已经开始（开始日 <= 今天）。未开始的订阅不计入已扣统计。
    static func isStarted(_ subscription: Subscription, now: Date = Date()) -> Bool {
        calendar.startOfDay(for: subscription.startDate) <= calendar.startOfDay(for: now)
    }
}

extension Calendar {
    /// 在 `anchor` 所在月份里取「第 day 天」；当月没有这一天（2 月 31 日）就取当月最后一天。
    func date(withAnchorDay day: Int, inMonthOf anchor: Date) -> Date? {
        let components = dateComponents([.year, .month], from: anchor)
        var target = DateComponents()
        target.year = components.year
        target.month = components.month
        target.day = max(day, 1)
        if let candidate = date(from: target),
           component(.month, from: candidate) == components.month {
            return startOfDay(for: candidate)
        }
        // 溢出进了下个月：退回当月最后一天。
        guard let firstOfThisMonth = date(from: DateComponents(year: components.year, month: components.month, day: 1)),
              let firstOfNextMonth = date(byAdding: .month, value: 1, to: firstOfThisMonth) else { return nil }
        return startOfDay(for: date(byAdding: .day, value: -1, to: firstOfNextMonth) ?? firstOfThisMonth)
    }
}
