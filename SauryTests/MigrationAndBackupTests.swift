import XCTest
import SwiftData
@testable import Saury

/// V3 → V4 迁移：旧「到期物品」里只有分类为订阅的记录会进新产品。
final class MigrationTests: XCTestCase {
    @MainActor
    func testExpirySubscriptionConvertsToSubscription() throws {
        let item = ExpiryItem(
            name: "云储存 200GB",
            category: .subscription,
            expiryDate: BillingMath.calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 12))!,
            priceMinorUnits: 2100,
            currencyCode: "CNY",
            recurrence: .monthly,
            notes: "家人共享"
        )
        let snapshot = LegacyExpirySnapshot(item)
        let converted = try XCTUnwrap(Subscription(migratedFrom: snapshot))
        XCTAssertEqual(converted.name, "云储存 200GB")
        XCTAssertEqual(converted.cycle, .monthly)
        XCTAssertEqual(converted.priceMinorUnits, 2100)
        XCTAssertEqual(converted.currencyCode, "CNY")
        XCTAssertEqual(converted.state, .autoRenew)
        XCTAssertEqual(converted.notes, "家人共享")
        XCTAssertEqual(converted.id, item.id)
    }

    @MainActor
    func testNonSubscriptionItemsDoNotConvert() throws {
        let milk = ExpiryItem(name: "牛奶", category: .food, expiryDate: Date())
        XCTAssertNil(Subscription(migratedFrom: LegacyExpirySnapshot(milk)))
    }

    @MainActor
    func testRecurrenceMapping() throws {
        func convert(_ recurrence: ExpiryRecurrence, interval: Int? = nil) -> BillingCycle {
            let item = ExpiryItem(
                name: "x",
                category: .subscription,
                expiryDate: Date(),
                recurrence: recurrence,
                recurrenceInterval: interval
            )
            return Subscription(migratedFrom: LegacyExpirySnapshot(item))!.cycle
        }
        XCTAssertEqual(convert(.none), .oneTime)
        XCTAssertEqual(convert(.weekly), .weekly)
        XCTAssertEqual(convert(.monthly), .monthly)
        XCTAssertEqual(convert(.quarterly), .quarterly)
        XCTAssertEqual(convert(.everySixMonths), .semiannual)
        XCTAssertEqual(convert(.yearly), .yearly)
        XCTAssertEqual(convert(.custom, interval: 5), .custom)
    }

    @MainActor
    func testArchivedItemBecomesInactive() throws {
        let item = ExpiryItem(name: "旧会员", category: .subscription, expiryDate: Date(), state: .archived)
        let converted = try XCTUnwrap(Subscription(migratedFrom: LegacyExpirySnapshot(item)))
        XCTAssertEqual(converted.state, .inactive)
    }
}

/// 导入导出的 JSON/CSV 往返。
final class SubscriptionImportExportTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: Schema(versionedSchema: SaurySchemaV4.self),
            configurations: [configuration]
        )
    }

    @MainActor
    func testCSVImportCreatesSubscriptions() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let csv = """
        名称,金额,币种,周期
        Netflix,45,CNY,每月
        ChatGPT,20,USD,monthly
        护照换发,0,CNY,一次性
        """
        let count = try SubscriptionImportExport.importCSV(csv, into: context)
        XCTAssertEqual(count, 3)
        let all = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertEqual(all.count, 3)
        let netflix = try XCTUnwrap(all.first { $0.name == "Netflix" })
        XCTAssertEqual(netflix.cycle, .monthly)
        XCTAssertEqual(netflix.priceMinorUnits, 4500)
        let chatGPT = try XCTUnwrap(all.first { $0.name == "ChatGPT" })
        XCTAssertEqual(chatGPT.currencyCode, "USD")
        XCTAssertEqual(chatGPT.cycle, .monthly)
        let passport = try XCTUnwrap(all.first { $0.name == "护照换发" })
        XCTAssertEqual(passport.cycle, .oneTime)
    }

    @MainActor
    func testJSONRoundTrip() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let original = Subscription(
            name: "iCloud",
            priceMinorUnits: 6800,
            currencyCode: "CNY",
            cycle: .monthly,
            category: "cloud",
            startDate: Date()
        )
        context.insert(original)
        try context.save()

        let data = SubscriptionImportExport.exportJSON(subscriptions: [original])
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID()).json")
        try data.write(to: temp, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temp) }

        let imported = try SubscriptionImportExport.importFile(at: temp, into: context)
        XCTAssertEqual(imported, 1)
        let all = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertEqual(all.count, 2)
        let copy = try XCTUnwrap(all.last { $0.id != original.id })
        XCTAssertEqual(copy.name, "iCloud")
        XCTAssertEqual(copy.priceMinorUnits, 6800)
        XCTAssertEqual(copy.cycle, .monthly)
    }

    @MainActor
    func testMarkdownExportMentionsTotalAndPrompt() {
        let subscription = Subscription(
            name: "Netflix",
            priceMinorUnits: 4500,
            currencyCode: "CNY",
            cycle: .monthly,
            category: "video"
        )
        let markdown = SubscriptionImportExport.exportMarkdown(
            subscriptions: [subscription],
            defaultCurrency: "CNY",
            categories: DefaultCategories.items,
            includeAIPrompt: true
        )
        XCTAssertTrue(markdown.contains("Netflix"))
        XCTAssertTrue(markdown.contains("¥45.00/月"))
        XCTAssertTrue(markdown.contains("月均"))
        XCTAssertTrue(markdown.contains("分析"))
    }
}
