import XCTest
@testable import Saury

final class MoneyTests: XCTestCase {
    func testFormatting() {
        XCTAssertEqual(Money(minorUnits: 13414, currencyCode: "CNY").formatted, "¥134.14")
        XCTAssertEqual(Money(minorUnits: 2000, currencyCode: "USD").formatted, "$20.00")
        XCTAssertEqual(Money(minorUnits: 242564, currencyCode: "CNY").formattedGrouped, "¥2,425.64")
        XCTAssertEqual(Money(minorUnits: 5, currencyCode: "EUR").formatted, "€0.05")
        XCTAssertEqual(Money(minorUnits: -100, currencyCode: "CNY").formatted, "-¥1.00")
    }

    /// 存储刻度全币种都是 ×100，小数位只影响展示：日元不会变成 1200.00。
    func testCurrencyPrecisionDrivesDisplay() {
        XCTAssertEqual(CurrencyCatalog.decimals(for: "CNY"), 2)
        XCTAssertEqual(CurrencyCatalog.decimals(for: "USD"), 2)
        XCTAssertEqual(CurrencyCatalog.decimals(for: "JPY"), 0)
        XCTAssertEqual(CurrencyCatalog.decimals(for: "KRW"), 0)
        XCTAssertEqual(CurrencyCatalog.decimals(for: "VND"), 0)
        // 表里没有的币种按两位处理。
        XCTAssertEqual(CurrencyCatalog.decimals(for: "XXX"), 2)

        XCTAssertEqual(Money(minorUnits: 120000, currencyCode: "JPY").formatted, "¥1200")
        XCTAssertEqual(Money(minorUnits: 1500000, currencyCode: "KRW").formattedGrouped, "₩15,000")
        XCTAssertEqual(Money(minorUnits: 120000, currencyCode: "JPY").amountText, "1200")
    }

    // MARK: - 解析

    private func parsed(_ text: String, _ code: String, _ separators: MoneyParsing.Separators = .english) -> Int? {
        try? MoneyParsing.parse(text, currencyCode: code, separators: separators).get().minorUnits
    }

    func testParseAcceptanceAmounts() {
        XCTAssertEqual(parsed("12.34", "CNY"), 1234)
        XCTAssertEqual(parsed("19.99", "USD"), 1999)
        XCTAssertEqual(parsed("1200", "JPY"), 120_000)
        XCTAssertEqual(parsed("15000", "KRW"), 1_500_000)
        XCTAssertEqual(parsed("0", "CNY"), 0)
        XCTAssertEqual(parsed("9999999999999", "CNY"), 999_999_999_999_900)
    }

    func testParseSeparatorsAndSymbols() {
        XCTAssertEqual(parsed("1,234.56", "CNY"), 123_456)
        XCTAssertEqual(parsed("1,234", "CNY"), 123_400, "规范千分位")
        XCTAssertEqual(parsed("12,5", "CNY"), 1250, "不是千分位形状就当小数点")
        XCTAssertEqual(parsed("¥ 25", "CNY"), 2500)
        XCTAssertEqual(parsed(" 25 ", "CNY"), 2500)
        // 德语环境里小数点和千分位反过来。
        XCTAssertEqual(parsed("1.234", "EUR", .continental), 123_400)
        XCTAssertEqual(parsed("1,5", "EUR", .continental), 150)
    }

    func testParseRejectsInvalidInput() {
        XCTAssertEqual(MoneyParsing.parse("-5", currencyCode: "CNY", separators: .english),
                       .failure(.negative))
        XCTAssertEqual(MoneyParsing.parse("1a2", currencyCode: "CNY", separators: .english),
                       .failure(.notANumber))
        XCTAssertEqual(MoneyParsing.parse("", currencyCode: "CNY", separators: .english),
                       .failure(.empty))
        // 币种精度：日元没有小数位。
        XCTAssertEqual(MoneyParsing.parse("1200.5", currencyCode: "JPY", separators: .english),
                       .failure(.tooManyFractionDigits(allowed: 0)))
        XCTAssertEqual(MoneyParsing.parse("1.234", currencyCode: "CNY", separators: .english),
                       .failure(.tooManyFractionDigits(allowed: 2)))
        XCTAssertEqual(MoneyParsing.parse("123456789012345678", currencyCode: "CNY", separators: .english),
                       .failure(.tooLarge))
        // 空串不算格式错误，交给必填校验。
        XCTAssertNil(MoneyParsing.validate("", currencyCode: "CNY", separators: .english))
    }

