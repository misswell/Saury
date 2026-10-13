import Foundation

/// 付过的钱分三种，混在一个数字里就是虚报：
///
/// * **已记录支付**：用户登记过的扣费/内购事件，有凭据。
/// * **预计历史费用**：按周期推算出来、落在过去的扣费，没有凭据。
/// * **未来预计费用**：还没发生的计划扣费。
///
/// 总览、列表、日历、小票、图表都从这一处取数，所以同一批订阅
/// 在哪个页面看到的历史合计都是同一个数。
struct SubscriptionLedger {
    enum Origin: Equatable {
        /// 用户登记过的扣费事件，金额是当时真实发生的。
        case recorded
        /// 周期推算出来的，UI 必须标「预计」。
        case projected
    }

    struct Entry {
        let subscription: Subscription
        let date: Date
        /// 订阅自己的币种；换算到默认币种由 `converted` 做。
        let amount: Money
        let origin: Origin
        /// 推算期间发生过调价但旧价没留档，只能拿现价估 —— 这个数要标不确定。
        let amountIsUncertain: Bool

        var id: String {
            "\(subscription.id.uuidString)-\(Int(date.timeIntervalSince1970))-\(origin == .recorded ? "r" : "p")"
        }
    }

    struct MonthBucket {
        let monthStart: Date
        let recorded: Money
        let projected: Money
        let recordedCount: Int
        let projectedCount: Int

        var total: Money { recorded + projected }
        var chargeCount: Int { recordedCount + projectedCount }
    }

    struct SubscriptionSummary {
        let subscription: Subscription
        let recordedCount: Int
        let projectedCount: Int
        let total: Money

        var chargeCount: Int { recordedCount + projectedCount }
        /// 一条扣费事件都没登记过：全部数字都是推算的。
        var isAllProjected: Bool { recordedCount == 0 }
    }

    struct Totals {
        let recorded: Money
        let projectedPast: Money
        /// 账面合计 = 已记录 + 预计历史。展示时必须拆开放，不能只报这个数。
        let combined: Money
        let recordedCount: Int
        let projectedCount: Int
        let uncertainCount: Int
        let perSubscription: [SubscriptionSummary]
        let coveredMonths: Int
        let monthlyAverage: Money
        let perSubscriptionAverage: Money
        /// 有凭据的笔数占比，用来看这个合计数能信几成。
        let recordedShare: Double

        var chargeCount: Int { recordedCount + projectedCount }
    }

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

    // MARK: - 换算

    func converted(_ money: Money) -> Money {
        money.converting(to: defaultCurrency, rates: rates)
    }

    private func convertedMinor(_ entry: Entry) -> Int {
        converted(entry.amount).minorUnits
    }

    private var calendar: Calendar { BillingMath.calendar }

    /// 事件按订阅分好一次，后面每个订阅只扫自己那一份。
    private var eventsBySubscription: [UUID: [SubscriptionEvent]] {
        var buckets: [UUID: [SubscriptionEvent]] = [:]
        for event in events {
            buckets[event.subscriptionID, default: []].append(event)
        }
        return buckets
    }

    // MARK: - 已记录支付

    /// 用户登记过的扣费。归档、停用都不清除历史：过去真花过的钱还在账上。
    func recordedEntries(now: Date = Date()) -> [Entry] {
        let ceiling = calendar.startOfDay(for: now)
        let ownerByID = Dictionary(uniqueKeysWithValues: subscriptions.map { ($0.id, $0) })
        var results: [Entry] = []
        for event in events {
            guard event.type == .charged || event.type == .inAppPurchase else { continue }
            guard let subscription = ownerByID[event.subscriptionID] else { continue }
            let day = calendar.startOfDay(for: event.happenedAt)
            guard day <= ceiling else { continue }
            if let amount = event.amount {
                results.append(Entry(subscription: subscription, date: day, amount: amount,
                                     origin: .recorded, amountIsUncertain: false))
            } else {
                // 登记了扣费但没填金额：按现价补一个数，并标成不确定。
                results.append(Entry(subscription: subscription, date: day, amount: subscription.myAmount,
                                     origin: .recorded, amountIsUncertain: true))
            }
        }
        return results.sorted { $0.date < $1.date }
    }

    // MARK: - 预计历史费用

