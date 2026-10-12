import Foundation

/// 全部统计口径的唯一出处。总览、列表、分类、日历、小票都从这里拿数字，
/// 这样「本月要付多少」在哪个页面看到都是同一个数。
struct SubscriptionStats {
    let subscriptions: [Subscription]
    let defaultCurrency: String
    let rates: [String: Double]

    init(subscriptions: [Subscription], defaultCurrency: String, rates: [String: Double]) {
        self.subscriptions = subscriptions
        self.defaultCurrency = defaultCurrency
        self.rates = rates
    }

    // MARK: - 基础换算

    func converted(_ money: Money) -> Money {
        money.converting(to: defaultCurrency, rates: rates)
    }

    func convertedMinor(_ money: Money) -> Int {
        converted(money).minorUnits
    }

    // MARK: - 周期总额（列表页的 月/季/年 合计）

    enum StatsPeriod: String, CaseIterable {
        case month, quarter, year

        var title: String {
            switch self {
            case .month: return "月"
            case .quarter: return "季"
            case .year: return "年"
            }
        }

        var multiplier: Int {
            switch self {
            case .month: return 1
            case .quarter: return 3
            case .year: return 12
            }
        }

        var longTitle: String {
            switch self {
            case .month: return "本月总额"
            case .quarter: return "本季总额"
            case .year: return "今年总额"
            }
        }
    }

    /// 在册订阅（不含已删除/归档/停用）折算到月的合计；一次性不计入。
    private var tracked: [Subscription] {
        subscriptions.filter(\.isTracked)
    }

    func recurringTotal() -> Money {
        let monthly = tracked.compactMap { BillingMath.monthlyNormalized($0) }
        let minor = monthly.reduce(0) { $0 + convertedMinor($1) }
        return Money(minorUnits: minor, currencyCode: defaultCurrency)
    }

    func total(for period: StatsPeriod) -> Money {
        let base = recurringTotal()
        return Money(minorUnits: base.minorUnits * period.multiplier, currencyCode: defaultCurrency)
    }

    /// 即将扣费：每个订阅的下一笔（自动续费 + 手动续费，一次性不算），
    /// 按日期排好。轮播页一卡一订阅。
    func upcomingCharges(limit: Int = 12, from reference: Date = Date()) -> [ScheduledCharge] {
        tracked
            .compactMap { subscription -> ScheduledCharge? in
                guard subscription.cycle.isRecurring,
                      let date = BillingMath.nextChargeDate(for: subscription, onOrAfter: reference) else { return nil }
                return ScheduledCharge(subscription: subscription, date: date, amount: subscription.myAmount)
            }
            .sorted { $0.date < $1.date }
            .prefix(limit)
            .map { $0 }
    }

    struct ScheduledCharge: Identifiable {
        let subscription: Subscription
        let date: Date
        let amount: Money

        var id: String { subscription.id.uuidString + String(date.timeIntervalSince1970) }
    }

    /// 总览的 月/季/年 总额：这个自然月/季/年里所有会发生的扣费合计。
    func periodChargeTotal(for period: StatsPeriod, now: Date = Date()) -> Money {
        let calendar = BillingMath.calendar
        let range: (start: Date, end: Date)
        switch period {
        case .month:
            range = (calendar.dateInterval(of: .month, for: now)?.start ?? now,
                     calendar.dateInterval(of: .month, for: now)?.end ?? now)
        case .quarter:
            range = (calendar.dateInterval(of: .quarter, for: now)?.start ?? now,
                     calendar.dateInterval(of: .quarter, for: now)?.end ?? now)
        case .year:
            range = (calendar.dateInterval(of: .year, for: now)?.start ?? now,
                     calendar.dateInterval(of: .year, for: now)?.end ?? now)
        }
        let minor = chargeDates(in: range.start..<range.end, after: BillingMath.calendar.startOfDay(for: now))
            .reduce(0) { $0 + convertedMinor($1.amount) }
        return Money(minorUnits: minor, currencyCode: defaultCurrency)
    }

    private func chargeDates(in range: Range<Date>, after floor: Date) -> [ScheduledCharge] {
        var results: [ScheduledCharge] = []
        for subscription in tracked {
            let dates = BillingMath.chargeDates(for: subscription, from: range.lowerBound, to: range.upperBound)
            for date in dates where date >= floor {
                results.append(ScheduledCharge(subscription: subscription, date: date, amount: subscription.myAmount))
            }
        }
        return results.sorted { $0.date < $1.date }
    }

    // MARK: - 分类

    struct CategorySlice: Identifiable {
        let category: SubscriptionCategory
        let monthly: Money
        let yearly: Money
        let share: Double
        let subscriptions: [Subscription]

        var id: String { category.id }
    }

    func categorySlices(preferences: [SubscriptionCategory]) -> [CategorySlice] {
        var buckets: [String: (monthly: Int, subs: [Subscription])] = [:]
        for subscription in tracked {
            guard let monthly = BillingMath.monthlyNormalized(subscription) else { continue }
            buckets[subscription.categoryRawValue, default: (0, [])].monthly += convertedMinor(monthly)
            buckets[subscription.categoryRawValue, default: (0, [])].subs.append(subscription)
        }
        let grand = buckets.values.reduce(0) { $0 + $1.monthly }
        guard grand > 0 else { return [] }
        return buckets
            .map { key, value in
                let category = preferences.first { $0.id == key } ?? DefaultCategories.fallback
                return CategorySlice(
                    category: category,
                    monthly: Money(minorUnits: value.monthly, currencyCode: defaultCurrency),
                    yearly: Money(minorUnits: value.monthly * 12, currencyCode: defaultCurrency),
                    share: Double(value.monthly) / Double(grand),
                    subscriptions: value.subs.sorted { $0.name < $1.name }
                )
            }
            .sorted { $0.monthly.minorUnits > $1.monthly.minorUnits }
    }

