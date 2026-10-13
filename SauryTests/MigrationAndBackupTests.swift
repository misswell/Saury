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
        let outcome = try SubscriptionImportExport.importCSV(csv, into: context)
        XCTAssertEqual(outcome.imported, 3)
        XCTAssertTrue(outcome.skipped.isEmpty)
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

    /// 金额读不出来的行不能悄悄存成 0，得跳过并且说清楚是哪一行、为什么。
    @MainActor
    func testCSVImportReportsUnreadableAmounts() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let csv = """
        名称,金额,币种,周期
        Netflix,45,CNY,monthly
        坏行,abc,CNY,monthly
        日元,1200.5,JPY,monthly
        """
        let outcome = try SubscriptionImportExport.importCSV(csv, into: context)
        XCTAssertEqual(outcome.imported, 1)
        XCTAssertEqual(outcome.skipped.count, 2)
        XCTAssertTrue(outcome.skipped[0].contains("坏行"))
        XCTAssertTrue(outcome.skipped[1].contains("日元"))
        let all = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertEqual(all.count, 1, "跳过的行一条都不落库")
        XCTAssertTrue(outcome.summaryText.contains("跳过 2 条"))
    }

    /// 老 JSON 格式以前只导订阅、不带编号：换机器一导，历史整段丢、重复导还翻倍。
    /// 现在补齐：稳定 UUID + 事件一起走。
    @MainActor
    func testJSONRoundTrip() throws {
        let sourceContainer = try makeContainer()
        let context = ModelContext(sourceContainer)
        let original = Subscription(
            name: "iCloud",
            priceMinorUnits: 6800,
            currencyCode: "CNY",
            cycle: .monthly,
            category: "cloud",
            startDate: Date()
        )
        context.insert(original)
        let event = SubscriptionEvent(subscriptionID: original.id, type: .charged,
                                      amountMinorUnits: 6800, currencyCode: "CNY",
                                      note: "去年那笔")
        context.insert(event)
        try context.save()

        let data = SubscriptionImportExport.exportJSON(subscriptions: [original], events: [event])
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID()).json")
        try data.write(to: temp, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temp) }

        let targetContainer = try makeContainer()
        let target = ModelContext(targetContainer)
        let imported = try SubscriptionImportExport.importFile(at: temp, into: target)
        XCTAssertEqual(imported.imported, 1)
        XCTAssertEqual(imported.eventsImported, 1, "事件也得跟着进来")
        XCTAssertTrue(imported.skipped.isEmpty, imported.summaryText)
        let all = try target.fetch(FetchDescriptor<Subscription>())
        XCTAssertEqual(all.count, 1)
        let copy = try XCTUnwrap(all.first)
        XCTAssertEqual(copy.id, original.id, "稳定编号原样带过去，重复导入才有依据")
        XCTAssertEqual(copy.name, "iCloud")
        XCTAssertEqual(copy.priceMinorUnits, 6800)
        XCTAssertEqual(copy.cycle, .monthly)
        let restoredEvent = try XCTUnwrap(target.fetch(FetchDescriptor<SubscriptionEvent>()).first)
        XCTAssertEqual(restoredEvent.id, event.id)
        XCTAssertEqual(restoredEvent.subscriptionID, copy.id, "事件要认得回同一条订阅")
        XCTAssertEqual(restoredEvent.note, "去年那笔")
    }

    /// 认领不到所属订阅的事件不写库，原因如实带回：只报「成功几条」就是把失败藏了。
    @MainActor
    func testJSONImportReportsUnmatchedEvents() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let subscription = Subscription(name: "Netflix", priceMinorUnits: 4500,
                                        currencyCode: "CNY", cycle: .monthly)
        let payload = SubscriptionImportExport.ExportPayload(
            exportedAt: Date(),
            subscriptions: [SubscriptionImportExport.exportedSubscription(subscription)],
            events: [SubscriptionImportExport.ExportedEvent(
                subscriptionName: "已经不存在的订阅", type: "charged",
                amountMinorUnits: 100, currencyCode: "CNY", note: "", happenedAt: Date()
            )]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID()).json")
        try encoder.encode(payload).write(to: temp, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temp) }

        let outcome = try SubscriptionImportExport.importFile(at: temp, into: context)
        XCTAssertEqual(outcome.imported, 1)
        XCTAssertEqual(outcome.eventsImported, 0)
        XCTAssertEqual(outcome.skipped.count, 1)
        XCTAssertTrue(outcome.skipped[0].contains("已经不存在的订阅"), outcome.skipped[0])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SubscriptionEvent>()), 0)
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

    /// 导出的月均必须就是统计服务算的那个数：两处各加一遍，迟早给出两个答案。
    @MainActor
    func testMarkdownMonthlyAverageMatchesStats() throws {
        let active = Subscription(name: "Netflix", priceMinorUnits: 4500, currencyCode: "CNY",
                                  cycle: .monthly, category: "video")
        let archived = Subscription(name: "旧网盘", priceMinorUnits: 9900, currencyCode: "CNY",
                                    cycle: .monthly, category: "cloud")
        archived.archivedAt = Date()
        let rates = ExchangeRateStore.shared.rates
        let markdown = SubscriptionImportExport.exportMarkdown(
            subscriptions: [active, archived],
            defaultCurrency: "CNY",
            categories: DefaultCategories.items,
            includeAIPrompt: false
        )
        let expected = SubscriptionStats(subscriptions: [active, archived], events: [],
                                         defaultCurrency: "CNY", rates: rates).recurringTotal()
        XCTAssertEqual(expected.minorUnits, 4500, "归档订阅不进月均")
        XCTAssertTrue(markdown.contains(expected.formatted), "导出里的月均要等于 \(expected.formatted)")
        XCTAssertFalse(markdown.contains("¥144.00/月"), "不能把归档的那份也加进去")
    }
}

