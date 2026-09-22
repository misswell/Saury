import XCTest
@testable import Saury

/// 方案 §91：扫描能力的测试重点是 Parser，而不是「拿手机再拍一张」。
/// 这里用九组仿真的识别行（食品包装 / 药盒 / 中文 / 英文 / 模糊 / 倾斜 / 反光 / 低光 / 多日期），
/// 断言的都是「这段文字应该变成什么」，不依赖 Vision。
final class ExpiryOCRParserTests: XCTestCase {
    private let reference = ExpiryEngineCalendar.date(year: 2026, month: 9, day: 22)

    // MARK: - 测试脚手架

    /// 一行识别文字。默认放在画面中段、置信度 0.95，让「位置」和「置信度」两项固定，
    /// 需要考察它们时再单独传参。
    private func line(
        _ text: String,
        confidence: Double = 0.95,
        y: Double = 0.48,
        height: Double = 0.04
    ) -> OCRLine {
        OCRLine(text, confidence: confidence, boundingBox: CGRect(x: 0.05, y: y, width: 0.9, height: height))
    }

    private func parse(_ lines: [OCRLine]) -> ExpiryOCRResult {
        ExpiryOCRParser.parse(page: OCRPage(lines: lines), now: reference)
    }

    private func page(_ texts: [String], confidence: Double = 0.95) -> [OCRLine] {
        texts.map { line($0, confidence: confidence) }
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        ExpiryEngineCalendar.date(year: year, month: month, day: day)
    }

    // MARK: - §22 日期写法

    func testChineseDateWithKeywordIsTheStrongestCase() throws {
        let result = parse(page(["有效期至 2026 年 10 月 12 日"]))
        let candidate = try XCTUnwrap(result.candidate(for: .expiryDate))
        XCTAssertEqual(candidate.value.dateValue, date(2026, 10, 12))
        XCTAssertEqual(candidate.confidence, 0.97, accuracy: 0.02)
        XCTAssertFalse(candidate.needsConfirmation)
    }

    func testAllSeparatorStylesResolveToTheSameDay() {
        for text in ["2026-09-22", "2026/09/22", "2026.09.22", "2026年9月22日", "20260922"] {
            let result = parse(page(["有效日期 " + text]))
            XCTAssertEqual(result.date(for: .expiryDate), date(2026, 9, 22), text)
        }
    }

    func testEnglishMonthNameDates() {
        XCTAssertEqual(parse(page(["BEST BEFORE SEP 22 2026"])).date(for: .expiryDate), date(2026, 9, 22))
        XCTAssertEqual(parse(page(["EXP 22 SEP 2026"])).date(for: .expiryDate), date(2026, 9, 22))
        XCTAssertEqual(parse(page(["USE BY December 3 2026"])).date(for: .expiryDate), date(2026, 12, 3))
    }

    func testDayMonthYearAndMonthDayYearAreToldApartByTheNumbers() {
        XCTAssertEqual(parse(page(["EXP 22/09/2026"])).date(for: .expiryDate), date(2026, 9, 22))
        XCTAssertEqual(parse(page(["EXP 09/22/2026"])).date(for: .expiryDate), date(2026, 9, 22))
    }

    func testAmbiguousDayAndMonthNeedsConfirmationAndOffersTheOtherReading() {
        let candidate = parse(page(["EXP 05/09/2026"])).candidate(for: .expiryDate)
        XCTAssertEqual(candidate?.value.dateValue, date(2026, 9, 5), "歧义时默认按「日/月」读")
        XCTAssertTrue(candidate?.needsConfirmation ?? false, "日月都能读通时必须让人确认")
        XCTAssertEqual(candidate?.alternatives.first?.dateValue, date(2026, 5, 9))
    }

    func testMonthOnlyDatesLandOnTheLastDayOfMonth() {
        let candidate = parse(page(["有效期至 2026-11"])).candidate(for: .expiryDate)
        XCTAssertEqual(candidate?.value.dateValue, date(2026, 11, 30))
        XCTAssertTrue(candidate?.needsConfirmation ?? false)
        XCTAssertTrue(candidate?.reasons.contains { $0.contains("只识别到月份") } ?? false)
    }

    func testImpossibleDatesAreDropped() {
        XCTAssertTrue(parse(page(["EXP 2026-02-30"])).entries.isEmpty)
        XCTAssertTrue(parse(page(["EXP 2026-13-40"])).entries.isEmpty)
    }

    func testVolumesAndWeightsAreNeverReadAsDates() {
        let result = parse(page(["净含量 500ml", "12.5ml", "0.9L", "5片装"]))
        XCTAssertNil(result.date(for: .expiryDate))
        XCTAssertNil(result.date(for: .manufactureDate))
    }

    // MARK: - §22 关键字决定日期归谁