    /// 反复编辑不能把金额改漂：解析 → 回填 → 再解析必须一模一样。
    func testRepeatedEditingDoesNotDrift() {
        for (text, code) in [("12.34", "CNY"), ("19.99", "USD"), ("1200", "JPY"), ("15000", "KRW"), ("0.05", "EUR")] {
            var current = text
            for _ in 0..<5 {
                let money = try? MoneyParsing.parse(current, currencyCode: code, separators: .english).get()
                XCTAssertNotNil(money, "\(code) \(text) 应该能解析")
                current = money?.amountText ?? ""
            }
            XCTAssertEqual(try? MoneyParsing.parse(current, currencyCode: code, separators: .english).get().minorUnits,
                           try? MoneyParsing.parse(text, currencyCode: code, separators: .english).get().minorUnits)
        }
    }

    // MARK: - 换算与分摊

    func testConversionUsesRatesTable() {
        // 1 USD = 7 CNY, 1 EUR = 0.5 USD。
        let rates = ["USD": 1.0, "CNY": 7.0, "EUR": 0.5]
        let usd = Money(minorUnits: 2000, currencyCode: "USD")
        XCTAssertEqual(usd.converting(to: "CNY", rates: rates).minorUnits, 14000)
        XCTAssertEqual(usd.converting(to: "EUR", rates: rates).minorUnits, 1000)
        // 缺币种按 1:1 兜底。
        XCTAssertEqual(usd.converting(to: "JPY", rates: rates).minorUnits, 2000)
        XCTAssertEqual(usd.converting(to: "USD", rates: rates).minorUnits, 2000)
        // 汇率更新只影响展示，不动存储的数字。
        XCTAssertEqual(usd.converting(to: "CNY", rates: ["USD": 1.0, "CNY": 7.5]).minorUnits, 15000)
        XCTAssertEqual(usd.minorUnits, 2000)
    }

    func testConversionDirectionStaysUsdBased() {
        // 表按「1 USD = n 目标币」存，换算 = 原值 × rates[to] / rates[from]。
        let rates = ["USD": 1.0, "JPY": 152.0, "CNY": 7.0]
        // $1.00 → ¥152，而 152 在主单位 ×100 的刻度下是 15200。
        XCTAssertEqual(Money(minorUnits: 100, currencyCode: "USD").converting(to: "JPY", rates: rates).minorUnits, 15_200)
        // 反向取整：¥152 回美元。
        XCTAssertEqual(Money(minorUnits: 15_200, currencyCode: "JPY").converting(to: "USD", rates: rates).minorUnits, 100)
        // 两边都不在美元上：CNY → JPY 仍然只隔一层比例。
        XCTAssertEqual(Money(minorUnits: 700, currencyCode: "CNY").converting(to: "JPY", rates: rates).minorUnits, 15_200)
        // 最小单位的换算也保持半进位：$0.01 → 7.5 元刻度就是 8。
        XCTAssertEqual(Money(minorUnits: 1, currencyCode: "USD").converting(to: "CNY",
                                                                            rates: ["USD": 1, "CNY": 7.5]).minorUnits, 8)
        // 零小数位币种照样落在 ×100 的存储刻度上：$1 = ¥152 → 15200，展示时才收成 152。
        XCTAssertEqual(Money(minorUnits: 100, currencyCode: "USD").converting(to: "VND",
                                                                              rates: ["USD": 1, "VND": 25400]).minorUnits, 2_540_000)
        XCTAssertEqual(Money(minorUnits: 2_540_000, currencyCode: "VND").formattedGrouped, "₫25,400")
    }

    func testEvenShareIsIntegerHalfUp() {
        XCTAssertEqual(Money.evenShare(totalMinorUnits: 1000, headcount: 3), 333, "¥10 三人分摊")
        XCTAssertEqual(Money.evenShare(totalMinorUnits: 1001, headcount: 3), 334)
        XCTAssertEqual(Money.evenShare(totalMinorUnits: 5, headcount: 2), 3, "半进位")
        XCTAssertEqual(Money.evenShare(totalMinorUnits: 1, headcount: 4), 0)
        XCTAssertEqual(Money.evenShare(totalMinorUnits: 0, headcount: 3), 0)
        XCTAssertEqual(Money.evenShare(totalMinorUnits: 100, headcount: 0), 100, "人数兜底为 1")
    }