    // MARK: - 日历

    /// 某一天会扣费的订阅（当天或之后的第一笔按当天算）。
    func charges(on day: Date, now: Date = Date()) -> [ScheduledCharge] {
        let calendar = BillingMath.calendar
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return tracked.compactMap { subscription -> ScheduledCharge? in
            guard subscription.cycle.isRecurring else { return nil }
            guard let next = BillingMath.nextChargeDate(for: subscription, onOrAfter: max(start, now)) else { return nil }
            guard calendar.startOfDay(for: next) == start else { return nil }
            return ScheduledCharge(subscription: subscription, date: next, amount: subscription.myAmount)
        }
        .sorted { $0.subscription.name < $1.subscription.name }
    }

    /// 月视图：day → 当天扣费。
    func chargesByDay(in month: Date, now: Date = Date()) -> [Date: [ScheduledCharge]] {
        let calendar = BillingMath.calendar
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [:] }
        var result: [Date: [ScheduledCharge]] = [:]
        for subscription in tracked where subscription.cycle.isRecurring {
            let dates = BillingMath.chargeDates(for: subscription, from: interval.start, to: interval.end)
            for date in dates where date >= calendar.startOfDay(for: now) {
                let key = calendar.startOfDay(for: date)
                result[key, default: []].append(
                    ScheduledCharge(subscription: subscription, date: date, amount: subscription.myAmount)
                )
            }
        }
        return result
    }

    // MARK: - 趋势

    /// 最近 N 个月的支出柱状图（每根柱 = 当月发生的全部扣费，不含未来）。
    func trendBars(months: Int = 6, now: Date = Date()) -> [BarsChart.Bar] {
        let calendar = BillingMath.calendar
        let formatter = DateFormatter()
        formatter.dateFormat = "M月"
        var bars: [BarsChart.Bar] = []
        for offset in stride(from: months - 1, through: 0, by: -1) {
            guard let monthStart = calendar.date(byAdding: .month, value: -offset, to: now),
                  let interval = calendar.dateInterval(of: .month, for: monthStart) else { continue }
            let minor = tracked.reduce(0) { partial, subscription -> Int in
                let dates = BillingMath.chargeDates(for: subscription, from: interval.start, to: interval.end)
                let count = dates.filter { $0 < now }.count
                return partial + count * convertedMinor(subscription.myAmount)
            }
            bars.append(BarsChart.Bar(
                id: interval.start.description,
                label: formatter.string(from: monthStart),
                value: Double(minor),
                highlighted: offset == 0
            ))
        }
        return bars
    }

    // MARK: - 累计与月均

    struct Cumulative {
        let total: Money
        let chargeCount: Int
        let perSubscription: [(subscription: Subscription, count: Int, total: Money)]
        let monthlyAverage: Money
        let perSubscriptionAverage: Money
        let coveredMonths: Int
    }

    /// 从开始日期到今天实际发生过的扣费（一次性订阅算它的开始日那一次）。
    func cumulative(now: Date = Date()) -> Cumulative {
        var totalCount = 0
        var totalMinor = 0
        var perSubscription: [(subscription: Subscription, count: Int, total: Money)] = []
        var earliest: Date?

        let calendar = BillingMath.calendar
        let horizon = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        for subscription in tracked {
            var dates: [Date]
            if subscription.cycle.isRecurring {
                dates = BillingMath.chargeDates(for: subscription, from: subscription.startDate, to: horizon)
            } else {
                dates = BillingMath.calendar.startOfDay(for: subscription.startDate) <= BillingMath.calendar.startOfDay(for: now) ? [subscription.startDate] : []
            }
            guard !dates.isEmpty else { continue }
            let count = dates.count
            let minor = count * convertedMinor(subscription.myAmount)
            totalCount += count
            totalMinor += minor
            perSubscription.append((subscription, count, Money(minorUnits: minor, currencyCode: defaultCurrency)))
            if let first = dates.first {
                earliest = min(earliest ?? first, first)
            }
        }

        var coveredMonths = 1
        if let earliest {
            let months = calendar.dateComponents([.month], from: calendar.startOfDay(for: earliest), to: now).month ?? 0
            coveredMonths = max(months + 1, 1)
        }
        let monthlyAverage = Money(minorUnits: totalMinor / coveredMonths, currencyCode: defaultCurrency)
        let subscriptionCount = max(tracked.count, 1)
        let perAverage = Money(minorUnits: monthlyAverage.minorUnits / subscriptionCount, currencyCode: defaultCurrency)

        return Cumulative(
            total: Money(minorUnits: totalMinor, currencyCode: defaultCurrency),
            chargeCount: totalCount,
            perSubscription: perSubscription.sorted { $0.total.minorUnits > $1.total.minorUnits },
            monthlyAverage: monthlyAverage,
            perSubscriptionAverage: perAverage,
            coveredMonths: coveredMonths
        )
    }
}
