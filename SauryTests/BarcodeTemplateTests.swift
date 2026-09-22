import SwiftData
import XCTest

@testable import Saury

/// 本地商品模板 + 保存前的重复检测（方案 §28、§29、§30），以及 V2 → V3 的建表迁移。
@MainActor
final class BarcodeTemplateTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private let calendar = ExpiryEngine.calendar
    private let reference = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 22))!

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

    private func item(
        name: String = "纯牛奶 1L",
        barcode: String? = "6901234567890",
        batch: String? = nil,
        expiryOffset: Int = 3,
        category: ExpiryCategory = .food,
        location: String? = "冰箱",
        unit: String = "盒",
        state: ExpiryState = .active
    ) -> ExpiryItem {
        ExpiryItem(
            name: name,
            category: category,
            expiryDate: day(expiryOffset),
            barcode: barcode,
            batchNumber: batch,
            quantity: 2,
            unit: unit,
            location: location,
            state: state
        )
    }

    // MARK: - §28 模板

    func testFirstSaveLearnsTheProductAndTheSecondScanReadsItBack() throws {
        let milk = item()
        context.insert(milk)
        ProductTemplateStore.remember(milk, in: context)
        try context.save()

        let template = try XCTUnwrap(ProductTemplateStore.template(forBarcode: "6901234567890", in: context))
        XCTAssertEqual(template.name, "纯牛奶 1L")
        XCTAssertEqual(template.category, .food)
        XCTAssertEqual(template.location, "冰箱")
        XCTAssertEqual(template.unit, "盒")
        XCTAssertEqual(template.reminderOffsets, ReminderPolicy.defaultOffsets(for: .food))
    }

    func testSavingAgainUpdatesTheTemplateInsteadOfAddingAnotherRow() throws {
        let first = item(location: "冰箱")
        context.insert(first)
        ProductTemplateStore.remember(first, in: context)
        try context.save()

        let moved = item(location: "阳台")
        context.insert(moved)
        ProductTemplateStore.remember(moved, in: context)
        try context.save()

        let all = try context.fetch(FetchDescriptor<ProductTemplate>())
        XCTAssertEqual(all.count, 1, "同一个条码只能有一条模板")
        XCTAssertEqual(all.first?.location, "阳台", "模板跟着最后一次正确的输入走")
    }

    func testBarcodeLookupIgnoresSurroundingSpacesAndRejectsMissingCodes() {
        let saved = item()
        context.insert(saved)
        XCTAssertNotNil(ProductTemplateStore.remember(saved, in: context))
        XCTAssertNotNil(ProductTemplateStore.template(forBarcode: "  6901234567890  ", in: context))
        XCTAssertNil(ProductTemplateStore.template(forBarcode: "   ", in: context))
        XCTAssertNil(ProductTemplateStore.template(forBarcode: nil, in: context))
    }

    func testItemsWithoutABarcodeDoNotCreateTemplates() {
        let unnamed = item(barcode: nil)
        context.insert(unnamed)
        XCTAssertNil(ProductTemplateStore.remember(unnamed, in: context))
        XCTAssertTrue(try context.fetch(FetchDescriptor<ProductTemplate>()).isEmpty)
    }

    // MARK: - §29 重复检测

    func testSameBarcodeSameDaySameBatchIsTheSameBatch() throws {
        let existing = item(batch: "A20260901")
        context.insert(existing)
        try context.save()

        let match = try XCTUnwrap(
            ExpiryDuplicateCheck.match(
                ExpiryDuplicateCheck.candidate(barcode: "6901234567890", name: "纯牛奶 1L",
                                               expiryDate: day(3), batchNumber: "a20260901"),
                in: [existing]
            )
        )
        XCTAssertEqual(match.id, existing.id)
    }

    func testADifferentBatchOrADifferentDayIsANewItem() {
        let existing = item(batch: "A20260901", expiryOffset: 3)
        let items = [existing]
        XCTAssertNil(ExpiryDuplicateCheck.match(
            ExpiryDuplicateCheck.candidate(barcode: "6901234567890", name: "纯牛奶 1L",
                                           expiryDate: day(3), batchNumber: "A20260910"),
            in: items
        ))
        XCTAssertNil(ExpiryDuplicateCheck.match(
            ExpiryDuplicateCheck.candidate(barcode: "6901234567890", name: "纯牛奶 1L",
                                           expiryDate: day(11), batchNumber: "A20260901"),
            in: items
        ))
    }

    func testTwiceTheSameMilkWithoutAnyBatchIsStillOneBatch() {
        let existing = item(batch: nil)
        // 没写批次号的两条同一天同商品，是「记重了」而不是「新增一批」。
        XCTAssertNotNil(ExpiryDuplicateCheck.match(
            ExpiryDuplicateCheck.candidate(barcode: "6901234567890", name: "纯牛奶 1L",
                                           expiryDate: day(3), batchNumber: nil),
            in: [existing]
        ))
    }

    func testItemsWithoutABarcodeAreMatchedByName() {
        let existing = item(name: "酸奶", barcode: nil)
        XCTAssertNotNil(ExpiryDuplicateCheck.match(
            ExpiryDuplicateCheck.candidate(barcode: nil, name: " 酸奶 ", expiryDate: day(3), batchNumber: nil),
            in: [existing]
        ))
        XCTAssertNil(ExpiryDuplicateCheck.match(
            ExpiryDuplicateCheck.candidate(barcode: nil, name: "牛奶", expiryDate: day(3), batchNumber: nil),
            in: [existing]
        ))
    }

    func testHandledBatchesAreNotDuplicates() {
        let thrownAway = item(batch: "A20260901", state: .discarded)
        XCTAssertNil(ExpiryDuplicateCheck.match(
            ExpiryDuplicateCheck.candidate(for: thrownAway),
            in: [thrownAway]
        ))
    }

    func testEditingAnItemDoesNotAskWhetherItDuplicatesItself() {
        let existing = item()
        XCTAssertNil(ExpiryDuplicateCheck.match(
            ExpiryDuplicateCheck.candidate(for: existing),
            in: [existing],
            excluding: existing.id
        ))
    }

    func testDayComparisonUsesRealCalendarDaysNotTimestamps() {
        let existing = item(batch: nil)
        let laterThatDay = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: day(3)) ?? day(3)
        XCTAssertNotNil(ExpiryDuplicateCheck.match(
            ExpiryDuplicateCheck.candidate(barcode: "6901234567890", name: "纯牛奶 1L",
                                           expiryDate: laterThatDay, batchNumber: nil),
            in: [existing]
        ))
    }

    // MARK: - V2 → V3

    func testExistingLibraryGainsTheTemplateTableWithoutLosingItems() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("saury-v2-to-v3-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let v2 = try PersistenceController.makeV2Container(url: url)
            let context = v2.mainContext
            context.insert(item())
            context.insert(item(name: "护照", barcode: nil, category: .document, location: "书房", unit: "本"))
            try context.save()
        }

        let v3 = try PersistenceController.makeContainer(url: url)
        let context = v3.mainContext
        let items = try context.fetch(FetchDescriptor<ExpiryItem>())
        XCTAssertEqual(items.count, 2, "升级到 V3 不能丢物品")
        XCTAssertEqual(Set(items.map(\.name)), ["纯牛奶 1L", "护照"])

        let milk = try XCTUnwrap(items.first { $0.name == "纯牛奶 1L" })
        ProductTemplateStore.remember(milk, in: context)
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<ProductTemplate>()).count, 1, "新表在老库上可直接写")
    }
}
