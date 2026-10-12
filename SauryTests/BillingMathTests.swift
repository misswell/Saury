import XCTest
@testable import Saury

/// 扣费日期算法。1 月 31 日、闰年、时区这些老坑全部在这一层验证。
final class BillingMathTests: XCTestCase {
    private var calendar: Calendar { BillingMath.calendar }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    /// 推算结果只承诺「落在哪一天」，不承诺当天几点。
    private func assertSameDay(_ actual: Date?, _ expected: Date, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else {
            XCTFail("期待有值，实际为 nil：\(message)", file: file, line: line)
            return
        }
        XCTAssertTrue(calendar.isDate(actual, inSameDayAs: expected), "期待 \(expected)，实际 \(actual)：\(message)", file: file, line: line)
    }

    private func subscription(
        cycle: BillingCycle,
        startDate: Date,
        customMonths: Int = 2,
        state: SubscriptionState = .autoRenew,
        endDate: Date? = nil
    ) -> Subscription {
        Subscription(
            name: "测试",
            cycle: cycle,
            customMonths: customMonths,
            state: state,
            startDate: startDate,
            endDate: endDate
        )
    }

    func testMonthlyAnchorDayReturnsToOriginalDay() {
        let start = date(2026, 1, 31)
        let subject = subscription(cycle: .monthly, startDate: start)
        // 1 月 31 日扣过之后，下一次被钳到 2 月 28 日……
        let afterJanuary = date(2026, 2, 1)
        assertSameDay(BillingMath.nextChargeDate(for: subject, onOrAfter: afterJanuary), date(2026, 2, 28))
        // ……但再下一次要回到 31 日。
        let afterFebruary = date(2026, 3, 1)
        assertSameDay(BillingMath.nextChargeDate(for: subject, onOrAfter: afterFebruary), date(2026, 3, 31))
    }

    func testLeapYearFebruaryClamp() {
        let start = date(2024, 1, 31)
        let subject = subscription(cycle: .monthly, startDate: start)
        assertSameDay(BillingMath.nextChargeDate(for: subject, onOrAfter: date(2024, 2, 1)), date(2024, 2, 29))
    }

    func testOnOrAfterIncludesSameDay() {
        let start = date(2026, 10, 11)
        let subject = subscription(cycle: .monthly, startDate: start)
        assertSameDay(BillingMath.nextChargeDate(for: subject, onOrAfter: date(2026, 11, 11)), date(2026, 11, 11))
        // 过了 11 日，下一次就是 12 月 11 日。
        assertSameDay(BillingMath.nextChargeDate(for: subject, onOrAfter: date(2026, 11, 12)), date(2026, 12, 11))
    }

    func testOneTimeHasNoNextCharge() {
        let subject = subscription(cycle: .oneTime, startDate: date(2026, 1, 1))
        XCTAssertNil(BillingMath.nextChargeDate(for: subject))
        XCTAssertFalse(subject.cycle.isRecurring)
    }

    func testInactiveStopsBilling() {
        let subject = subscription(cycle: .monthly, startDate: date(2026, 1, 1), state: .inactive)
        XCTAssertNil(BillingMath.nextChargeDate(for: subject, onOrAfter: date(2026, 2, 1)))
    }

    func testEndDateCutsBilling() {
        let subject = subscription(cycle: .monthly, startDate: date(2026, 1, 1), endDate: date(2026, 3, 15))
        assertSameDay(BillingMath.nextChargeDate(for: subject, onOrAfter: date(2026, 3, 1)), date(2026, 3, 1))
        XCTAssertNil(BillingMath.nextChargeDate(for: subject, onOrAfter: date(2026, 4, 1)))
    }

    func testCustomCycleUsesMonths() {
        let start = date(2026, 1, 10)
        let subject = subscription(cycle: .custom, startDate: start, customMonths: 3)
        assertSameDay(BillingMath.nextChargeDate(for: subject, onOrAfter: date(2026, 2, 1)), date(2026, 4, 10))
    }

    func testChargeDatesBetween() {
        let subject = subscription(cycle: .monthly, startDate: date(2026, 1, 11))
        let dates = BillingMath.chargeDates(for: subject, from: date(2026, 1, 1), to: date(2026, 4, 1))
        XCTAssertEqual(dates.count, 3)
        XCTAssertEqual(calendar.component(.day, from: dates[0]), 11)
    }

    func testMonthlyNormalized() {
        func money(_ major: Double, _ cycle: BillingCycle, months: Int = 2, headcount: Int = 1, sharing: Bool = false) -> Double {
            let subject = Subscription(
                name: "x",
                priceMinorUnits: Int(major * 100),
                currencyCode: "CNY",
                cycle: cycle,
                customMonths: months,
                shareEnabled: sharing,
                shareHeadcount: headcount
            )
            return Double(BillingMath.monthlyNormalized(subject)?.minorUnits ?? -1)
        }
        XCTAssertEqual(money(30, .quarterly), 1000)
        XCTAssertEqual(money(120, .yearly), 1000)
        XCTAssertEqual(money(52, .weekly), 5200.0 * 52 / 12, accuracy: 1)
        XCTAssertEqual(money(60, .custom, months: 3), 2000)
        XCTAssertNil(BillingMath.monthlyNormalized(subscription(cycle: .oneTime, startDate: Date())))
    }

    func testShareSplit() {
        let even = Subscription(
            name: "拼车",
            priceMinorUnits: 6800,
            currencyCode: "CNY",
            cycle: .monthly,
            shareEnabled: true,
            shareHeadcount: 3
        )
        XCTAssertEqual(even.myAmount.minorUnits, 2267, "68 / 3 = 22.67，四舍五入到分")
        let custom = Subscription(
            name: "拼车",
            priceMinorUnits: 6800,
            currencyCode: "CNY",
            cycle: .monthly,
            shareEnabled: true,
            shareHeadcount: 3,
            shareMode: .custom,
            shareMyMinorUnits: 1000
        )
        XCTAssertEqual(custom.myAmount.minorUnits, 1000)
        XCTAssertNil(custom.othersAmount, "自定义份额没有「其余每人」")
        XCTAssertEqual(even.othersAmount?.minorUnits, 2267)
        let solo = Subscription(name: "单人", priceMinorUnits: 1000, currencyCode: "CNY", cycle: .monthly)
        XCTAssertEqual(solo.myAmount.minorUnits, 1000)
    }
}