/// 这一组走的是真的磁盘库 + 真的迁移阶段，不是内存里的字段映射。
final class RealStoreMigrationTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("saury-migration-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
        root = nil
    }

    /// V1（最早那版订阅）一路升到 V4：物品要变成订阅，决定记录要变成时间轴。
    func testV1StoreUpgradesAllTheWayToSubscriptionsAndHistory() throws {
        let store = root.appendingPathComponent("v1.store")
        let itemID = UUID()
        do {
            let legacy = try PersistenceController.makeLegacyContainer(url: store)
            let context = ModelContext(legacy)
            context.insert(RenewalItem(id: itemID, name: "Netflix", amountMinorUnits: 4500,
                                       currencyCode: "CNY", nextRenewalDate: Date(), cycleRawValue: "monthly"))
            context.insert(DecisionRecord(renewalItemID: itemID, itemName: "Netflix",
                                          actionRawValue: "continued", amountMinorUnits: 4500, currencyCode: "CNY"))
            context.insert(DecisionRecord(renewalItemID: itemID, itemName: "Netflix",
                                          actionRawValue: "snoozed", amountMinorUnits: 0, currencyCode: "CNY"))
            try context.save()
        }

        let upgraded = try PersistenceController.makeContainer(url: store)
        let context = ModelContext(upgraded)
        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        let events = try context.fetch(FetchDescriptor<SubscriptionEvent>())
        XCTAssertEqual(subscriptions.count, 1)
        XCTAssertEqual(subscriptions.first?.id, itemID, "编号要一路带过来")
        XCTAssertEqual(subscriptions.first?.priceMinorUnits, 4500)
        XCTAssertEqual(events.count, 2, "旧版每一次决定都是真实历史，不能只搬物品不搬账")
        XCTAssertEqual(Set(events.map(\.type)), [.charged, .skipped])
        XCTAssertTrue(events.contains { $0.note.contains("已续期") }, events.map(\.note).description)
        XCTAssertEqual(events.filter { $0.subscriptionID == itemID }.count, 2)
    }

    /// V2 库（已经有数据）+ 新表：轻量迁移这一跳也必须把历史带过来。
    func testV2StoreKeepsItemsAndEventsThroughTheLightweightStage() throws {
        let store = root.appendingPathComponent("v2.store")
        let itemID = UUID()
        do {
            let previous = try PersistenceController.makeV2Container(url: store)
            let context = ModelContext(previous)
            let item = ExpiryItem(id: itemID, name: "云储存 200GB", category: .subscription,
                                  expiryDate: Date(), priceMinorUnits: 2100, currencyCode: "CNY",
                                  recurrence: .monthly)
            context.insert(item)
            context.insert(ExpiryEvent(eventType: .renewed, for: item))
            try context.save()
        }

        let upgraded = try PersistenceController.makeContainer(url: store)
        let context = ModelContext(upgraded)
        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertEqual(subscriptions.count, 1)
        XCTAssertEqual(subscriptions.first?.id, itemID)
        XCTAssertEqual(subscriptions.first?.cycle, .monthly)
        let events = try context.fetch(FetchDescriptor<SubscriptionEvent>())
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.amountMinorUnits, 2100)
    }

    /// V3 里食品、药片这些在新产品没有对应物：物品不迁，它们的事件也别留下成孤儿。
    func testV3StoreDropsUnrelatedItemsWithoutLeavingOrphanEvents() throws {
        let store = root.appendingPathComponent("v3.store")
        do {
            let previous = try PersistenceController.makeV3Container(url: store)
            let context = ModelContext(previous)
            let subscriptionItem = ExpiryItem(name: "视频会员", category: .subscription, expiryDate: Date(),
                                              priceMinorUnits: 2500, currencyCode: "CNY", recurrence: .monthly)
            let milk = ExpiryItem(name: "牛奶", category: .food, expiryDate: Date())
            context.insert(subscriptionItem)
            context.insert(milk)
            context.insert(ExpiryEvent(eventType: .renewed, for: subscriptionItem))
            context.insert(ExpiryEvent(eventType: .consumed, for: milk))
            try context.save()
        }

        let upgraded = try PersistenceController.makeContainer(url: store)
        let context = ModelContext(upgraded)
        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        let events = try context.fetch(FetchDescriptor<SubscriptionEvent>())
        XCTAssertEqual(subscriptions.count, 1, "只有分类是订阅的记录进新产品")
        XCTAssertEqual(subscriptions.first?.name, "视频会员")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.subscriptionID, subscriptions.first?.id)
    }

    /// 体检报告跑在真迁移出来的库上：升级完就应该一条问题都查不出来。
    func testMigratedLibraryPassesTheIntegrityCheck() throws {
        let store = root.appendingPathComponent("v3-clean.store")
        do {
            let previous = try PersistenceController.makeV3Container(url: store)
            let context = ModelContext(previous)
            let item = ExpiryItem(name: "音乐会员", category: .subscription, expiryDate: Date(),
                                  priceMinorUnits: 1500, currencyCode: "CNY", recurrence: .yearly)
            context.insert(item)
            context.insert(ExpiryEvent(eventType: .renewed, for: item))
            try context.save()
        }
        let upgraded = try PersistenceController.makeContainer(url: store)
        let context = ModelContext(upgraded)
        let report = StoreIntegrityReport.check(
            subscriptions: try context.fetch(FetchDescriptor<Subscription>()),
            events: try context.fetch(FetchDescriptor<SubscriptionEvent>()),
            categories: DefaultCategories.items
        )
        XCTAssertTrue(report.isClean, report.issues.map(\.detail).description)
    }

    /// 老库那几行的「要不要提醒」由启动时的补算落成开关，规则按「用户当时看到的说法」下判。
    ///
    /// 旧库里 0 天在新增页和详情页上都写着「不提醒」，调度器却把它读成「当天提醒」。
    /// 补算只能选一个：选用户看到的那一句（§5.1 不许静默改变提醒规则）。
    /// 天数原样留着 —— 用户将来把开关打开时，他当初挑的那一天还在。
    ///
    /// # 这一条为什么不是 Schema 迁移阶段
    ///
    /// `VersionedSchema.models` 只能列**在用的**类型，所以「加这一列之前那一版」和当前版
    /// 交得出同一份模型；`.custom(fromVersion:toVersion:)` 在建 stage 的当场就抛
    /// 「The current model reference and the next model reference cannot be equal」，
    /// 装着老库的设备一打开 App 就闪退。补一列交给 CoreData 的自动轻量迁移，
    /// 补一个结论只能自己跑一趟 —— 见 `ReminderIntentBackfill`。
    ///
    /// # 这一条测不到什么（诚实交代）
    ///
    /// 这里造的「V4 库」用的还是当前模型类，物理上已经带着 `remindersEnabled` 这一列。
    /// 真·发布版 V4 的库里没有这一列 —— 那个库只能用升级前的构建造出来，这台机器上没有。
    /// 所以这里证的是「补算规则 + 不许盖 updatedAt」，
    /// 「缺列时自动补列」那一步要靠 §15 的升级前构建装机验收补。
    @MainActor
    func testReminderIntentBackfillUsesTheOldMeaningOfZeroDays() throws {
        let store = root.appendingPathComponent("v4-backfill.store")
        let defaults = makeBackfillDefaults()
        let createdAt = BillingMath.calendar.date(from: DateComponents(year: 2025, month: 5, day: 6, hour: 9))!
        do {
            let previous = try PersistenceController.makeV4Container(url: store)
            let context = ModelContext(previous)
            // 这三条都是旧版造得出来的样子：旧版没有开关，「不提醒」只能靠把天数拨到 0 表达。
            context.insert(Subscription(name: "当天提醒", startDate: Date(),
                                        remindersEnabled: true, reminderDays: 0, createdAt: createdAt))
            context.insert(Subscription(name: "提前三天", startDate: Date(),
                                        remindersEnabled: true, reminderDays: 3, createdAt: createdAt))
            context.insert(Subscription(name: "提前一天", startDate: Date(),
                                        remindersEnabled: false, reminderDays: 1, createdAt: createdAt))
            try context.save()
        }

        // 补算跑在升级后那个容器上 —— 也就是用户真实打开 App 的那一趟。
        let upgraded = try PersistenceController.makeContainer(url: store)
        XCTAssertEqual(ReminderIntentBackfill.runIfNeeded(container: upgraded, defaults: defaults), 2,
                       "0 天那条要从「开」翻成「关」，天数 > 0 却没开的要翻开")

        // 顺序不参与断言：SwiftData 不带排序描述符的 fetch 本来就不保证次序，
        // 这里要钉的只有「一条都不能少」。
        let fetched = try ModelContext(upgraded).fetch(FetchDescriptor<Subscription>())
        XCTAssertEqual(Set(fetched.map(\.name)), Set(["提前一天", "提前三天", "当天提醒"]), "一条订阅都不能少")

        let sameDay = fetched.first { $0.name == "当天提醒" }
        XCTAssertFalse(sameDay?.remindersEnabled ?? true, "0 天在旧界面上就是「不提醒」")
        XCTAssertEqual(sameDay?.reminderDays, 0, "天数不许被顺手改成 3")

        let threeDays = fetched.first { $0.name == "提前三天" }
        XCTAssertTrue(threeDays?.remindersEnabled ?? false)
        XCTAssertEqual(threeDays?.reminderDays, 3)

        let oneDay = fetched.first { $0.name == "提前一天" }
        XCTAssertTrue(oneDay?.remindersEnabled ?? false,
                      "旧版没有单独关提醒的开关：天数 > 0 就是当初选了要提醒")

        // 补算不是用户改动：盖了时间戳，升级完的那台设备会把每一行都当成
        // 「本机这份最新」整片推上云，把另一台设备刚改的东西盖掉。
        XCTAssertEqual(sameDay?.updatedAt, createdAt, "补算不许动 updatedAt")
        XCTAssertEqual(threeDays?.updatedAt, createdAt)
        XCTAssertEqual(oneDay?.updatedAt, createdAt)
    }

    /// 补算只管「这一版之前就在库里的那几行」。跑过之后再写进来的行，
    /// 用户看见的是新语义（0 天 = 当天提醒），不许下一次启动又给他关回去。
    @MainActor
    func testReminderIntentBackfillRunsOnceAndLeavesLaterChoicesAlone() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let defaults = makeBackfillDefaults()
        let context = ModelContext(container)
        context.insert(Subscription(name: "当天提醒", startDate: Date(),
                                    remindersEnabled: true, reminderDays: 0))
        try context.save()

        XCTAssertEqual(ReminderIntentBackfill.runIfNeeded(container: container, defaults: defaults), 1)
        XCTAssertNotNil(defaults.object(forKey: ReminderIntentBackfill.doneKey), "跑成过一次就留下凭据")

        // 新表单里明确选的「当天提醒」：开 + 0 天，这个组合旧版根本表达不出来。
        context.insert(Subscription(name: "新选当天", startDate: Date(),
                                    remindersEnabled: true, reminderDays: 0))
        try context.save()

        XCTAssertNil(ReminderIntentBackfill.runIfNeeded(container: container, defaults: defaults),
                     "第二趟必须一格都不动")
        let fetched = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertEqual(fetched.first { $0.name == "新选当天" }?.remindersEnabled, true,
                       "补算不能把用户后来的选择改回去")
        XCTAssertEqual(fetched.first { $0.name == "当天提醒" }?.remindersEnabled, false)
    }

    /// 三条入口共用同一个说法：老备份文件、老云端载荷、老库补算，不许给同一份数据判出相反结果。
    func testBackfillRuleIsTheSameRuleLegacyPayloadsUse() {
        for days in [0, 1, 3, 30] {
            XCTAssertEqual(ReminderIntentBackfill.intent(reminderDays: days), days > 0)
            let legacy = SubscriptionImportExport.ExportedSubscription(
                name: "Netflix", plan: "", colorHexes: [], priceMinorUnits: 4500,
                currencyCode: "CNY", cycle: "monthly", customMonths: 1, category: "video",
                state: "autoRenew", startDate: Date(timeIntervalSince1970: 1_700_000_000),
                reminderDays: days, remindersEnabled: nil,
                shareEnabled: false, shareHeadcount: 1,
                shareMode: "even", shareMyMinorUnits: 0, paymentMethod: "", notes: "",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            XCTAssertEqual(legacy.resolvedRemindersEnabled, ReminderIntentBackfill.intent(reminderDays: days),
                           "老文件里的 \(days) 天和老库里的 \(days) 天必须是同一句话")
        }
    }

    // MARK: - 开库之前先问文件：判不清就当老库

    /// 刚写完的老库必须被认成老库 —— 这一条是那趟随机失败的回归测试。
    ///
    /// 坏法是：`Z_METADATA` 那一行还躺在 `-wal` 里，只读打开读不到版本章，于是「读不出来」
    /// 被当成「已经在本机这一版」，CoreData 对着老库做自动迁移；旧实体在它眼里是要删掉的表，
    /// 1 条订阅变成 0 条 —— 测试里只是断言失败，真机上就是用户的账没了。
    /// 版本章真读不到时，表名还在主文件里，所以这里只要求「不许认成新版」，
    /// 具体走哪条路（读到章 / 靠表名兜底）由 `opensWithDeclaredStages` 那条测试钉。
    func testFreshlyWrittenLegacyStoreIsNeverReadAsTheCurrentVersion() throws {
        let store = root.appendingPathComponent("probe-v3.store")
        do {
            let previous = try PersistenceController.makeV3Container(url: store)
            let context = ModelContext(previous)
            context.insert(ExpiryItem(name: "视频会员", category: .subscription, expiryDate: Date(),
                                      priceMinorUnits: 2500, currencyCode: "CNY", recurrence: .monthly))
            try context.save()
        }

        switch StoreFileProbe.schemaEvidence(at: store) {
        case .stamped(let version):
            XCTAssertTrue(["1.0.0", "2.0.0", "3.0.0"].contains(version), "V3 库盖的版本章读成了 \(version)")
        case .legacyTables:
            break  // 版本章没落进主文件，表名兜住了 —— 兜底存在的意义就在这一下
        default:
            XCTFail("老库被认成 \(StoreFileProbe.schemaEvidence(at: store))，会被当成不用迁移的那一种开法")
        }
    }

    /// 反过来：本机这一版的库不许被当成老库。带计划开它就是把设备上那次闪退再演一遍
    /// （新加的那一列做不成迁移阶段，见 `Docs/DATA_MIGRATION.md`）。
    func testCurrentVersionStoreIsNotReadAsALegacyLibrary() throws {
        let store = root.appendingPathComponent("probe-v4.store")
        do {
            let previous = try PersistenceController.makeV4Container(url: store)
            let context = ModelContext(previous)
            context.insert(Subscription(name: "Netflix", priceMinorUnits: 4500,
                                        currencyCode: "CNY", cycle: .monthly))
            try context.save()
        }

        let evidence = StoreFileProbe.schemaEvidence(at: store)
        XCTAssertFalse(PersistenceController.opensWithDeclaredStages(for: evidence),
                       "V4 库的证据被判成老库了：\(evidence)")
        if case .stamped(let version) = evidence {
            XCTAssertEqual(version, "4.0.0")
        }
    }

    /// 判断本身单独钉：只许「看清了是本机这一版」这一种证据不带迁移计划。
    /// 不碰 CoreData，专钉规则 —— 开库结果撞对了不代表规则写对了。
    func testOnlyUnambiguousCurrentVersionEvidenceSkipsTheDeclaredStages() {
        for evidence in [StoreFileProbe.SchemaEvidence.absent, .legacyTables, .unreadable] {
            XCTAssertTrue(PersistenceController.opensWithDeclaredStages(for: evidence),
                          "\(evidence) 判不清，必须走那条不会洗数据的老路")
        }
        for version in ["1.0.0", "2.0.0", "3.0.0"] {
            XCTAssertTrue(PersistenceController.opensWithDeclaredStages(for: .stamped(version: version)))
        }
        XCTAssertFalse(PersistenceController.opensWithDeclaredStages(for: .currentTables))
        XCTAssertFalse(PersistenceController.opensWithDeclaredStages(for: .stamped(version: "4.0.0")))
    }

    /// 空位置和「这文件压根不是库」是两种不同的判不清，得能分开。
    func testProbeSeparatesMissingFileFromUnreadableFile() throws {
        XCTAssertEqual(StoreFileProbe.schemaEvidence(at: root.appendingPathComponent("nope.store")), .absent)
        let junk = root.appendingPathComponent("junk-probe.store")
        try Data("this is definitely not a sqlite database file".utf8).write(to: junk)
        XCTAssertEqual(StoreFileProbe.schemaEvidence(at: junk), .unreadable)
    }

    /// 每台设备一套干净的偏好：补算的哨兵存在哪台设备上，测完不许留在真偏好里。
    private func makeBackfillDefaults() -> UserDefaults {
        let name = "saury.tests.backfill.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
        }
        return defaults
    }
}