    /// 按周期推算、落在今天之前的扣费。已经登记过的钱不再重复推算，暂停区间和
    /// 跳过的那一期也不算。
    func projectedEntries(now: Date = Date()) -> [Entry] {
        let ceiling = calendar.startOfDay(for: now)
        let grouped = eventsBySubscription
        var results: [Entry] = []
        for subscription in subscriptions where subscription.cycle.isRecurring {
            let mine = grouped[subscription.id] ?? []
            let suppressed = suppressedDays(for: mine, now: now)
            let changes = mine
                .filter { $0.type == .priceChanged && $0.amount != nil }
                .sorted { $0.happenedAt < $1.happenedAt }

            let days = historicalChargeDates(for: subscription, through: ceiling)
            let paid = days.filter { !suppressed.contains($0) }
            // 只拿「今天及以前」的登记去占用期数：填了个未来日期的登记不进已付账，
            // 也不该顺手吃掉一期推算，否则那笔钱两头都不见了。
            let consumed = consumedDays(days: paid,
                                        charges: mine.filter {
                                            ($0.type == .charged || $0.type == .inAppPurchase)
                                                && calendar.startOfDay(for: $0.happenedAt) <= ceiling
                                        })
            for day in paid where !consumed.contains(day) {
                let priced = priceOn(day, changes: changes, appliedTo: subscription)
                results.append(Entry(subscription: subscription, date: day, amount: priced.amount,
                                     origin: .projected, amountIsUncertain: priced.uncertain))
            }
        }
        return results.sorted { $0.date < $1.date }
    }

    /// 一笔登记对应的是哪一期：落在这一期周期里的那次扣费日。
    /// 用户常常晚一天才记（15 号扣的 16 号才登记），按「同一天」去重会漏，
    /// 于是同一笔钱既算已记录又算预计 —— 历史合计会凭空多一笔。
    /// `days` 升序，所以最后一个 <= 登记日的就是它所属的那一期。
    private func consumedDays(days: [Date], charges: [SubscriptionEvent]) -> Set<Date> {
        var consumed: Set<Date> = []
        for charge in charges {
            let day = calendar.startOfDay(for: charge.happenedAt)
            if let match = days.last(where: { $0 <= day }) { consumed.insert(match) }
        }
        return consumed
    }

    /// 从开始日一路推到今天的扣费日。这里不能复用 `BillingMath.chargeDates`：
    /// 那个函数带「还在册」的判断，而停用、归档订阅的过去同样花过钱。
    private func historicalChargeDates(for subscription: Subscription, through ceiling: Date) -> [Date] {
        let anchor = subscription.anchorDay
        let endDate = subscription.endDate.map { calendar.startOfDay(for: $0) }
        var results: [Date] = []
        var current = calendar.startOfDay(for: subscription.startDate)
        var guardCounter = 0
        while current <= ceiling {
            guardCounter += 1
            if guardCounter > 2400 { break }
            if endDate == nil || current <= endDate! { results.append(current) }
            guard let next = BillingMath.step(from: current,
                                              cycle: subscription.cycle,
                                              months: subscription.customMonths,
                                              anchorDay: anchor) else { break }
            current = next
        }
        return results
    }

    /// 一次性订阅的开始日：开始日已过就算一笔已发生的支出（没有周期可言）。
    /// 一次性只花一次，只要登记过扣费（哪天记的都算）就不再推算。
    private func oneTimeEntries(now: Date, grouped: [UUID: [SubscriptionEvent]]) -> [Entry] {
        let ceiling = calendar.startOfDay(for: now)
        return subscriptions.compactMap { subscription -> Entry? in
            guard !subscription.cycle.isRecurring else { return nil }
            let day = calendar.startOfDay(for: subscription.startDate)
            guard day <= ceiling else { return nil }
            let recorded = (grouped[subscription.id] ?? []).contains {
                ($0.type == .charged || $0.type == .inAppPurchase)
                    && calendar.startOfDay(for: $0.happenedAt) <= ceiling
            }
            guard !recorded else { return nil }
            return Entry(subscription: subscription, date: day, amount: subscription.myAmount,
                         origin: .projected, amountIsUncertain: false)
        }
    }

