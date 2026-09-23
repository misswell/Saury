import Foundation
import SwiftData
import XCTest

@testable import Saury

/// 方案 §59（Backup V2）+ §60（幂等恢复）。
///
/// 一句话：备份格式要能往前也往后读。三代文件（V2、只写 `version` 的中途版、
/// 订阅时代那份 `decisions`）都得进得来，且同一个文件导入两次数据量不许变。
@MainActor
final class BackupTests: XCTestCase {
    /// 和 `LocationCatalog.key` 同一把钥匙：那行是 private，测试只能照抄。
    private let locationsKey = "qijian.locations"

    private var container: ModelContainer!
    private var context: ModelContext!
    private var savedLocations: [String]?

    private let expiry = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 12))!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Schema(versionedSchema: SaurySchemaV3.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = container.mainContext
        savedLocations = UserDefaults.standard.array(forKey: locationsKey) as? [String]
    }

    override func tearDown() {
        if let savedLocations {
            UserDefaults.standard.set(savedLocations, forKey: locationsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: locationsKey)
        }
        super.tearDown()
    }

    // MARK: - 帮助

    private func freshContext() throws -> ModelContext {
        let restored = try ModelContainer(
            for: Schema(versionedSchema: SaurySchemaV3.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(restored)
    }

    private func counts(in context: ModelContext) throws -> (items: Int, events: Int, templates: Int) {
        (try context.fetch(FetchDescriptor<ExpiryItem>()).count,
         try context.fetch(FetchDescriptor<ExpiryEvent>()).count,
         try context.fetch(FetchDescriptor<ProductTemplate>()).count)
    }

    private func item(_ id: UUID, in context: ModelContext) throws -> ExpiryItem {
        let found = try context.fetch(FetchDescriptor<ExpiryItem>()).first { $0.id == id }
        return try XCTUnwrap(found)
    }

    private func date(_ iso8601: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso8601), "测试里的日期写错了")
    }

    /// 两件物品、一条历史、一个模板，位置清单也换成这两项，好让备份里四张表都有东西。
    @discardableResult
    private func makeStock() throws -> UUID {
        let milk = ExpiryItem(name: "牛奶", category: .food, expiryDate: expiry,
                              barcode: "6901234567890", location: "冰箱")
        let cream = ExpiryItem(name: "面霜", category: .skincare, expiryDate: expiry.addingTimeInterval(86_400 * 30),
                               quantity: 2, unit: "罐", location: "浴室")
        context.insert(milk)
        context.insert(cream)
        context.insert(ExpiryEvent(eventType: .created, for: milk))
        ProductTemplateStore.remember(milk, in: context)
        LocationCatalog.replace(["冰箱", "浴室"])
        try context.save()
        return milk.id
    }

    private func exportText() throws -> String {
        DataExportService.jsonText(
            items: try context.fetch(FetchDescriptor<ExpiryItem>()),
            events: try context.fetch(FetchDescriptor<ExpiryEvent>()),
            templates: try context.fetch(FetchDescriptor<ProductTemplate>())
        )
    }

    // MARK: - §59 格式

    func testBackupCarriesSchemaVersionTwoAndAllFourTables() throws {
        _ = try makeStock()
        let data = try XCTUnwrap(Data(exportText().utf8))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(root["schemaVersion"] as? Int, 2, "方案 §59 定的键名是 schemaVersion")
        for key in ["exportedAt", "items", "events", "templates", "locations"] {
            XCTAssertNotNil(root[key], "V2 备份少了 \(key) 这张表")
        }
        XCTAssertEqual((root["items"] as? [Any])?.count, 2)
        XCTAssertEqual((root["templates"] as? [Any])?.count, 1)
        XCTAssertEqual((root["locations"] as? [String]), ["冰箱", "浴室"],
                       "位置清单要跟着走，否则换设备只拿得到默认那几个")
    }

    func testEveryExportedRowCarriesItsOwnIdentity() throws {
        _ = try makeStock()
        let data = try XCTUnwrap(Data(exportText().utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(SauryExport.self, from: data)

        XCTAssertEqual(Set(export.items.map(\.id)).count, 2, "物品靠 UUID 认身份")
        XCTAssertEqual(Set(export.events.map(\.itemID)).subtracting(export.items.map(\.id)).count, 0,
                       "历史指向的物品必须在同一份文件里")
        XCTAssertEqual(export.templates.map(\.barcode), ["6901234567890"],
                       "模板的身份就是条码那一列")
    }

    // MARK: - §60 幂等

    func testImportingTheSameBackupTwiceGrowsNothing() throws {
        _ = try makeStock()
        let text = try exportText()

        let target = try freshContext()
        let first = try DataExportService.importJSON(Data(text.utf8), into: target)
        let afterFirst = try counts(in: target)
        let locationsAfterFirst = LocationCatalog.all

        let second = try DataExportService.importJSON(Data(text.utf8), into: target)

        XCTAssert(afterFirst == (items: 2, events: 1, templates: 1), "两份物品、一条历史、一个模板，got \(afterFirst)")
        XCTAssert(try counts(in: target) == afterFirst, "重复导入不许让数据翻倍")
        XCTAssertEqual(second.importedItems, first.importedItems, "已存在的走更新，不是新插一条")
        XCTAssertEqual(second.importedEvents, 0)
        XCTAssertEqual(second.skippedEvents, 1, "同一条历史第二次要认出来")
        XCTAssertEqual(LocationCatalog.all, locationsAfterFirst, "位置清单也不能越导入越长")
    }

    func testImportWritesOverTheRecordItAlreadyHas() throws {
        let milkID = try makeStock()
        let text = try exportText()

        let target = try freshContext()
        try DataExportService.importJSON(Data(text.utf8), into: target)
        let imported = try item(milkID, in: target)
        imported.name = "鲜奶"
        imported.notes = "本机改的"
        try target.save()

        try DataExportService.importJSON(Data(text.utf8), into: target)
        let after = try item(milkID, in: target)
        XCTAssertEqual(try counts(in: target).items, 2)
        XCTAssertEqual(after.name, "牛奶", "方案 §60：已存在 → update")
        XCTAssertEqual(after.notes, "")
    }

    func testLocationsFromABackupMergeInsteadOfReplacingTheLocalList() throws {
        LocationCatalog.replace(["阳台"])
        let json = """
        {"schemaVersion":2,"exportedAt":"2026-09-01T00:00:00Z","items":[],"events":[],
         "templates":[],"locations":["冷冻室","阳台","阳台","  "]}
        """
        let summary = try DataExportService.importJSON(Data(json.utf8), into: try freshContext())

        XCTAssertEqual(LocationCatalog.all, ["阳台", "冷冻室"], "本机顺序不动，备份里多出来的追加在后面")
        XCTAssertEqual(summary.addedLocations, 1, "重复的和空串不算新增")
    }

    // MARK: - 前代文件

    /// 改造中途导出的那份写的是 `version`，也没有模板和位置。
    func testTheInterimBackupWithTheOldVersionKeyStillImports() throws {
        _ = try makeStock()
        let full = try XCTUnwrap(Data(exportText().utf8))
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: full) as? [String: Any])
        root.removeValue(forKey: "schemaVersion")
        root["version"] = 2
        root.removeValue(forKey: "templates")
        root.removeValue(forKey: "locations")
        let data = try JSONSerialization.data(withJSONObject: root)

        let target = try freshContext()
        let summary = try DataExportService.importJSON(data, into: target)
        XCTAssertEqual(try counts(in: target).items, 2)
        XCTAssertEqual(summary.importedEvents, 1)
    }

    /// 订阅时代（TestFlight build 2、3 导出的就是这种）：字段名完全不同，历史在 `decisions` 里。
    func testTheSubscriptionEraBackupLandsInTheNewModel() throws {
        let itemID = UUID()
        let json = """
        {"exportedAt":"2026-04-01T00:00:00Z",
         "items":[{"id":"\(itemID.uuidString)","name":"视频会员","amountMinorUnits":2500,
                   "currencyCode":"CNY","nextRenewalDate":"2026-05-01T00:00:00Z","cycle":"monthly",
                   "intervalMonths":1,"category":"entertainment","status":"active","isAutoRenewing":true,
                   "cancelByDate":"2026-04-28T00:00:00Z","reminderOffsets":[3,1],
                   "managementURLString":"https://example.com/manage","notes":"自动续费"}],
         "decisions":[{"renewalItemID":"\(itemID.uuidString)","itemName":"视频会员","action":"cancelled",
                       "amountMinorUnits":2500,"currencyCode":"CNY","happenedAt":"2026-04-20T00:00:00Z"}]}
        """
        let data = try XCTUnwrap(Data(json.utf8))

        let target = try freshContext()
        let summary = try DataExportService.importJSON(data, into: target)

        let item = try item(itemID, in: target)
        XCTAssertEqual(summary.importedItems, 1)
        XCTAssertEqual(item.category, .subscription, "续费日不是保质期，进来就得标成订阅")
        XCTAssertEqual(item.priceMinorUnits, 2500)
        XCTAssertEqual(item.recurrence, .monthly)
        XCTAssertEqual(item.actionDeadline, try date("2026-04-28T00:00:00Z"))
        XCTAssertEqual(item.sourceURL, "https://example.com/manage")
        XCTAssertEqual(item.state, .active)

        let event = try XCTUnwrap(try target.fetch(FetchDescriptor<ExpiryEvent>()).first)
        XCTAssertEqual(event.eventType, .cancelled, "旧决定要映射成新事件类型")
        XCTAssertEqual(event.itemID, itemID)

        let before = try counts(in: target)
        let again = try DataExportService.importJSON(data, into: target)
        XCTAssert(try counts(in: target) == before,
                  "老文件里的决定没有 id，靠内容算出来的那个也必须认得自己")
        XCTAssertEqual(again.importedEvents, 0)
        XCTAssertEqual(again.skippedEvents, 1)
    }

    // MARK: - 不是备份的文件

    func testAFileThatIsNotABackupSaysSo() throws {
        let target = try freshContext()

        XCTAssertThrowsError(try DataExportService.importJSON(Data("[1,2]".utf8), into: target))

        XCTAssertThrowsError(try DataExportService.importJSON(Data(#"{"hello":"world"}"#.utf8), into: target)) { error in
            XCTAssertEqual(error.localizedDescription, "读不出内容：这不是期见导出的备份，或者文件已经损坏。")
        }
    }
}