/// 账本跑在真库上：存进去再取出来，已登记/预计的拆法必须和在内存里算的一模一样。
final class LedgerPersistenceTests: XCTestCase {
    private var calendar: Calendar { BillingMath.calendar }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 9))!
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Schema(versionedSchema: SaurySchemaV4.self),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @MainActor
    func testCumulativeSplitSurvivesSaveAndFetch() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let subscription = Subscription(name: "老订阅", priceMinorUnits: 1000, currencyCode: "CNY",
                                        cycle: .monthly, startDate: date(2026, 8, 11))
        context.insert(subscription)
        context.insert(SubscriptionEvent(subscriptionID: subscription.id, type: .charged,
                                         amountMinorUnits: 900, currencyCode: "CNY",
                                         happenedAt: date(2026, 8, 11)))
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Subscription>())
        let events = try context.fetch(FetchDescriptor<SubscriptionEvent>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(events.count, 1)

        let stats = SubscriptionStats(subscriptions: fetched, events: events,
                                      defaultCurrency: "CNY", rates: [:])
        let now = date(2026, 10, 11)
        let totals = stats.cumulative(now: now)
        XCTAssertEqual(totals.recordedCount, 1)
        XCTAssertEqual(totals.projectedCount, 2, "9/11、10/11 按周期推算")
        XCTAssertEqual(totals.recorded.minorUnits, 900, "登记过的价不会被现价覆盖")
        XCTAssertEqual(totals.projectedPast.minorUnits, 2000)
        XCTAssertEqual(totals.combined.minorUnits, 2900)

        let buckets = stats.monthlyBuckets(now: now)
        XCTAssertEqual(buckets.count, 3)
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.total.minorUnits }, totals.combined.minorUnits)
        XCTAssertEqual(buckets.last?.recorded.minorUnits, 900, "最早那月带登记的那笔")
    }
}