    /// 暂停区间 [paused, resumed) 内的日子 + 显式跳过的那一期。
    private func suppressedDays(for mine: [SubscriptionEvent], now: Date) -> Set<Date> {
        var days: Set<Date> = []
        var pausedAt: Date?
        let ceiling = calendar.startOfDay(for: now)
        for event in mine.sorted(by: { $0.happenedAt < $1.happenedAt }) {
            switch event.type {
            case .skipped:
                days.insert(calendar.startOfDay(for: event.happenedAt))
            case .paused:
                // 暂停当天起往后都按停着算，直到恢复。
                pausedAt = calendar.startOfDay(for: event.happenedAt)
            case .resumed:
                if let from = pausedAt {
                    days.formUnion(dayRun(from: from, before: calendar.startOfDay(for: event.happenedAt)))
                    pausedAt = nil
                }
            default:
                break
            }
        }
        // 一直没恢复：从暂停日推到今天。
        if let from = pausedAt {
            days.formUnion(dayRun(from: from, upTo: ceiling))
        }
        return days
    }

    private func dayRun(from start: Date, before end: Date) -> [Date] {
        var result: [Date] = []
        var cursor = start
        while cursor < end {
            result.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    private func dayRun(from start: Date, upTo end: Date) -> [Date] {
        dayRun(from: start, before: calendar.date(byAdding: .day, value: 1, to: end) ?? end)
    }

    /// 某天的价格：用过那天之前的最后一次调价；调价发生在那天之后说明旧价没留档，
    /// 只能拿现价估。
    private func priceOn(_ day: Date,
                         changes: [SubscriptionEvent],
                         appliedTo subscription: Subscription) -> (amount: Money, uncertain: Bool) {
        var applied: SubscriptionEvent?
        var hasLaterChange = false
        for change in changes {
            if calendar.startOfDay(for: change.happenedAt) <= day { applied = change }
            else { hasLaterChange = true }
        }
        if let amount = applied?.amount {
            return (amount, false)
        }
        return (subscription.myAmount, hasLaterChange)
    }

    // MARK: - 未来预计

    /// 今天起还会发生的扣费，一订阅一条（下一笔）。
    func upcomingEntries(now: Date = Date(), limit: Int = 12) -> [Entry] {
        subscriptions
            .filter(\.isTracked)
            .compactMap { subscription -> Entry? in
                guard subscription.cycle.isRecurring,
                      let date = BillingMath.nextChargeDate(for: subscription, onOrAfter: now) else { return nil }
                return Entry(subscription: subscription, date: date, amount: subscription.myAmount,
                             origin: .projected, amountIsUncertain: false)
            }
            .sorted { $0.date < $1.date }
            .prefix(limit)
            .map { $0 }
    }

    /// [lowerBound, upperBound) 内计划发生的全部扣费（未来口径，只算在册订阅）。
    func plannedEntries(in range: Range<Date>, floor: Date) -> [Entry] {
        var results: [Entry] = []
        for subscription in subscriptions where subscription.isTracked && subscription.cycle.isRecurring {
            for date in BillingMath.chargeDates(for: subscription, from: range.lowerBound, to: range.upperBound)
            where date >= floor {
                results.append(Entry(subscription: subscription,
                                     date: calendar.startOfDay(for: date),
                                     amount: subscription.myAmount,
                                     origin: .projected,
                                     amountIsUncertain: false))
            }
        }
        return results.sorted { $0.date < $1.date }
    }

    // MARK: - 合计

    /// 落在过去的全部扣费：已登记的与推算的互不重复。
    func pastEntries(now: Date = Date()) -> [Entry] {
        let grouped = eventsBySubscription
        var entries = recordedEntries(now: now) + projectedEntries(now: now)
        entries += oneTimeEntries(now: now, grouped: grouped)
        return entries.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.subscription.name < rhs.subscription.name
        }
    }

    func totals(now: Date = Date()) -> Totals {
        let entries = pastEntries(now: now)
        let recordedMinor = entries.filter { $0.origin == .recorded }.reduce(0) { $0 + convertedMinor($1) }
        let projectedMinor = entries.filter { $0.origin == .projected }.reduce(0) { $0 + convertedMinor($1) }
        let recordedCount = entries.filter { $0.origin == .recorded }.count

        var summaries: [UUID: SubscriptionSummary] = [:]
        for entry in entries {
            let key = entry.subscription.id
            let existing = summaries[key]
            let recorded = (existing?.recordedCount ?? 0) + (entry.origin == .recorded ? 1 : 0)
            let projected = (existing?.projectedCount ?? 0) + (entry.origin == .projected ? 1 : 0)
            let minor = (existing?.total.minorUnits ?? 0) + convertedMinor(entry)
            summaries[key] = SubscriptionSummary(
                subscription: entry.subscription,
                recordedCount: recorded,
                projectedCount: projected,
                total: Money(minorUnits: minor, currencyCode: defaultCurrency)
            )
        }
        let ordered = summaries.values.sorted { $0.total.minorUnits > $1.total.minorUnits }

        var coveredMonths = 1
        if let earliest = entries.map(\.date).min() {
            let months = calendar.dateComponents([.month],
                                                 from: calendar.startOfDay(for: earliest),
                                                 to: calendar.startOfDay(for: now)).month ?? 0
            coveredMonths = max(months + 1, 1)
        }
        let combinedMinor = recordedMinor + projectedMinor
        let monthlyAverageMinor = Money.scaled(combinedMinor, by: 1, over: coveredMonths)
        let perAverageMinor = Money.scaled(monthlyAverageMinor, by: 1, over: max(ordered.count, 1))
        let count = entries.count

        return Totals(
            recorded: Money(minorUnits: recordedMinor, currencyCode: defaultCurrency),
            projectedPast: Money(minorUnits: projectedMinor, currencyCode: defaultCurrency),
            combined: Money(minorUnits: combinedMinor, currencyCode: defaultCurrency),
            recordedCount: recordedCount,
            projectedCount: count - recordedCount,
            uncertainCount: entries.filter(\.amountIsUncertain).count,
            perSubscription: ordered,
            coveredMonths: coveredMonths,
            monthlyAverage: Money(minorUnits: monthlyAverageMinor, currencyCode: defaultCurrency),
            perSubscriptionAverage: Money(minorUnits: perAverageMinor, currencyCode: defaultCurrency),
            recordedShare: count == 0 ? 0 : Double(recordedCount) / Double(count)
        )
    }

    /// 按月分组：详情页的分期列表、小票都从这里取，保证是同一批数字。
    func monthlyBuckets(now: Date = Date()) -> [MonthBucket] {
        var buckets: [Date: (recorded: Int, projected: Int, recordedCount: Int, projectedCount: Int)] = [:]
        for entry in pastEntries(now: now) {
            let key = calendar.dateInterval(of: .month, for: entry.date)?.start ?? entry.date
            var bucket = buckets[key] ?? (0, 0, 0, 0)
            if entry.origin == .recorded {
                bucket.recorded += convertedMinor(entry)
                bucket.recordedCount += 1
            } else {
                bucket.projected += convertedMinor(entry)
                bucket.projectedCount += 1
            }
            buckets[key] = bucket
        }
        return buckets
            .map { start, value in
                MonthBucket(monthStart: start,
                            recorded: Money(minorUnits: value.recorded, currencyCode: defaultCurrency),
                            projected: Money(minorUnits: value.projected, currencyCode: defaultCurrency),
                            recordedCount: value.recordedCount,
                            projectedCount: value.projectedCount)
            }
            .sorted { $0.monthStart > $1.monthStart }
    }

    /// 最近 N 个自然月的合计（图表的柱子）。先建数据，绘制端只做插值。
    func monthlySeries(months: Int, now: Date = Date()) -> [(monthStart: Date, total: Money)] {
        let byMonth = Dictionary(grouping: pastEntries(now: now)) { entry -> Date in
            calendar.dateInterval(of: .month, for: entry.date)?.start ?? entry.date
        }
        var results: [(monthStart: Date, total: Money)] = []
        for offset in stride(from: months - 1, through: 0, by: -1) {
            guard let monthStart = calendar.date(byAdding: .month, value: -offset, to: now),
                  let interval = calendar.dateInterval(of: .month, for: monthStart) else { continue }
            let minor = (byMonth[interval.start] ?? []).reduce(0) { $0 + convertedMinor($1) }
            results.append((interval.start, Money(minorUnits: minor, currencyCode: defaultCurrency)))
        }
        return results
    }
}
