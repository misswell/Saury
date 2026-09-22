import XCTest
@testable import Saury

final class RenewalDateCalculatorTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testJanuary31MonthlyRenewalClampsToFebruaryAndReturnsToAnchorDay() {
        let january31 = date(2025, 1, 31)
        let february = RenewalDateCalculator.nextDate(after: january31, cycle: .monthly, anchorDay: 31, calendar: calendar)!
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: february).day, 28)

        let march = RenewalDateCalculator.nextDate(after: february, cycle: .monthly, anchorDay: 31, calendar: calendar)!
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: march).day, 31)
    }

    func testLeapDayYearlyRenewalClampsAndRespectsAnchorDay() {
        let leapDay = date(2024, 2, 29)
        let next = RenewalDateCalculator.nextDate(after: leapDay, cycle: .yearly, anchorDay: 29, calendar: calendar)!
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: next).day, 28)
        let preLeap = date(2027, 2, 28)
        let leapAgain = RenewalDateCalculator.nextDate(after: preLeap, cycle: .yearly, anchorDay: 29, calendar: calendar)!
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: leapAgain).day, 29)
    }

    func testNotificationOffsetsUsePreferredHourForDayOffsets() {
        let renewal = date(2026, 8, 8, hour: 0)
        let reminder = RenewalDateCalculator.notificationDate(for: renewal, minutesBefore: 3 * 24 * 60, preferredHour: 10, calendar: calendar)
        let components = calendar.dateComponents([.day, .hour, .minute], from: reminder)
        XCTAssertEqual(components.day, 5)
        XCTAssertEqual(components.hour, 10)
        XCTAssertEqual(components.minute, 0)
    }

    func testDaysUntilIgnoresTimeOfDay() {
        XCTAssertEqual(RenewalDateCalculator.daysUntil(date(2026, 8, 8, hour: 0), from: date(2026, 8, 3, hour: 23), calendar: calendar), 5)
    }
}
