import XCTest
@testable import Saury

final class MoneyTests: XCTestCase {
    func testAmountInputRoundsToTheNearestCentInsteadOfTruncating() {
        XCTAssertEqual(QJMoney.minorUnits(from: "19.99", currencyCode: "CNY"), 1999)
        XCTAssertEqual(QJMoney.minorUnits(from: "0.07", currencyCode: "CNY"), 7)
        XCTAssertEqual(QJMoney.minorUnits(fromYuan: 19.99), 1999)
    }

    func testAmountInputAcceptsGroupingSeparators() {
        XCTAssertEqual(QJMoney.minorUnits(from: "1,234.56", currencyCode: "USD"), 123456)
    }

    func testAmountInputFallsBackToZeroForUnparsableText() {
        XCTAssertEqual(QJMoney.minorUnits(from: "", currencyCode: "CNY"), 0)
        XCTAssertEqual(QJMoney.minorUnits(from: "abc", currencyCode: "CNY"), 0)
        XCTAssertEqual(QJMoney.minorUnits(from: "-12", currencyCode: "CNY"), 0)
    }

    func testSpendSummaryNeverAddsAcrossCurrencies() {
        var summary = QJSpendSummary()
        summary.add(6800, currencyCode: "CNY")
        summary.add(2000, currencyCode: "USD")
        summary.add(3000, currencyCode: "CNY")

        XCTAssertEqual(summary.amount(in: "CNY"), 9800)
        XCTAssertEqual(summary.amount(in: "USD"), 2000)
        XCTAssertEqual(summary.primaryCurrency, "CNY")

        let text = summary.text
        XCTAssertTrue(text.contains("98.00"), "人民币小计应出现在 \(text)")
        XCTAssertTrue(text.contains("20.00"), "美元小计应出现在 \(text)")
        XCTAssertFalse(text.contains("118.00"), "不同币种不能被加成一个数：\(text)")
    }

    func testEmptySummaryReadsAsZeroRenminbi() {
        XCTAssertTrue(QJSpendSummary().isEmpty)
        XCTAssertEqual(QJSpendSummary().text, QJMoney.text(0, currencyCode: "CNY"))
    }

    func testMonthlyEquivalentSplitsRecurringCycles() {
        let future = Calendar.current.date(byAdding: .month, value: 1, to: Date())!
        XCTAssertEqual(
            ExpiryItem(name: "年付", expiryDate: future, priceMinorUnits: 1200, recurrence: .yearly)
                .monthlyEquivalentMinorUnits,
            100
        )
        XCTAssertEqual(
            ExpiryItem(name: "季付", expiryDate: future, priceMinorUnits: 9900, recurrence: .quarterly)
                .monthlyEquivalentMinorUnits,
            3300
        )
        XCTAssertEqual(
            ExpiryItem(name: "每 3 个月", expiryDate: future, priceMinorUnits: 9900, recurrence: .custom, recurrenceInterval: 3)
                .monthlyEquivalentMinorUnits,
            3300
        )
        XCTAssertEqual(
            ExpiryItem(name: "月付", expiryDate: future, priceMinorUnits: 2500, recurrence: .monthly)
                .monthlyEquivalentMinorUnits,
            2500
        )
    }

    func testPricelessItemsStayOutOfMoneyTotals() {
        let future = Calendar.current.date(byAdding: .month, value: 1, to: Date())!
        let milk = ExpiryItem(name: "纯牛奶", expiryDate: future)
        XCTAssertFalse(milk.hasPrice)
        XCTAssertEqual(milk.monthlyEquivalentMinorUnits, 0)

        var summary = QJSpendSummary()
        summary.addMonthlyEquivalent(of: milk)
        summary.addMonthlyEquivalent(of: ExpiryItem(name: "会员", expiryDate: future, priceMinorUnits: 1900, currencyCode: "CNY", recurrence: .monthly))
        XCTAssertEqual(summary.amount(in: "CNY"), 1900)
    }

    func testFormattedPriceUsesTheItemsOwnCurrency() {
        let future = Calendar.current.date(byAdding: .month, value: 1, to: Date())!
        let usd = ExpiryItem(name: "ChatGPT Plus", expiryDate: future, priceMinorUnits: 2000, currencyCode: "USD")
        XCTAssertTrue(usd.formattedPrice.contains("20.00"))
        XCTAssertFalse(usd.formattedPrice.contains("¥"), "美元记录不应显示成人民币：\(usd.formattedPrice)")
    }
}