    func testScaledMatchesConversionRounding() {
        XCTAssertEqual(Money.scaled(2000, by: 52, over: 12), 8667, "周付折算到月")
        XCTAssertEqual(Money.scaled(3000, by: 1, over: 12), 250)
        XCTAssertEqual(Money.scaled(1000, by: 1, over: 0), 1000, "除 0 兜底不动数")
    }

    func testCurrencyCatalogHasEssentials() {
        for code in ["CNY", "USD", "EUR", "JPY"] {
            XCTAssertNotNil(CurrencyCatalog.entry(for: code))
        }
        XCTAssertEqual(CurrencyCatalog.symbol(for: "USD"), "$")
    }
}

/// 统计口径。所有页面看到的「本月多少」都从 SubscriptionStats 出，这里守住数字。
final class SubscriptionStatsTestsSuite: XCTestCase {
    private var calendar: Calendar { BillingMath.calendar }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 9))!
    }

    private var rates: [String: Double] {
        ["USD": 1.0, "CNY": 7.0]
    }

    private var now: Date { date(2026, 10, 11) }

    private func makeStats(_ subscriptions: [Subscription],
                           events: [SubscriptionEvent] = [],
                           currency: String = "CNY") -> SubscriptionStats {
        SubscriptionStats(subscriptions: subscriptions,
                          events: events,
                          defaultCurrency: currency,
                          rates: rates)
    }

    private func subscription(
        name: String,
        price: Int,
        currency: String = "CNY",
        cycle: BillingCycle = .monthly,
        category: String = "video",
        startDate: Date,
        state: SubscriptionState = .autoRenew
    ) -> Subscription {
        Subscription(
            name: name,
            priceMinorUnits: price,
            currencyCode: currency,
            cycle: cycle,
            category: category,
            state: state,
            startDate: startDate
        )
    }

    func testRecurringTotalNormalizesToMonthly() {
        let chatGPT = subscription(name: "ChatGPT", price: 2000, currency: "USD", category: "ai", startDate: now)
        let iCloud = subscription(name: "iCloud", price: 6800, category: "cloud", startDate: date(2026, 10, 12))
        let stats = makeStats([chatGPT, iCloud])
        // $20 × 7 + ¥68 = ¥208。
        XCTAssertEqual(stats.recurringTotal().minorUnits, 20800)
        XCTAssertEqual(stats.total(for: .quarter).minorUnits, 20800 * 3)
        XCTAssertEqual(stats.total(for: .year).minorUnits, 20800 * 12)
    }

    /// 折算到月只有一套舍入：周付 ×52/12、年付 ÷12 都是半进位，列表页和总览同数。
    func testMonthlyNormalizationRoundsHalfUp() {
        let weekly = subscription(name: "周付", price: 1999, cycle: .weekly, startDate: now)
        XCTAssertEqual(BillingMath.monthlyNormalized(weekly)?.minorUnits, 8662, "19.99×52/12 = 86.623 → 86.62")
        let yearly = subscription(name: "年付", price: 1001, cycle: .yearly, startDate: now)
        XCTAssertEqual(BillingMath.monthlyNormalized(yearly)?.minorUnits, 83, "1001/12 = 83.4 → 83")
        let bumped = subscription(name: "年付", price: 999, cycle: .yearly, startDate: now)
        XCTAssertEqual(BillingMath.monthlyNormalized(bumped)?.minorUnits, 83, "999/12 = 83.25 → 83")
        let halfUp = subscription(name: "年付", price: 18, cycle: .yearly, startDate: now)
        XCTAssertEqual(BillingMath.monthlyNormalized(halfUp)?.minorUnits, 2, "18/12 = 1.5 → 2，半进位")
    }

    func testPeriodChargeTotalCountsChargesInWindow() {
        // 从 10 月 11 日开始，10 月里只有今天这一笔。
        let chatGPT = subscription(name: "ChatGPT", price: 2000, currency: "USD", category: "ai", startDate: now)
        let stats = makeStats([chatGPT])
        XCTAssertEqual(stats.periodChargeTotal(for: .month, now: now).minorUnits, 14000)
        // 季度里有 3 笔。
        XCTAssertEqual(stats.periodChargeTotal(for: .quarter, now: now).minorUnits, 42000)
    }

    func testOneTimeDoesNotCountInRecurring() {
        let passport = subscription(name: "护照", price: 10000, cycle: .oneTime, startDate: now)
        let stats = makeStats([passport])
        XCTAssertEqual(stats.recurringTotal().minorUnits, 0)
        XCTAssertEqual(stats.upcomingCharges(from: now).count, 0)
    }

    func testUpcomingChargesSortedByDate() {
        let later = subscription(name: "后扣", price: 1000, startDate: date(2026, 10, 20))
        let today = subscription(name: "先扣", price: 2000, startDate: now)
        let stats = makeStats([later, today])
        let charges = stats.upcomingCharges(from: now)
        XCTAssertEqual(charges.count, 2, "一卡一订阅：每个订阅只出下一笔")
        XCTAssertEqual(charges[0].subscription.name, "先扣")
        XCTAssertTrue(calendar.isDate(charges[0].date, inSameDayAs: now))
        XCTAssertEqual(charges[1].subscription.name, "后扣")
    }

    func testCategorySlicesShareToOneHundred() {
        let a = subscription(name: "A", price: 3000, category: "video", startDate: now)
        let b = subscription(name: "B", price: 1000, category: "ai", startDate: now)
        let stats = makeStats([a, b])
        let slices = stats.categorySlices(preferences: DefaultCategories.items)
        XCTAssertEqual(slices.count, 2)
        let shareSum = slices.reduce(0.0) { $0 + $1.share }
        XCTAssertEqual(shareSum, 1.0, accuracy: 0.001)
        XCTAssertEqual(slices.first?.category.id, "video", "占大头的排前面")
    }

    /// 累计必须拆成「已登记」和「预计」两个数：只报合计就是把推算说成实付。
    func testCumulativeSplitsRecordedFromProjected() {
        // 8 月 11 日开始月付，到 10 月 11 日该扣 8/11、9/11、10/11 共三笔。
        let started = subscription(name: "老订阅", price: 1000, startDate: date(2026, 8, 11))
        let notYet = subscription(name: "新订阅", price: 1000, startDate: date(2026, 10, 12))
        let paid = SubscriptionEvent(subscriptionID: started.id, type: .charged,
                                     amountMinorUnits: 1000, currencyCode: "CNY",
                                     happenedAt: date(2026, 8, 11))
        let stats = makeStats([started, notYet], events: [paid])
        let cumulative = stats.cumulative(now: now)
        XCTAssertEqual(cumulative.chargeCount, 3)
        XCTAssertEqual(cumulative.recordedCount, 1)
        XCTAssertEqual(cumulative.projectedCount, 2)
        XCTAssertEqual(cumulative.recorded.minorUnits, 1000)
        XCTAssertEqual(cumulative.projectedPast.minorUnits, 2000)
        XCTAssertEqual(cumulative.combined.minorUnits, 3000)
        XCTAssertEqual(cumulative.perSubscription.first?.chargeCount, 3)
    }

    func testChargesOnSpecificDay() {
        let chatGPT = subscription(name: "ChatGPT", price: 2000, currency: "USD", startDate: date(2026, 9, 11))
        let stats = makeStats([chatGPT])
        let on11th = stats.charges(on: date(2026, 10, 11), now: now)
        XCTAssertEqual(on11th.count, 1)
        let on12th = stats.charges(on: date(2026, 10, 12), now: now)
        XCTAssertTrue(on12th.isEmpty)
    }

    func testTrendBarsHasLatestMonthHighlighted() {
        let subject = subscription(name: "A", price: 1000, startDate: date(2026, 4, 1))
        let stats = makeStats([subject])
        let bars = stats.trendBars(months: 6, now: now)
        XCTAssertEqual(bars.count, 6)
        XCTAssertTrue(bars.last?.highlighted ?? false)
        XCTAssertEqual(bars.last?.value ?? 0, 1000, "10 月已有今天的扣费")
    }

    func testArchivedAndDeletedAreExcluded() {
        let active = subscription(name: "正常", price: 1000, startDate: now)
        let archived = subscription(name: "归档", price: 9000, startDate: now)
        archived.archivedAt = Date()
        let deleted = subscription(name: "回收站", price: 9000, startDate: now)
        deleted.deletedAt = Date()
        let inactive = subscription(name: "停用", price: 9000, startDate: now, state: .inactive)
        let stats = makeStats([active, archived, deleted, inactive])
        XCTAssertEqual(stats.recurringTotal().minorUnits, 1000)
        XCTAssertEqual(stats.upcomingCharges(from: now).count, 1, "只有「正常」还在产生扣费")
    }
}

