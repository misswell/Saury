import XCTest
import SwiftUI
@testable import Saury

/// 所有页面共用的到期分级：边界必须固定，否则同一个物品会在
/// 首页显示「今天」、在列表里显示「3 天内」。
final class ExpiryUrgencyTests: XCTestCase {

    func testBoundaryDaysMapToTheDocumentedBuckets() {
        XCTAssertEqual(ExpiryUrgency(daysRemaining: -30), .expired)
        XCTAssertEqual(ExpiryUrgency(daysRemaining: -1), .expired)
        XCTAssertEqual(ExpiryUrgency(daysRemaining: 0), .today)
        XCTAssertEqual(ExpiryUrgency(daysRemaining: 1), .critical)
        XCTAssertEqual(ExpiryUrgency(daysRemaining: 3), .critical)
        XCTAssertEqual(ExpiryUrgency(daysRemaining: 4), .soon)
        XCTAssertEqual(ExpiryUrgency(daysRemaining: 7), .soon)
        XCTAssertEqual(ExpiryUrgency(daysRemaining: 8), .upcoming)
        XCTAssertEqual(ExpiryUrgency(daysRemaining: 30), .upcoming)
        XCTAssertEqual(ExpiryUrgency(daysRemaining: 31), .normal)
    }

    func testLabelsReadAsCountdownNotRawNumbers() {
        XCTAssertEqual(ExpiryUrgency.label(daysRemaining: -2), "已过期 2 天")
        XCTAssertEqual(ExpiryUrgency.label(daysRemaining: 0), "今天到期")
        XCTAssertEqual(ExpiryUrgency.label(daysRemaining: 1), "明天到期")
        XCTAssertEqual(ExpiryUrgency.label(daysRemaining: 5), "还有 5 天")
    }

    func testSectionOrderPlacesMostUrgentFirst() {
        let ordered = ExpiryUrgency.allCases.sorted { $0.sortWeight < $1.sortWeight }
        XCTAssertEqual(ordered, [.expired, .today, .critical, .soon, .upcoming, .normal])
    }

    /// 分级必须建立在真实天数上：同一天里的早晚、跨月、跨闰年都不能改变档位。
    func testUrgencyFollowsRealDayCounting() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))

        let morning = try day(2026, 9, 22, hour: 9, in: calendar)
        let lateNight = try day(2026, 9, 22, hour: 23, in: calendar)
        let nextMidnight = try day(2026, 9, 23, hour: 0, in: calendar)
        let yesterdayNight = try day(2026, 9, 21, hour: 23, in: calendar)

        XCTAssertEqual(urgency(from: morning, to: lateNight, in: calendar), .today)
        XCTAssertEqual(urgency(from: morning, to: nextMidnight, in: calendar), .critical)
        XCTAssertEqual(urgency(from: morning, to: yesterdayNight, in: calendar), .expired)

        // 2 月 28 日到 2 月 29 日只隔一天，闰年不能算成 0 天或 2 天。
        let leapEve = try day(2028, 2, 28, hour: 9, in: calendar)
        let leapDay = try day(2028, 2, 29, hour: 9, in: calendar)
        XCTAssertEqual(ExpiryEngine.daysRemaining(to: leapDay, from: leapEve, calendar: calendar), 1)

        // 1 月 31 日往后 28 天仍在「30 天内」，跨到次年才归入「以后」。
        let jan31 = try day(2027, 1, 31, hour: 9, in: calendar)
        let feb28 = try day(2027, 2, 28, hour: 9, in: calendar)
        let nextYear = try day(2028, 1, 31, hour: 9, in: calendar)
        XCTAssertEqual(urgency(from: jan31, to: feb28, in: calendar), .upcoming)
        XCTAssertEqual(urgency(from: jan31, to: nextYear, in: calendar), .normal)
    }

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int, in calendar: Calendar) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
    }

    private func urgency(from reference: Date, to date: Date, in calendar: Calendar) -> ExpiryUrgency {
        ExpiryUrgency(daysRemaining: ExpiryEngine.daysRemaining(to: date, from: reference, calendar: calendar))
    }
}