    func testManufactureAndExpiryKeywordsSplitTwoDatesIntoTwoFields() {
        let result = parse(page(["生产日期：2026.09.01", "有效期至：2026.10.01"]))
        XCTAssertEqual(result.date(for: .manufactureDate), date(2026, 9, 1))
        XCTAssertEqual(result.date(for: .expiryDate), date(2026, 10, 1))
        XCTAssertFalse(result.candidate(for: .expiryDate)?.needsConfirmation ?? true)
        XCTAssertFalse(result.candidate(for: .manufactureDate)?.needsConfirmation ?? true)
    }

    func testEnglishAbbreviationsAreNotMatchedInsideOtherWords() {
        // 「EXAMPLE」里含 EXP，不能因此把后面的数字当日期。
        let result = parse(page(["EXAMPLE 2026.09.01"]))
        XCTAssertEqual(result.date(for: .manufactureDate), nil)
        XCTAssertEqual(result.date(for: .expiryDate), date(2026, 9, 1), "没有关键字时兜底当有效日期")
        XCTAssertTrue(result.candidate(for: .expiryDate)?.needsConfirmation ?? false)
    }

    func testKeywordOnThePreviousLineStillWorks() {
        let result = parse(page(["保质期至", "2026.10.12"]))
        let candidate = result.candidate(for: .expiryDate)
        XCTAssertEqual(candidate?.value.dateValue, date(2026, 10, 12))
        XCTAssertNotNil(candidate)
    }

    func testBareDatesAreKeptButMarkedForConfirmation() {
        let result = parse(page(["2026.10.12"]))
        let candidate = result.candidate(for: .expiryDate)
        XCTAssertTrue(candidate?.needsConfirmation ?? false)
        XCTAssertGreaterThanOrEqual(candidate?.confidence ?? 1, ExpiryOCRThresholds.discard)
    }

    func testPastExpiryDateSaysSoInsteadOfQuietlyPassing() {
        let candidate = parse(page(["有效期至 2023.10.15"])).candidate(for: .expiryDate)
        XCTAssertEqual(candidate?.value.dateValue, date(2023, 10, 15))
        XCTAssertTrue(candidate?.reasons.contains { $0.contains("已经过去") } ?? false)
    }

    // MARK: - §23 保质期

    func testShelfLifePlusManufactureDateDerivesExpiry() {
        let result = parse(page(["生产日期：2026/09/01", "保质期：30天"]))
        XCTAssertEqual(result.duration(for: .shelfLife), ShelfLife(amount: 30, unit: .day))
        XCTAssertEqual(result.date(for: .expiryDate), date(2026, 10, 1))
        XCTAssertEqual(result.candidate(for: .expiryDate)?.sources, Set<ExpirySource>([.derived]))
    }

    func testShelfLifeInMonthsUsesCalendarArithmetic() {
        let result = parse(page(["生产日期：2026-09-01", "保质期：12个月"]))
        XCTAssertEqual(result.date(for: .expiryDate), date(2027, 9, 1))
    }

    func testChineseNumeralsAndYearUnits() {
        XCTAssertEqual(parse(page(["保质期一年"])).duration(for: .shelfLife), ShelfLife(amount: 1, unit: .year))
        XCTAssertEqual(parse(page(["保质期三十六个月"])).duration(for: .shelfLife), ShelfLife(amount: 36, unit: .month))
        XCTAssertEqual(parse(page(["保质期半年"])).duration(for: .shelfLife), ShelfLife(amount: 6, unit: .month))
        XCTAssertEqual(parse(page(["SHELF LIFE 18 months"])).duration(for: .shelfLife), ShelfLife(amount: 18, unit: .month))
    }

    func testDerivedExpiryDoesNotOverrideAReadDateButLeavesANote() {
        let result = parse(page(["生产日期：2026-09-01", "保质期：30天", "有效期至：2026-11-11"]))
        XCTAssertEqual(result.date(for: .expiryDate), date(2026, 11, 11))
        XCTAssertTrue(result.notes.contains { $0.contains("2026 年 10 月 1 日") })
    }

    // MARK: - §24 开封期

    func testOpeningKeywordMakesTheNumberAnAfterOpeningLife() {
        let result = parse(page(["开封后 6 个月内用完"]))
        XCTAssertEqual(result.duration(for: .afterOpening), ShelfLife(amount: 6, unit: .month))
        XCTAssertNil(result.duration(for: .shelfLife))
    }

    func testPeriodAfterOpeningSymbolAloneCountsAsOpeningLife() {
        let result = parse(page(["12M"]))
        let candidate = result.candidate(for: .afterOpening)
        XCTAssertEqual(candidate?.value.durationValue, ShelfLife(amount: 12, unit: .month))
        XCTAssertTrue(candidate?.needsConfirmation ?? false, "只有符号时不能自作主张")
    }

    func testMillilitresAreNotPeriodAfterOpening() {
        XCTAssertTrue(parse(page(["500ml"])).duration(for: .afterOpening) == nil)
        XCTAssertTrue(parse(page(["12mg"])).duration(for: .afterOpening) == nil)
    }

    // MARK: - §26 区域评分

