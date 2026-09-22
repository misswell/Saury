import XCTest
@testable import Saury

/// 「稍后再提醒」的每一档都必须落在一个还没过去的时刻（方案 §45）。
/// 这一组测试盯的是两件事：档位说的是不是真话，以及会不会排到过去。
final class SnoozeChoiceTests: XCTestCase {
    private let calendar = ExpiryEngine.calendar
    private let hour = 9

    private func slot(hour: Int, day: Int = 0, minute: Int = 0) -> Date {
        let base = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 9, day: 22, hour: hour, minute: minute)
        )!
        return calendar.date(byAdding: .day, value: day, to: base) ?? base
    }

    func testEachPresetLandsOnTheTimeItPromises() {
        let now = slot(hour: 9)
        XCTAssertEqual(SnoozeChoice.inOneHour.fireDate(now: now, preferredHour: hour), slot(hour: 10))
        XCTAssertEqual(SnoozeChoice.tonight.fireDate(now: now, preferredHour: hour), slot(hour: 20))
        XCTAssertEqual(SnoozeChoice.tomorrow.fireDate(now: now, preferredHour: hour), slot(hour: 9, day: 1))
        XCTAssertEqual(SnoozeChoice.inThreeDays.fireDate(now: now, preferredHour: hour), slot(hour: 9, day: 3))
    }

    func testTonightAfterEightOClockMeansTomorrowEvening() {
        let now = slot(hour: 21)
        XCTAssertEqual(SnoozeChoice.tonight.fireDate(now: now, preferredHour: hour), slot(hour: 20, day: 1))
    }

    func testTomorrowUsesTheConfiguredReminderHour() {
        let now = slot(hour: 9)
        XCTAssertEqual(SnoozeChoice.tomorrow.fireDate(now: now, preferredHour: 18), slot(hour: 18, day: 1))
    }

    func testNoPresetEverSchedulesIntoThePast() {
        // 一天里每个整点都试一遍：已经过期的东西也要能说明天再提醒。
        for hourOfDay in 0...23 {
            let now = slot(hour: hourOfDay)
            for choice in SnoozeChoice.presets {
                XCTAssertGreaterThan(
                    choice.fireDate(now: now, preferredHour: hour), now,
                    "\(choice.title) 在 \(hourOfDay) 点排到了一个过去的时刻"
                )
            }
        }
    }

    func testCustomTimeInTheFutureIsKeptExactly() {
        let now = slot(hour: 9)
        let picked = slot(hour: 15, minute: 30)
        XCTAssertEqual(SnoozeChoice.custom(picked).fireDate(now: now, preferredHour: hour), picked)
    }

    func testCustomTimeAlreadyGoneSnapsForward() {
        let now = slot(hour: 9)
        XCTAssertEqual(
            SnoozeChoice.custom(slot(hour: 8)).fireDate(now: now, preferredHour: hour),
            slot(hour: 9, minute: 1)
        )
    }

    func testPresetsCoverEveryDocumentedSlot() {
        XCTAssertEqual(SnoozeChoice.presets.map(\.title), ["1 小时后", "今晚", "明天", "3 天后"])
    }
}
