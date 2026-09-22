import XCTest
@testable import Saury

/// 日期与提醒的算法集中在 ExpiryEngine，这里就是它的边界契约：
/// 跨月、跨闰年、锚点日钳制、开封后有效期、下一次提醒的选取。
final class ExpiryEngineTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    // MARK: - 周期推进

    func testJanuary31MonthlyRenewalClampsToFebruaryAndReturnsToAnchorDay() {
        let january31 = date(2025, 1, 31)
        let february = ExpiryEngine.nextOccurrence(after: january31, recurrence: .monthly, anchorDay: 31, calendar: calendar)!
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: february).day, 28)

        let march = ExpiryEngine.nextOccurrence(after: february, recurrence: .monthly, anchorDay: 31, calendar: calendar)!
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: march).day, 31)
    }

    func testLeapDayYearlyRenewalClampsAndRespectsAnchorDay() {
        let leapDay = date(2024, 2, 29)
        let next = ExpiryEngine.nextOccurrence(after: leapDay, recurrence: .yearly, anchorDay: 29, calendar: calendar)!
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: next), DateComponents(year: 2025, month: 2, day: 28))

        // 锚点日是 29 的物品被钳到 28 之后，闰年要能回到 29。
        let preLeap = date(2027, 2, 28)
        let leapAgain = ExpiryEngine.nextOccurrence(after: preLeap, recurrence: .yearly, anchorDay: 29, calendar: calendar)!
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: leapAgain), DateComponents(year: 2028, month: 2, day: 29))
    }

    /// 锚点日必须由物品自己记住：续费把日期钳到 2 月 28 日之后，
    /// 下一次仍要回到 31 日，而不是顺着被钳过的日期一路漂到 28 日。
    func testMonthEndItemReturnsToItsAnchorDayAfterClamping() throws {
        let calendar = ExpiryEngine.calendar
        let january31 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 1, day: 31, hour: 12)))
        let item = ExpiryItem(name: "月付账单", category: .subscription, expiryDate: january31, recurrence: .monthly)

        let february = try XCTUnwrap(ExpiryEngine.nextOccurrence(for: item, calendar: calendar))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: february), DateComponents(year: 2027, month: 2, day: 28))

        item.expiryDate = february
        let march = try XCTUnwrap(ExpiryEngine.nextOccurrence(for: item, calendar: calendar))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: march), DateComponents(year: 2027, month: 3, day: 31))
        XCTAssertEqual(item.anchorDay, 31, "推进周期不能改写锚点日")
    }

    // MARK: - 夏令时与时区

    /// 春进的那天只有 23 小时、秋退那天有 25 小时：按日历天计数不能因此差一天。
    func testDaylightSavingTransitionsStillCountOneCalendarDay() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))

        let march7 = try XCTUnwrap(newYork.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 9)))
        let springForward = try XCTUnwrap(newYork.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 9)))
        XCTAssertEqual(ExpiryEngine.daysRemaining(to: springForward, from: march7, calendar: newYork), 1)

        let october31 = try XCTUnwrap(newYork.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 9)))
        let fallBack = try XCTUnwrap(newYork.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9)))
        XCTAssertEqual(ExpiryEngine.daysRemaining(to: fallBack, from: october31, calendar: newYork), 1)
    }

    /// 同一个时刻在不同时区属于不同的「日」：结论必须整体跟着所用日历走。
    func testDayCountingIsConsistentWithinTheGivenCalendar() throws {
        var shanghai = Calendar(identifier: .gregorian)
        shanghai.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!

        // UTC 10-16 20:00 在上海已经是 10-17。
        let expiry = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 20)))
        let fromShanghai = try XCTUnwrap(shanghai.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 9)))
        let fromUTC = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 9)))

        XCTAssertEqual(ExpiryEngine.daysRemaining(to: expiry, from: fromShanghai, calendar: shanghai), 2)
        XCTAssertEqual(ExpiryEngine.daysRemaining(to: expiry, from: fromUTC, calendar: utc), 1)
    }

    func testQuarterlyAndSixMonthCyclesAdvanceByTheirOwnInterval() {
        let start = date(2026, 1, 15)
        let quarterly = ExpiryEngine.nextOccurrence(after: start, recurrence: .quarterly, calendar: calendar)!
        let halfYear = ExpiryEngine.nextOccurrence(after: start, recurrence: .everySixMonths, calendar: calendar)!
        XCTAssertEqual(calendar.component(.month, from: quarterly), 4)
        XCTAssertEqual(calendar.component(.month, from: halfYear), 7)
    }

    func testCustomRecurrenceUsesItsOwnIntervalInMonths() {
        let start = date(2026, 1, 15)
        let next = ExpiryEngine.nextOccurrence(after: start, recurrence: .custom, intervalMonths: 18, calendar: calendar)!
        XCTAssertEqual(calendar.dateComponents([.year, .month], from: next), DateComponents(year: 2027, month: 7))
    }

    func testWeeklyRecurrenceAdvancesSevenDays() {
        let start = date(2026, 3, 3)
        let next = ExpiryEngine.nextOccurrence(after: start, recurrence: .weekly, calendar: calendar)!
        XCTAssertEqual(ExpiryEngine.daysRemaining(to: next, from: start, calendar: calendar), 7)
    }

    func testNonRecurringItemHasNoNextOccurrence() {
        XCTAssertNil(ExpiryEngine.nextOccurrence(after: date(2026, 1, 15), recurrence: .none, calendar: calendar))
    }

    // MARK: - 真正会过期的那一天

    func testDaysRemainingIgnoresTimeOfDay() {
        XCTAssertEqual(ExpiryEngine.daysRemaining(to: date(2026, 8, 8, hour: 0), from: date(2026, 8, 3, hour: 23), calendar: calendar), 5)
    }

    func testPackagingDateWinsWhenShelfLifeEndsLater() {
        let item = ExpiryItem(
            name: "酸奶",
            expiryDate: date(2026, 3, 10),
            manufactureDate: date(2026, 1, 1),
            shelfLifeDays: 120
        )
        XCTAssertEqual(ExpiryEngine.effectiveExpiryDate(for: item, calendar: calendar), date(2026, 3, 10))
    }

    func testShelfLifeWinsWhenPackagingDateIsLater() {
        let item = ExpiryItem(
            name: "罐头",
            expiryDate: date(2027, 1, 1),
            manufactureDate: date(2026, 1, 1),
            shelfLifeDays: 180
        )
        XCTAssertEqual(ExpiryEngine.effectiveExpiryDate(for: item, calendar: calendar), date(2026, 6, 30))
    }

    func testOpenedDateCanMoveExpiryEarlierThanBothDates() {
        let item = ExpiryItem(
            name: "面霜",
            expiryDate: date(2027, 1, 1),
            manufactureDate: date(2026, 1, 1),
            openedDate: date(2026, 3, 1),
            shelfLifeDays: 400,
            afterOpeningDays: 90
        )
        XCTAssertEqual(ExpiryEngine.effectiveExpiryDate(for: item, calendar: calendar), date(2026, 5, 30))
    }

    func testUrgencyComesFromEffectiveExpiryNotThePrintedDate() {
        // 包装上还有一年，开封 6 个月后就已经过期：分级必须跟着开封日期走。
        let opened = ExpiryItem(
            name: "开封的精华液",
            expiryDate: calendar.date(byAdding: .year, value: 1, to: date(2026, 3, 1))!,
            openedDate: date(2025, 1, 1),
            afterOpeningDays: 180
        )
        XCTAssertEqual(ExpiryEngine.urgency(for: opened, from: date(2026, 3, 1), calendar: calendar), .expired)

        let sealed = ExpiryItem(name: "未开封的精华液", expiryDate: date(2026, 3, 8))
        XCTAssertEqual(ExpiryEngine.urgency(for: sealed, from: date(2026, 3, 1), calendar: calendar), .soon)
    }

    // MARK: - 提醒

    func testNotificationOffsetsUsePreferredHourForDayOffsets() {
        let expiry = date(2026, 8, 8, hour: 0)
        let reminder = ExpiryEngine.notificationDate(forExpiry: expiry, minutesBefore: 3 * 24 * 60, preferredHour: 10, calendar: calendar)
        let components = calendar.dateComponents([.day, .hour, .minute], from: reminder)
        XCTAssertEqual(components.day, 5)
        XCTAssertEqual(components.hour, 10)
        XCTAssertEqual(components.minute, 0)
    }

    func testSameDayReminderFallsOnThePreferredHour() {
        let expiry = date(2026, 8, 8, hour: 0)
        let reminder = ExpiryEngine.notificationDate(forExpiry: expiry, minutesBefore: 0, preferredHour: 21, calendar: calendar)
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: reminder)
        XCTAssertEqual(components, DateComponents(year: 2026, month: 8, day: 8, hour: 21))
    }

    func testSubDayOffsetsCountBackFromTheExactExpiryMoment() {
        let expiry = date(2026, 8, 8, hour: 18)
        let reminder = ExpiryEngine.notificationDate(forExpiry: expiry, minutesBefore: 3 * 60, preferredHour: 9, calendar: calendar)
        XCTAssertEqual(reminder, date(2026, 8, 8, hour: 15))
    }

    func testNextReminderIsTheEarliestNotificationStillInTheFuture() throws {
        let item = ExpiryItem(
            name: "会员",
            expiryDate: date(2026, 8, 8),
            recurrence: .monthly,
            reminderOffsets: [7 * 24 * 60, 3 * 24 * 60, 24 * 60, 0]
        )
        // 提前 7 天和 3 天都已经过去，剩下的最早一条是提前 1 天。
        let next = try XCTUnwrap(ExpiryEngine.nextReminderDate(for: item, now: date(2026, 8, 6, hour: 12), preferredHour: 9, calendar: calendar))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour], from: next), DateComponents(year: 2026, month: 8, day: 7, hour: 9))
    }

    func testNextReminderBecomesNilOnceTheWholePlanIsOver() {
        let item = ExpiryItem(
            name: "会员",
            expiryDate: date(2026, 8, 8),
            reminderOffsets: [24 * 60, 0]
        )
        XCTAssertNil(ExpiryEngine.nextReminderDate(for: item, now: date(2026, 8, 9, hour: 12), preferredHour: 9, calendar: calendar))
    }
}
