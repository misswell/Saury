import XCTest
import SwiftData
@testable import Saury

/// 处理动作和撤销（方案 §35、§37）。
@MainActor
final class ExpiryRepositoryTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private let calendar = ExpiryEngine.calendar
    /// 每个用例一个固定的「今天」：Date() 每次调用都不同，直接比会假失败。
    private let reference = Date()

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Schema(versionedSchema: SaurySchemaV3.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = container.mainContext
    }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: reference) ?? reference
    }

    private func events(for item: ExpiryItem) -> [ExpiryEvent] {
        ((try? context.fetch(FetchDescriptor<ExpiryEvent>())) ?? []).filter { $0.itemID == item.id }
    }

    func testMarkingAnItemConsumedWritesStateAndExactlyOneEvent() throws {
        let item = ExpiryItem(name: "酸奶", category: .food, expiryDate: day(-1))
        context.insert(item)
        try context.save()

        XCTAssertNotNil(ExpiryRepository(context: context).perform(.consumed, on: item))
        XCTAssertEqual(item.state, .consumed)
        XCTAssertEqual(events(for: item).map(\.eventType), [.consumed])
    }

    func testUndoRestoresTheItemAndErasesTheEvent() throws {
        let expiry = day(3)
        let item = ExpiryItem(name: "牛奶", category: .food, expiryDate: expiry, quantity: 2, unit: "盒")
        context.insert(item)
        try context.save()

        guard let record = ExpiryRepository(context: context).perform(.consumed, on: item) else {
            return XCTFail("消耗品应该能标记为用完")
        }
        XCTAssertEqual(record.previousExpiryDate, expiry)
        XCTAssertEqual(record.actionTitle, "吃完", "撤销条要复述用户当时看到的那句话")

        ExpiryRepository(context: context).undo(record)

        XCTAssertEqual(item.state, .active)
        XCTAssertEqual(item.expiryDate, expiry)
        XCTAssertTrue(events(for: item).isEmpty, "撤销之后不该留下一次没有发生过的「用完」")
    }

    func testRenewalAdvancesTheDateAndUndoPutsItBack() throws {
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 1, day: 31))!
        let item = ExpiryItem(name: "云储存", category: .subscription, expiryDate: anchor, recurrence: .monthly)
        context.insert(item)
        try context.save()

        guard let record = ExpiryRepository(context: context).perform(.renewed, on: item) else {
            return XCTFail("月付订阅应该能续期")
        }
        XCTAssertEqual(item.expiryDate.qjDateText, "2 月 28 日")
        XCTAssertEqual(item.state, .active)
        XCTAssertEqual(item.anchorDay, 31, "续费不覆盖锚点日")
        XCTAssertEqual(events(for: item).map(\.eventType), [.renewed])

        ExpiryRepository(context: context).undo(record)
        XCTAssertEqual(item.expiryDate, anchor)
        XCTAssertTrue(events(for: item).isEmpty)
    }

    func testRenewalOnANonRecurringItemChangesNothing() throws {
        let item = ExpiryItem(name: "一盒牛奶", category: .food, expiryDate: day(3))
        context.insert(item)
        try context.save()

        XCTAssertNil(ExpiryRepository(context: context).perform(.renewed, on: item))
        XCTAssertEqual(item.expiryDate, day(3))
        XCTAssertTrue(events(for: item).isEmpty, "没有执行的动作不该留下记录")
    }

    func testManualRenewalDateBecomesTheNewAnchor() throws {
        let original = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30))!
        let renewed = calendar.date(from: DateComponents(year: 2036, month: 3, day: 15))!
        let item = ExpiryItem(name: "护照", category: .document, expiryDate: original)
        context.insert(item)
        try context.save()

        let record = ExpiryRepository(context: context).renew(item, to: renewed)
        XCTAssertEqual(item.expiryDate, renewed)
        XCTAssertEqual(item.anchorDay, 15)
        XCTAssertEqual(item.state, .active)
        XCTAssertEqual(events(for: item).map(\.eventType), [.renewed])

        ExpiryRepository(context: context).undo(record)
        XCTAssertEqual(item.expiryDate, original)
        XCTAssertEqual(item.anchorDay, 30)
    }

    func testSnoozeKeepsTheItemInNeedOfAttention() throws {
        let item = ExpiryItem(name: "酸奶", category: .food, expiryDate: day(2))
        context.insert(item)
        try context.save()

        XCTAssertNotNil(ExpiryRepository(context: context).perform(.snoozed, on: item))
        XCTAssertEqual(item.state, .active)
        XCTAssertEqual(events(for: item).map(\.eventType), [.snoozed])
    }
}
