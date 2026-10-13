import Foundation

/// 全部统计口径的唯一出处。总览、列表、分类、日历、小票都从这里拿数字，
/// 这样「本月要付多少」在哪个页面看到都是同一个数。
///
/// 涉及「过去花过多少」的一律转交 `SubscriptionLedger`：已登记支付和按周期
/// 推算出来的预计费用是两个数，不能揉成一个。
struct SubscriptionStats {
    let subscriptions: [Subscription]
    let events: [SubscriptionEvent]
    let defaultCurrency: String
    let rates: [String: Double]

    init(subscriptions: [Subscription],
         events: [SubscriptionEvent],
         defaultCurrency: String,
         rates: [String: Double]) {
        self.subscriptions = subscriptions
        self.events = events
        self.defaultCurrency = defaultCurrency
        self.rates = rates
    }

    private var ledger: SubscriptionLedger {
        SubscriptionLedger(subscriptions: subscriptions,
                           events: events,
                           defaultCurrency: defaultCurrency,
                           rates: rates)
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

    private var calendar: Calendar { BillingMath.calendar }

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
        ledger.upcomingEntries(now: reference, limit: limit).map(ScheduledCharge.init(entry:))
    }

    struct ScheduledCharge: Identifiable {
        let subscription: Subscription
        let date: Date
        let amount: Money

        var id: String { subscription.id.uuidString + String(date.timeIntervalSince1970) }

        init(subscription: Subscription, date: Date, amount: Money) {
            self.subscription = subscription
            self.date = date
            self.amount = amount
        }

        init(entry: SubscriptionLedger.Entry) {
            subscription = entry.subscription
            date = entry.date
            amount = entry.amount
        }
    }

    /// 总览的 月/季/年 总额：这个自然月/季/年里所有会发生的扣费合计。
    func periodChargeTotal(for period: StatsPeriod, now: Date = Date()) -> Money {
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
        let minor = ledger.plannedEntries(in: range.start..<range.end,
                                          floor: calendar.startOfDay(for: now))
            .reduce(0) { $0 + convertedMinor($1.amount) }
        return Money(minorUnits: minor, currencyCode: defaultCurrency)
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

    /// 最近 N 个月的支出柱状图（每根柱 = 当月真实发生过 + 推算落在当月的扣费）。
    func trendBars(months: Int = 6, now: Date = Date()) -> [BarsChart.Bar] {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月"
        return ledger.monthlySeries(months: months, now: now).enumerated().map { index, item in
            BarsChart.Bar(
                id: item.monthStart.description,
                label: formatter.string(from: item.monthStart),
                value: Double(item.total.minorUnits),
                highlighted: index == months - 1
            )
        }
    }

    // MARK: - 累计与月均

    typealias Cumulative = SubscriptionLedger.Totals

    /// 从有记录到现在一共花掉多少。拆成「已登记支付」和「预计历史费用」两个数，
    /// 页面必须按这个拆法展示，不能只报合计。
    func cumulative(now: Date = Date()) -> Cumulative {
        ledger.totals(now: now)
    }

    /// 按月拆分的支出（详情页分期列表、小票共用同一份）。
    func monthlyBuckets(now: Date = Date()) -> [SubscriptionLedger.MonthBucket] {
        ledger.monthlyBuckets(now: now)
    }
}
