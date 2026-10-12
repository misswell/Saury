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

    func testConversionUsesRatesTable() {
        // 1 USD = 7 CNY, 1 EUR = 0.5 USD。
        let rates = ["USD": 1.0, "CNY": 7.0, "EUR": 0.5]
        let usd = Money(minorUnits: 2000, currencyCode: "USD")
        XCTAssertEqual(usd.converting(to: "CNY", rates: rates).minorUnits, 14000)
        XCTAssertEqual(usd.converting(to: "EUR", rates: rates).minorUnits, 1000)
        // 缺币种按 1:1 兜底。
        XCTAssertEqual(usd.converting(to: "JPY", rates: rates).minorUnits, 2000)
        XCTAssertEqual(usd.converting(to: "USD", rates: rates).minorUnits, 2000)
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

    private func makeStats(_ subscriptions: [Subscription], currency: String = "CNY") -> SubscriptionStats {
        SubscriptionStats(subscriptions: subscriptions, defaultCurrency: currency, rates: rates)
    }

    private var now: Date { date(2026, 10, 11) }

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

    func testCumulativeCountsPastChargesOnly() {
        // 8 月 11 日开始月付，到 10 月 11 日扣了 8/11、9/11、10/11 共三笔。
        let started = subscription(name: "老订阅", price: 1000, startDate: date(2026, 8, 11))
        let notYet = subscription(name: "新订阅", price: 1000, startDate: date(2026, 10, 12))
        let stats = makeStats([started, notYet])
        let cumulative = stats.cumulative(now: now)
        XCTAssertEqual(cumulative.chargeCount, 3)
        XCTAssertEqual(cumulative.total.minorUnits, 3000)
        XCTAssertEqual(cumulative.perSubscription.first?.count, 3)
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
