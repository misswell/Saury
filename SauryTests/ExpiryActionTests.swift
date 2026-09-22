import XCTest
@testable import Saury

/// 处理动作的文案和可选集合（方案 §35）。
final class ExpiryActionTests: XCTestCase {
    private let calendar = ExpiryEngine.calendar

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: Date()) ?? Date()
    }

    func testActionWordingFollowsTheCategory() {
        let food = ExpiryItem(name: "牛奶", category: .food, expiryDate: day(2))
        let medicine = ExpiryItem(name: "布洛芬", category: .medicine, expiryDate: day(2), recurrence: .monthly)
        let passport = ExpiryItem(name: "护照", category: .document, expiryDate: day(2))
        let subscription = ExpiryItem(name: "音乐会员", category: .subscription, expiryDate: day(2), recurrence: .monthly)

        XCTAssertEqual(ExpiryAction.consumed.title(for: food), "吃完")
        XCTAssertEqual(ExpiryAction.consumed.title(for: medicine), "用完")
        XCTAssertEqual(ExpiryAction.discarded.title(for: food), "丢弃")
        XCTAssertEqual(ExpiryAction.renewed.title(for: medicine), "替换新品")
        XCTAssertEqual(ExpiryAction.renewed.title(for: passport), "已续期")
        XCTAssertEqual(ExpiryAction.renewed.title(for: subscription), "已续订")
    }

    func testConsumablesAreAskedWhetherTheyAreUsedUp() {
        let food = ExpiryItem(name: "牛奶", category: .food, expiryDate: day(2))
        XCTAssertEqual(ExpiryAction.available(for: food), [.consumed, .discarded, .snoozed, .archived])
    }

    func testRecurringItemsAreAskedWhetherTheyContinue() {
        let subscription = ExpiryItem(name: "云储存", category: .subscription, expiryDate: day(2), recurrence: .monthly)
        XCTAssertEqual(ExpiryAction.available(for: subscription), [.renewed, .cancelled, .snoozed, .archived])
    }

    /// 列出来却什么都不发生的按钮，比少一个按钮更糟。
    func testRenewalIsOnlyOfferedWhenThereIsANextOccurrence() {
        let passport = ExpiryItem(name: "护照", category: .document, expiryDate: day(2))
        XCTAssertNil(passport.nextOccurrence)
        XCTAssertEqual(ExpiryAction.available(for: passport), [.renewed, .snoozed, .archived])

        let milk = ExpiryItem(name: "牛奶", category: .food, expiryDate: day(2))
        XCTAssertFalse(ExpiryAction.available(for: milk).contains(.renewed))
    }
}