/// 「过去花过多少」的账本。已登记的和推算的必须互不重复、各算各的。
final class SubscriptionLedgerTests: XCTestCase {
    private var calendar: Calendar { BillingMath.calendar }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 9))!
    }

    private var now: Date { date(2026, 10, 11) }

    private func subscription(name: String = "A",
                              price: Int = 1000,
                              currency: String = "CNY",
                              cycle: BillingCycle = .monthly,
                              startDate: Date,
                              state: SubscriptionState = .autoRenew) -> Subscription {
        Subscription(name: name, priceMinorUnits: price, currencyCode: currency,
                     cycle: cycle, state: state, startDate: startDate)
    }

    private func event(_ sub: Subscription,
                       _ type: SubscriptionEventType,
                       amount: Int? = nil,
                       on day: Date) -> SubscriptionEvent {
        SubscriptionEvent(subscriptionID: sub.id, type: type,
                          amountMinorUnits: amount ?? 0,
                          currencyCode: amount == nil ? "" : sub.currencyCode,
                          happenedAt: day)
    }

    private func ledger(_ subs: [Subscription], _ events: [SubscriptionEvent] = []) -> SubscriptionLedger {
        SubscriptionLedger(subscriptions: subs, events: events,
                           defaultCurrency: "CNY", rates: ["USD": 1.0, "CNY": 7.0])
    }

    func testProjectedPastCountsEveryCycleUpToToday() {
        let sub = subscription(startDate: date(2026, 8, 11))
        let result = ledger([sub]).totals(now: now)
        XCTAssertEqual(result.projectedCount, 3, "8/11、9/11、10/11")
        XCTAssertEqual(result.recordedCount, 0)
        XCTAssertEqual(result.combined.minorUnits, 3000)
        XCTAssertEqual(result.projectedPast.minorUnits, 3000)
        XCTAssertEqual(result.recordedShare, 0, accuracy: 0.001, "一笔都没登记：这个数全是推算")
    }

    /// 用户登记过的日子按登记的算，那一期的推算同时消失 —— 不能一笔钱数两遍。
    func testRecordedEntryReplacesThatCyclesProjection() {
        let sub = subscription(startDate: date(2026, 8, 11))
        let result = ledger([sub], [event(sub, .charged, amount: 1200, on: date(2026, 9, 11))]).totals(now: now)
        XCTAssertEqual(result.chargeCount, 3, "总数还是三期")
        XCTAssertEqual(result.recordedCount, 1)
        XCTAssertEqual(result.projectedCount, 2)
        XCTAssertEqual(result.recorded.minorUnits, 1200, "登记价与现价不同时以登记价为准")
        XCTAssertEqual(result.projectedPast.minorUnits, 2000)
        XCTAssertEqual(result.combined.minorUnits, 3200)
        XCTAssertEqual(result.recordedShare, 1 / 3, accuracy: 0.001)
    }

    /// 扣费常在几天后才补记，得认成同一期，否则历史合计凭空多一笔。
    func testLateRegistrationDoesNotDoubleCount() {
        let sub = subscription(startDate: date(2026, 9, 11))
        let result = ledger([sub], [event(sub, .charged, amount: 1000, on: date(2026, 9, 14))]).totals(now: now)
        XCTAssertEqual(result.chargeCount, 2, "9/11 补记 + 10/11 推算")
        XCTAssertEqual(result.recordedCount, 1)
        XCTAssertEqual(result.projectedCount, 1)
        XCTAssertEqual(result.combined.minorUnits, 2000)
    }

    /// 登记日早于开始日属于另一笔钱（预付、代付），不能占掉第一期的推算。
    func testEarlyRegistrationKeepsFirstCycleProjected() {
        let sub = subscription(startDate: date(2026, 9, 11))
        let result = ledger([sub], [event(sub, .charged, amount: 1000, on: date(2026, 9, 5))]).totals(now: now)
        XCTAssertEqual(result.recordedCount, 1)
        XCTAssertEqual(result.projectedCount, 2)
        XCTAssertEqual(result.combined.minorUnits, 3000)
    }

    /// 日期填到未来的登记既不进已付账，也不该顺手吃掉一期推算。
    func testFutureDatedRegistrationConsumesNothing() {
        let sub = subscription(startDate: date(2026, 9, 11))
        let result = ledger([sub], [event(sub, .charged, amount: 1000, on: date(2026, 10, 15))]).totals(now: now)
        XCTAssertEqual(result.recordedCount, 0, "还没发生的登记不算已付")
        XCTAssertEqual(result.projectedCount, 2, "9/11、10/11 两期都还在")
        XCTAssertEqual(result.combined.minorUnits, 2000)
    }

    func testAmountlessRecordedEventIsFlaggedUncertain() {
        let sub = subscription(price: 1500, startDate: date(2026, 10, 11))
        let result = ledger([sub], [event(sub, .charged, on: date(2026, 10, 11))]).totals(now: now)
        XCTAssertEqual(result.recordedCount, 1)
        XCTAssertEqual(result.projectedCount, 0)
        XCTAssertEqual(result.combined.minorUnits, 1500, "没填金额就按现价补")
        XCTAssertEqual(result.uncertainCount, 1, "补出来的数要标不确定")
    }

    func testPausedAndSkippedCyclesAreNotProjected() {
        let sub = subscription(startDate: date(2026, 7, 15))
        let events = [event(sub, .paused, on: date(2026, 8, 1)),
                      event(sub, .resumed, on: date(2026, 9, 20)),
                      event(sub, .skipped, on: date(2026, 10, 15))]
        // 推算只看今天之前：7/15、8/15（暂停中）、9/15（暂停中）→ 只剩 7/15。
        let result = ledger([sub], events).totals(now: now)
        XCTAssertEqual(result.projectedCount, 1)
        XCTAssertEqual(result.combined.minorUnits, 1000)
    }

    func testOpenEndedPauseStopsProjection() {
        let sub = subscription(startDate: date(2026, 6, 1))
        let result = ledger([sub], [event(sub, .paused, on: date(2026, 7, 1))]).totals(now: now)
        XCTAssertEqual(result.projectedCount, 1, "只有暂停前的 6/1")
        XCTAssertEqual(result.combined.minorUnits, 1000)
    }

    func testPriceChangesAreAppliedFromTheirOwnCycle() {
        let sub = subscription(price: 2000, startDate: date(2026, 1, 15))
        let raised = event(sub, .priceChanged, amount: 1200, on: date(2026, 6, 15))
        let result = ledger([sub], [raised]).totals(now: now)
        // 1..5 月调价前没有留档价，只能拿现价估并标不确定；6 月起用登记过的旧价。
        XCTAssertEqual(result.projectedCount, 9, "1/15 到 9/15")
        XCTAssertEqual(result.uncertainCount, 5)
        XCTAssertEqual(result.combined.minorUnits, 5 * 2000 + 4 * 1200)
    }

    func testArchivedHistoryStillCountsButFutureDoesNot() {
        let sub = subscription(name: "归档", price: 1000, startDate: date(2026, 8, 11))
        sub.archivedAt = now
        let result = ledger([sub]).totals(now: now)
        XCTAssertEqual(result.projectedCount, 3, "过去真花过的钱还在账上")
        XCTAssertTrue(ledger([sub]).upcomingEntries(now: now).isEmpty, "归档了就不该再有下一次")
    }

    func testOneTimeCountsOnceAndYieldsToRecordedPayment() {
        let sub = subscription(name: "买断", price: 5000, cycle: .oneTime, startDate: date(2026, 9, 1))
        let bare = ledger([sub]).totals(now: now)
        XCTAssertEqual(bare.projectedCount, 1)
        XCTAssertEqual(bare.combined.minorUnits, 5000)

        let paid = ledger([sub], [event(sub, .charged, amount: 4800, on: date(2026, 9, 3))]).totals(now: now)
        XCTAssertEqual(paid.recordedCount, 1)
        XCTAssertEqual(paid.projectedCount, 0, "一次性只花一次，登记过就不再推算")
        XCTAssertEqual(paid.combined.minorUnits, 4800)
    }

    func testFutureSubscriptionHasNoPastEntries() {
        let sub = subscription(startDate: date(2026, 12, 1))
        let result = ledger([sub]).totals(now: now)
        XCTAssertEqual(result.chargeCount, 0)
        XCTAssertEqual(result.combined.minorUnits, 0)
        XCTAssertEqual(result.coveredMonths, 1, "没有记录也不能除以 0")
    }

    func testRecordedEventsForMissingSubscriptionAreIgnored() {
        let orphan = SubscriptionEvent(subscriptionID: UUID(), type: .charged,
                                       amountMinorUnits: 9999, currencyCode: "CNY",
                                       happenedAt: date(2026, 9, 1))
        let result = ledger([subscription(startDate: date(2026, 10, 11))], [orphan]).totals(now: now)
        XCTAssertEqual(result.combined.minorUnits, 1000, "只算还在这份数据里的订阅")
        XCTAssertEqual(result.recordedCount, 0)
    }

    func testCrossCurrencyHistoryConvertsIntoDefaultCurrency() {
        let sub = subscription(price: 2000, currency: "USD", startDate: date(2026, 8, 11))
        let result = ledger([sub]).totals(now: now)
        XCTAssertEqual(result.combined.minorUnits, 3 * 14000, "$20 × 7 × 3 期")
        XCTAssertEqual(result.combined.currencyCode, "CNY")
    }

    func testMonthBucketsAndSeriesAgreeWithTotals() {
        let sub = subscription(startDate: date(2026, 7, 11))
        let subject = ledger([sub], [event(sub, .charged, amount: 1000, on: date(2026, 8, 11))])
        let totals = subject.totals(now: now)
        let buckets = subject.monthlyBuckets(now: now)
        XCTAssertEqual(buckets.count, 4, "7、8、9、10 月")
        let sum = buckets.reduce(0) { $0 + $1.total.minorUnits }
        XCTAssertEqual(sum, totals.combined.minorUnits, "分月加起来必须等于合计")
        let recordedSum = buckets.reduce(0) { $0 + $1.recorded.minorUnits }
        XCTAssertEqual(recordedSum, totals.recorded.minorUnits)
        let august = buckets.first { $0.monthStart == calendar.startOfDay(for: date(2026, 8, 1)) }
        XCTAssertEqual(august?.recordedCount, 1)
        XCTAssertEqual(august?.projectedCount, 0)

        let series = subject.monthlySeries(months: 4, now: now)
        XCTAssertEqual(series.count, 4)
        XCTAssertEqual(series.last?.total.minorUnits, 1000, "10 月只有 10/11 这一笔")
    }

    func testMonthlyAverageUsesCoveredMonths() {
        let sub = subscription(price: 1000, startDate: date(2026, 8, 11))
        let result = ledger([sub]).totals(now: now)
        XCTAssertEqual(result.coveredMonths, 3, "8、9、10 三个月")
        XCTAssertEqual(result.monthlyAverage.minorUnits, 1000)
        XCTAssertEqual(result.perSubscriptionAverage.minorUnits, 1000)
    }

    // MARK: - 未来预计（第 3 类数字，不能和已付混排）

    func testUpcomingEntriesAreProjectedOnly() {
        let sub = subscription(startDate: date(2026, 10, 20))
        let entries = ledger([sub]).upcomingEntries(now: now)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].origin, .projected)
        XCTAssertTrue(calendar.isDate(entries[0].date, inSameDayAs: date(2026, 10, 20)))
    }

    func testPlannedEntriesIgnorePastDaysInWindow() {
        // 周付，10 月里有 5、12、19、26 四天，其中 10/5 已经过去。
        let sub = subscription(cycle: .weekly, startDate: date(2026, 9, 28))
        let entries = ledger([sub]).plannedEntries(in: date(2026, 10, 1)..<date(2026, 11, 1),
                                                   floor: calendar.startOfDay(for: now))
        XCTAssertEqual(entries.count, 3, "本月只剩今天及以后的三笔")
        XCTAssertTrue(calendar.isDate(entries[0].date, inSameDayAs: date(2026, 10, 12)))
        XCTAssertTrue(calendar.isDate(entries.last?.date ?? .distantPast, inSameDayAs: date(2026, 10, 26)))
    }
}
