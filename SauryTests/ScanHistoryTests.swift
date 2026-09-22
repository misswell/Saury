import SwiftData
import UIKit
import XCTest

@testable import Saury

/// 扫描原图 → `ImageStore` → 活动记录（方案 §34）。
///
/// 这里验的是「有原图就要能在历史里看到它」这条链：文件落在哪、存一件东西留下几条
/// 记录、以及同一批扫两次各自的那张图都在。
@MainActor
final class ScanHistoryTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var directory: URL!
    private var images: ImageStore!

    private let expiry = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 12))!
    private let barcode = "6901234567890"

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Schema(versionedSchema: SaurySchemaV3.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = container.mainContext
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SauryImages-\(UUID().uuidString)", isDirectory: true)
        images = ImageStore(root: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - 帮助

    private func result(name: String? = "纯牛奶 1L", barcode: String? = "6901234567890", expiry: Date?) -> ExpiryOCRResult {
        var entries: [ExpiryOCRCandidate] = []
        if let name { entries.append(ExpiryOCRCandidate(field: .name, value: .text(name), confidence: 0.9)) }
        if let barcode { entries.append(ExpiryOCRCandidate(field: .barcode, value: .text(barcode), confidence: 0.9)) }
        if let expiry { entries.append(ExpiryOCRCandidate(field: .expiryDate, value: .date(expiry, alternatives: []), confidence: 0.9)) }
        return ExpiryOCRResult(entries: entries)
    }

    private func confirmation(_ result: ExpiryOCRResult, image: UIImage?) -> ExpiryOCRConfirmation {
        ExpiryOCRConfirmation(result: result, openedToday: false, image: image)
    }

    /// 测试用的小图：内容不重要，重要的是它编得出文件。
    private func swatch(_ color: UIColor = .systemRed) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120)).image { renderer in
            color.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
        }
    }

    private func filesInStore() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.sorted() ?? []
    }

    // MARK: - §34 落盘

    func testOriginalAndThumbnailAreBothWrittenAndReadable() throws {
        guard let identifier = images.store(swatch()) else { return XCTFail("原图没写进去") }
        XCTAssertTrue(identifier.hasSuffix(".heic") || identifier.hasSuffix(".jpg"), "文件名要带得出格式：\(identifier)")
        XCTAssertNotNil(images.image(for: identifier))
        XCTAssertNotNil(images.thumbnail(for: identifier))
        XCTAssertEqual(Set(filesInStore()), [identifier, ImageStore.Reference(fileName: identifier).thumbnailFileName])
    }

    func testDefaultStoreWritesUnderApplicationSupport() {
        let path = ImageStore.shared.root.path
        XCTAssertTrue(path.hasSuffix("Saury/Images"), "方案 §34 指定的位置：\(path)")
    }

    func testDeletingTakesBothCopiesWithIt() throws {
        guard let identifier = images.store(swatch()) else { return XCTFail("原图没写进去") }
        images.delete(identifier)
        XCTAssertTrue(filesInStore().isEmpty)
        XCTAssertNil(images.image(for: identifier))
        XCTAssertNil(images.thumbnail(for: identifier))
    }

    /// 老数据可能只有原图没有缩略图：列表不能因此空一块。
    func testThumbnailFallsBackToTheOriginalWhenTheSmallCopyIsMissing() throws {
        guard let identifier = images.store(swatch()) else { return XCTFail("原图没写进去") }
        try FileManager.default.removeItem(at: directory.appendingPathComponent(ImageStore.Reference(fileName: identifier).thumbnailFileName))
        XCTAssertNotNil(images.thumbnail(for: identifier))
    }

    func testMissingIdentifierReadsAsNoImage() {
        XCTAssertNil(images.image(for: nil))
        XCTAssertNil(images.thumbnail(for: ""))
        images.delete(nil)  // 不该炸
    }

    // MARK: - 存一件东西留下什么

    func testSavingAScanLeavesOneItemAndOneEventCarryingTheSamePicture() throws {
        let store = ContinuousScanStore(context: context, images: images)
        let saved = try store.save(confirmation(result(expiry: expiry), image: swatch()))

        XCTAssertFalse(saved.merged)
        XCTAssertEqual(saved.name, "纯牛奶 1L")
        let items = try context.fetch(FetchDescriptor<ExpiryItem>())
        let events = try context.fetch(FetchDescriptor<ExpiryEvent>())
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(events.count, 1, "扫进来的每一件都要在活动记录里留一条（方案 §34）")
        XCTAssertEqual(events.first?.eventType, .created)
        XCTAssertEqual(events.first?.imageIdentifier, items.first?.imageIdentifier)
        XCTAssertNotNil(images.image(for: events.first?.imageIdentifier), "记录上那个文件名要真能读出图")
    }

    func testScanningTheSameBatchTwiceKeepsOneItemAndTwoPictures() throws {
        let store = ContinuousScanStore(context: context, images: images)
        let first = try store.save(confirmation(result(expiry: expiry), image: swatch(.systemRed)))
        let second = try store.save(confirmation(result(expiry: expiry), image: swatch(.systemBlue)))

        XCTAssertTrue(second.merged, "同一批第二次只该加数量：\(first) / \(second)")
        let items = try context.fetch(FetchDescriptor<ExpiryItem>())
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.quantity, 2)

        let events = try context.fetch(FetchDescriptor<ExpiryEvent>()).sorted { $0.happenedAt < $1.happenedAt }
        XCTAssertEqual(events.count, 2, "两次扫描是两条历史，各自带自己那张图")
        XCTAssertEqual(Set(events.compactMap(\.imageIdentifier)).count, 2)
        XCTAssertEqual(events.map(\.eventType), [.created, .edited])
        XCTAssertEqual(filesInStore().count, 4, "两张原图 + 两张缩略图")
    }

    func testScanWithoutAnExpiryDateSavesNothingAndLeavesNoFileBehind() throws {
        let store = ContinuousScanStore(context: context, images: images)
        XCTAssertThrowsError(try store.save(confirmation(result(expiry: nil), image: swatch()))) { error in
            XCTAssertEqual(error as? ContinuousScanStore.StoreError, .noExpiryDate)
        }
        XCTAssertTrue(try context.fetch(FetchDescriptor<ExpiryItem>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ExpiryEvent>()).isEmpty)
        XCTAssertTrue(filesInStore().isEmpty, "没存下去的那一件不该在盘上留图")
    }

    /// 手动填的（没有图）也走同一条保存路径：有事件，但没有可展示的图。
    func testScanWithoutAPictureStillRecordsTheItem() throws {
        let store = ContinuousScanStore(context: context, images: images)
        XCTAssertNoThrow(try store.save(confirmation(result(expiry: expiry), image: nil)))
        let events = try context.fetch(FetchDescriptor<ExpiryEvent>())
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events.first?.imageIdentifier)
    }

    // MARK: - 备份要带得动这个指针

    func testThePicturePointerSurvivesABackupRoundTrip() throws {
        let store = ContinuousScanStore(context: context, images: images)
        _ = try store.save(confirmation(result(expiry: expiry), image: swatch()))
        let text = DataExportService.jsonText(
            items: try context.fetch(FetchDescriptor<ExpiryItem>()),
            events: try context.fetch(FetchDescriptor<ExpiryEvent>())
        )

        let restored = try ModelContainer(
            for: Schema(versionedSchema: SaurySchemaV3.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let restoredContext = ModelContext(restored)
        let summary = try DataExportService.importJSON(Data(text.utf8), into: restoredContext)
        XCTAssertEqual(summary.importedEvents, 1)

        let original = try XCTUnwrap(try context.fetch(FetchDescriptor<ExpiryEvent>()).first?.imageIdentifier)
        let imported = try XCTUnwrap(try restoredContext.fetch(FetchDescriptor<ExpiryEvent>()).first?.imageIdentifier)
        XCTAssertEqual(imported, original, "恢复之后记录还得指回同一张图")
        XCTAssertNotNil(images.image(for: imported))
    }

    // MARK: - §28 模板 + 图

    func testSecondScanOfTheSameBarcodePrefillsFromTheTemplateAndStillCarriesAPicture() throws {
        let store = ContinuousScanStore(context: context, images: images)
        // 第一次只认到条码和日期；存过之后模板记住了名称、单位这些常的东西。
        _ = try store.save(confirmation(result(expiry: expiry), image: swatch()))
        let template = try XCTUnwrap(ProductTemplateStore.template(forBarcode: barcode, in: context))
        template.location = "冰箱"
        try context.save()

        // 第二次换一批（日期不同，所以不是并数量），连名称都没认出来 —— 模板得把它补上，图也照样留。
        let later = Calendar.current.date(byAdding: .day, value: 30, to: expiry)!
        let bare = ExpiryOCRResult(entries: [
            ExpiryOCRCandidate(field: .barcode, value: .text(barcode), confidence: 0.9),
            ExpiryOCRCandidate(field: .expiryDate, value: .date(later, alternatives: []), confidence: 0.9),
        ])
        let added = try store.save(confirmation(bare, image: swatch(.systemGreen)))

        XCTAssertEqual(added.name, "纯牛奶 1L", "名称从模板补出来")
        let items = try context.fetch(FetchDescriptor<ExpiryItem>())
        XCTAssertEqual(items.count, 2, "换了日期就是另一批")
        let newest = try XCTUnwrap(items.first { $0.expiryDate == later })
        XCTAssertEqual(newest.location, "冰箱")
        XCTAssertNotNil(newest.imageIdentifier)
    }
}
