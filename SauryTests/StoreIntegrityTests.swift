import XCTest
import SwiftData
@testable import Saury

/// 数据体检（PR2d 的一致性检查）：数量、编号、金额、事件、图标引用。
final class StoreIntegrityTests: XCTestCase {
    private func subscription(
        id: UUID = UUID(),
        name: String = "Netflix",
        currency: String = "CNY",
        cycle: BillingCycle = .monthly,
        months: Int = 2,
        category: String = "video",
        iconFile: String? = nil
    ) -> Subscription {
        Subscription(id: id, name: name, iconImageFile: iconFile,
                     currencyCode: currency, cycle: cycle,
                     customMonths: months, category: category)
    }

    private func report(_ subscriptions: [Subscription], _ events: [SubscriptionEvent] = [],
                        categories: [SubscriptionCategory] = DefaultCategories.items,
                        iconExists: (String) -> Bool = { _ in true }) -> StoreIntegrityReport {
        StoreIntegrityReport.check(subscriptions: subscriptions, events: events,
                                   categories: categories, iconExists: iconExists)
    }

    func testHealthyLibraryReportsNothing() {
        let item = subscription()
        let event = SubscriptionEvent(subscriptionID: item.id, type: .charged,
                                      amountMinorUnits: 4500, currencyCode: "CNY")
        let outcome = report([item], [event])
        XCTAssertTrue(outcome.isClean, outcome.issues.map(\.detail).description)
        XCTAssertEqual(outcome.subscriptionCount, 1)
        XCTAssertEqual(outcome.eventCount, 1)
        XCTAssertEqual(outcome.summaryText, "1 条订阅、1 条事件，没查出问题。")
    }

    /// 事件数量：认不出主人的事件必须被点名，统计口径才不会把它算成某条订阅的钱。
    func testOrphanEventsAreCounted() {
        let kept = subscription()
        let orphan = SubscriptionEvent(subscriptionID: UUID(), type: .charged, amountMinorUnits: 100)
        let outcome = report([kept], [orphan, orphan, orphan])
        XCTAssertEqual(outcome.issues.filter { $0.kind == .orphanEvent }.count, 1)
        XCTAssertTrue(outcome.issues[0].detail.contains("3 条事件找不到对应的订阅"), outcome.issues[0].detail)
    }

    func testDuplicateIDsAcrossRowsAreCaught() {
        let id = UUID()
        let outcome = report([subscription(id: id, name: "A 号"), subscription(id: id, name: "B 号")])
        let issue = outcome.issues.first { $0.kind == .duplicateID }
        XCTAssertNotNil(issue)
        XCTAssertTrue(issue?.detail.contains("A 号、B 号") == true, issue?.detail ?? "")
    }

    func testMissingIconFileIsNamed() {
        let item = subscription(iconFile: "ABC.png")
        let outcome = report([item], iconExists: { _ in false })
        XCTAssertTrue(outcome.issues.contains { $0.kind == .missingIcon && $0.detail.contains("ABC.png") })
    }

    /// 分类编号认不出来不算坏数据，但列表会把它显示成「其他」，得提前说。
    func testUnknownCategoryIsReported() {
        let outcome = report([subscription(category: "from-another-build")])
        XCTAssertTrue(outcome.issues.contains { $0.kind == .unknownCategory })
    }

    func testBlankNameAndBadCurrencyAndBrokenCycle() {
        let blank = subscription(name: "   ")
        let badCurrency = subscription(name: "贵", currency: "CN")
        let badCycle = Subscription(id: UUID(), name: "怪", cycle: .custom, customMonths: 0)
        badCycle.customMonths = 0
        let early = Subscription(id: UUID(), name: "倒着来", startDate: Date(timeIntervalSince1970: 10_000),
                                 endDate: Date(timeIntervalSince1970: 1_000))
        let outcome = report([blank, badCurrency, badCycle, early])
        XCTAssertEqual(outcome.issues.filter { $0.kind == .blankName }.count, 1)
        XCTAssertEqual(outcome.issues.filter { $0.kind == .badCurrency }.count, 1)
        XCTAssertEqual(outcome.issues.filter { $0.kind == .badCycle }.count, 2)
        XCTAssertTrue(outcome.issues.contains { $0.detail.contains("名字是空的") })
    }

    /// 空库不是问题：一条数据都没有时不该吓唬人。
    func testEmptyLibraryIsClean() {
        XCTAssertTrue(report([], []).isClean)
        XCTAssertEqual(report([], []).summaryText, "0 条订阅、0 条事件，没查出问题。")
    }

    /// 体检只列问题，不许顺手改数据。
    func testCheckDoesNotMutateRows() {
        let item = subscription(iconFile: "gone.png")
        item.categoryRawValue = "nope"
        _ = report([item], iconExists: { _ in false })
        XCTAssertEqual(item.iconImageFile, "gone.png")
        XCTAssertEqual(item.categoryRawValue, "nope")
        XCTAssertEqual(item.customMonths, 2)
        XCTAssertEqual(item.currencyCode, "CNY")
    }
}