    func testLowEngineConfidenceDropsTheWholeRegionBelowConfirmation() {
        let result = parse([line("有效期至 2026.10.12", confidence: 0.4)])
        let candidate = result.candidate(for: .expiryDate)
        XCTAssertTrue(candidate?.needsConfirmation ?? false)
        XCTAssertEqual(candidate?.value.dateValue, date(2026, 10, 12))
    }

    func testTextAtTheEdgeScoresLowerThanTextInBand() {
        let middle = parse([line("EXP 2026.10.12", y: 0.48)]).confidence(of: .expiryDate)
        let edge = parse([line("EXP 2026.10.12", y: 0.94)]).confidence(of: .expiryDate)
        XCTAssertGreaterThan(middle ?? 0, edge ?? 0)
    }

    func testGiantBrandTypeIsNotTreatedAsAPackedDate() {
        let result = parse([line("EXP 2026.10.12", y: 0.48, height: 0.3)])
        XCTAssertLessThan(result.confidence(of: .expiryDate) ?? 1,
                          parse(page(["EXP 2026.10.12"])).confidence(of: .expiryDate) ?? 1)
    }

    func testEveryCandidateCarriesItsPlaceOnTheOriginalImage() {
        let result = parse(page(["有效期至 2026.10.12"]))
        XCTAssertEqual(result.candidate(for: .expiryDate)?.boundingBox, CGRect(x: 0.05, y: 0.48, width: 0.9, height: 0.04))
        XCTAssertEqual(result.boxes.count, 1)
    }

    func testJunkBelowTheFloorIsDiscardedEntirely() {
        let result = parse([line("2026/10/12", confidence: 0.05, y: 0.98)])
        XCTAssertNil(result.date(for: .expiryDate))
    }

    // MARK: - §91 仿真包装

    func testFoodPackageReading() {
        let result = parse(page([
            "光明乳业",
            "纯牛奶",
            "生产日期：2026.09.01",
            "保质期：12个月",
            "净含量：250ml",
            "配料：生牛乳"
        ]))
        XCTAssertEqual(result.text(for: .name), "光明乳业")
        XCTAssertEqual(result.date(for: .manufactureDate), date(2026, 9, 1))
        XCTAssertEqual(result.duration(for: .shelfLife), ShelfLife(amount: 12, unit: .month))
        XCTAssertEqual(result.date(for: .expiryDate), date(2027, 9, 1))
    }

    func testMedicineBoxReading() {
        let result = parse(page([
            "布洛芬缓释胶囊",
            "0.3g×20粒",
            "产品批号：H20260901",
            "生产日期 2026/08/20",
            "有效期至 2028/08/19"
        ]))
        XCTAssertEqual(result.text(for: .name), "布洛芬缓释胶囊")
        XCTAssertEqual(result.text(for: .batchNumber), "H20260901")
        XCTAssertEqual(result.date(for: .manufactureDate), date(2026, 8, 20))
        XCTAssertEqual(result.date(for: .expiryDate), date(2028, 8, 19))
        XCTAssertFalse(result.candidate(for: .expiryDate)?.needsConfirmation ?? true)
    }

    func testEnglishCosmeticPackageWithMultipleDates() {
        let result = parse(page([
            "AQUA MOISTURIZING CREAM",
            "Net wt. 50 ml",
            "MFG 09/2026",
            "EXP 09/2029",
            "12M"
        ]))
        XCTAssertEqual(result.text(for: .name), "AQUA MOISTURIZING CREAM")
        XCTAssertEqual(result.date(for: .expiryDate), date(2029, 9, 30))
        XCTAssertEqual(result.duration(for: .afterOpening)?.title, "12个月")
    }

    func testBlurryLowLightPackageKeepsNothingHighConfidence() {
        let result = parse(page(["牛奶", "保质期??"], confidence: 0.3))
        XCTAssertTrue(result.entries.allSatisfy(\.needsConfirmation))
    }

    func testEmptyPageProducesNoEntries() {
        XCTAssertTrue(parse([]).isEmpty)
    }

    func testResultKeepsOneCandidatePerField() {
        let fields = parse(page(["有效期至 2026.10.12", "有效期至 2026.11.12", "EXP 2027.01.01"]))
            .entries.map(\.field)
        XCTAssertEqual(fields.filter { $0 == .expiryDate }.count, 1)
    }

    // MARK: - 金额（旧截图填表能力不降级）

    func testPriceFromScreenshotSurvivesTheRewrite() {
        let result = parse(page(["会员月卡 ￥21.00"]))
        XCTAssertEqual(result.amount(for: .amount)?.minorUnits, 2100)
        XCTAssertEqual(result.amount(for: .amount)?.currencyCode, "CNY")
    }
}

private extension ExpiryOCRResult {
    func confidence(of field: ExpiryOCRField) -> Double? { candidate(for: field)?.confidence }
}

private enum ExpiryEngineCalendar {
    static func date(year: Int, month: Int, day: Int) -> Date {
        ExpiryEngine.calendar.startOfDay(for: ExpiryEngine.calendar.date(from: DateComponents(year: year, month: month, day: day))!)
    }
}
