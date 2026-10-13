import XCTest
import SwiftData
@testable import Saury

/// 任务书 §3.2 的冲突判定：去重优先按稳定 UUID，疑似重复不许未经确认就覆盖本机数据。
///
/// 这里最要紧的几条都不是「算得对不对」，而是「用户什么都不改直接点确认会不会出事」：
/// 同名不同数字必须默认跳过、文件里自己撞车的只能导一条、更新只覆盖文件里写了的那几列。
final class ImportConflictTests: XCTestCase {
    private func parse(_ csv: String) throws -> ImportParser.Table {
        try ImportParser.parse(data: Data(csv.utf8), fileName: "订阅.csv",
                               categories: DefaultCategories.items, defaultCurrency: "CNY")
    }

    private func plan(_ csv: String, local: [SubscriptionDraft]) throws -> ImportConflictResolver.Plan {
        ImportConflictResolver.resolve(table: try parse(csv), local: local)
    }

    private func parseJSON(_ text: String) throws -> ImportParser.Table {
        try ImportParser.parse(data: Data(text.utf8), fileName: "外部.json",
                               categories: DefaultCategories.items, defaultCurrency: "CNY")
    }

    private func local(_ name: String,
                       id: UUID = UUID(),
                       price: Int = 4500,
                       cycle: BillingCycle = .monthly,
                       currency: String = "CNY") -> SubscriptionDraft {
        var draft = SubscriptionDraft(id: id, name: name, priceMinorUnits: price,
                                      currencyCode: currency, cycle: cycle)
        draft.notes = "本机备注"
        draft.reminderDays = 5
        draft.iconSymbolName = "play.tv.fill"
        draft.shareEnabled = true
        draft.shareHeadcount = 4
        draft.paymentMethod = "微信"
        draft.plan = "标准版"
        return draft
    }

    // MARK: - 认得到本机那一条时该怎么定

    /// 编号相同就是同一条：默认更新，而且不给「新建」这个选项 ——
    /// 库里 `id` 是唯一列，选新建只会静默变成覆盖，等于给用户一个假按钮。
    func testStableIDCollisionDefaultsToUpdateAndRefusesCreate() throws {
        let id = UUID()
        let table = try parseJSON("""
        [{"id":"\(id.uuidString)","name":"iCloud","price":"68","currency":"CNY","cycle":"monthly"}]
        """)
        let plan = ImportConflictResolver.resolve(table: table,
                                                  local: [local("iCloud", id: id, price: 6000)])
        let item = try XCTUnwrap(plan.items.first)
        XCTAssertEqual(item.matchKind, .stableID)
        XCTAssertEqual(item.decision, .update)
        XCTAssertEqual(item.allowedDecisions, [.update, .skip])
        XCTAssertEqual(plan.setting(rowID: item.id, decision: .create).items[0].decision, .update,
                       "编号撞了就不该能选新建")
        XCTAssertEqual(item.diffs, [ImportConflictResolver.Diff(field: .amount,
                                                                localText: "60.00", incomingText: "68.00")])
    }

    /// 只认得出同名、数字不一样：默认跳过。这是 §3.2 那条硬规矩的正身。
    func testSameNameWithDifferentNumbersDefaultsToSkip() throws {
        let plan = try plan("名称,金额,币种,周期\nNetflix,60,CNY,monthly",
                            local: [local("Netflix")])
        let item = try XCTUnwrap(plan.items.first)
        XCTAssertEqual(item.matchKind, .sameName)
        XCTAssertEqual(item.decision, .skip)
        XCTAssertEqual(item.suggested, .skip)
        XCTAssertTrue(item.reasons.contains { $0.contains("覆盖") }, item.reasons.description)
        XCTAssertEqual(item.diffs.count, 1)
        XCTAssertEqual(item.diffs.first?.incomingText, "60.00")
        XCTAssertTrue(item.allowedDecisions.contains(.update), "用户可以主动选覆盖，但不是默认")
        XCTAssertTrue(plan.notes.contains { $0.contains("同名订阅") }, plan.notes.description)
    }

    /// 内容一模一样：默认不重复导，说清是本机已有。
    func testIdenticalRecordDefaultsToSkipAndSaysWhy() throws {
        let plan = try plan("名称,金额,币种,周期\nNetflix,45,CNY,monthly",
                            local: [local("Netflix")])
        let item = try XCTUnwrap(plan.items.first)
        XCTAssertEqual(item.matchKind, .sameContent)
        XCTAssertEqual(item.decision, .skip)
        XCTAssertTrue(item.reasons.contains { $0.contains("一模一样") }, item.reasons.description)
        XCTAssertTrue(plan.notes.contains { $0.contains("一模一样") }, plan.notes.description)
    }

    /// 名字相同但日期被改成「今天」也算同一条：跨账本导出时日期几乎总在变。
    func testSameContentIgnoresStartDateDifferences() throws {
        let plan = try plan("名称,金额,币种,周期,起始日期\nNetflix,45,CNY,monthly,2020-01-01",
                            local: [local("Netflix")])
        XCTAssertEqual(plan.items.first?.matchKind, .sameContent)
    }

    // MARK: - 文件里自己撞车

    /// 同一份文件里重复的两行只能导一条：都写的话后一条会静默盖掉前一条，等于凭空少一行。
    func testDuplicateRowsInsideTheFileOnlyWriteOnce() throws {
        let plan = try plan("""
        名称,金额,币种,周期
        Netflix,45,CNY,monthly
        Netflix,45,CNY,monthly
        """, local: [])
        XCTAssertEqual(plan.items[0].decision, .create)
        XCTAssertTrue(plan.items[1].duplicatedInFile)
        XCTAssertEqual(plan.items[1].decision, .skip)
        XCTAssertEqual(plan.projection.creates, 1)
        XCTAssertEqual(plan.writes.count, 1)
        XCTAssertTrue(plan.notes.contains { $0.contains("自己撞了车") }, plan.notes.description)
    }

    /// 同一个编号出现两次：第二条不写。
    func testSameStableIDTwiceInOneFileSkipsTheSecond() throws {
        let id = UUID()
        let table = try parseJSON("""
        [{"id":"\(id.uuidString)","name":"iCloud","price":"68","cycle":"monthly"},
         {"id":"\(id.uuidString)","name":"iCloud","price":"210","cycle":"yearly"}]
        """)
        let plan = ImportConflictResolver.resolve(table: table, local: [])
        XCTAssertTrue(plan.items[1].duplicatedInFile)
        XCTAssertEqual(plan.items[1].decision, .skip)
        XCTAssertEqual(plan.writes.count, 1)
    }

    /// 两行改同一条本机订阅：后一条默认跳过，不然「先改 A 再改 B」会被理解成两次都生效。
    func testTwoRowsClaimingTheSameLocalRowSkipTheSecond() throws {
        let plan = try plan("""
        名称,金额,币种,周期
        Netflix,45,CNY,monthly
        netflix,60,CNY,monthly
        """, local: [local("Netflix")])
        XCTAssertEqual(plan.items[0].matchKind, .sameContent)
        XCTAssertTrue(plan.items[1].duplicatedInFile, "名字大小写不同，指向的还是同一条")
        XCTAssertEqual(plan.items[1].decision, .skip)
    }

    // MARK: - 更新到底改了什么

    /// 更新只覆盖文件里写了的那几列：本机那条的备注、提醒、共享、图标一个都不该被冲掉。
    func testUpdateOverwritesOnlyTheColumnsTheFileCarries() throws {
        let id = UUID()
        let anchored = local("iCloud", id: id)
        let table = try parseJSON("""
        [{"id":"\(id.uuidString)","name":"iCloud","price":"68","currency":"CNY","cycle":"monthly"}]
        """)
        let plan = ImportConflictResolver.resolve(table: table, local: [anchored])
        let writes = plan.writes
        XCTAssertEqual(writes.count, 1)
        let draft = try XCTUnwrap(writes.first?.draft)
        XCTAssertEqual(draft.id, id, "更新的是本机那条，不是新号")
        XCTAssertEqual(draft.priceMinorUnits, 6800)
        XCTAssertEqual(draft.notes, "本机备注")
        XCTAssertEqual(draft.reminderDays, 5)
        XCTAssertEqual(draft.iconSymbolName, "play.tv.fill")
        XCTAssertEqual(draft.shareHeadcount, 4)
        XCTAssertEqual(draft.paymentMethod, "微信")
        XCTAssertEqual(draft.plan, "标准版")
    }

    /// 空单元格等于「这一列没写」，不是「把本机这一列清空」。
    func testEmptyColumnsDoNotBlankLocalValues() throws {
        let plan = try plan("名称,金额,备注\nNetflix,60,\n", local: [local("Netflix")])
        let item = try XCTUnwrap(plan.items.first)
        let forced = plan.setting(rowID: item.id, decision: .update)
        XCTAssertEqual(forced.writes.first?.draft.notes, "本机备注")
        XCTAssertEqual(forced.writes.first?.draft.priceMinorUnits, 6000)
    }

    /// 旧版 JSON 导出本来就是这条订阅的完整快照：更新它时整份覆盖才是它该有的意思。
    func testWholeRecordJSONUpdateReplacesEveryFieldButTheID() throws {
        let id = UUID()
        let created = Date(timeIntervalSince1970: 1_600_000_000)
        let item = SubscriptionImportExport.ExportedSubscription(
            id: id, name: "iCloud", plan: "50GB", iconSymbolName: "icloud.fill", iconImageFile: nil,
            iconColorHex: nil, colorHexes: [], priceMinorUnits: 6800, currencyCode: "CNY",
            cycle: "monthly", customMonths: 1, category: "cloud", state: "autoRenew",
            startDate: created, endDate: nil, reminderDays: 1, shareEnabled: false, shareHeadcount: 1,
            shareMode: "even", shareMyMinorUnits: 0, paymentMethod: "", notes: "", createdAt: created)
        let data = try JSONEncoder.backup.encode(
            SubscriptionImportExport.ExportPayload(exportedAt: created, subscriptions: [item], events: []))
        let table = try ImportParser.parse(data: data, fileName: "导出.json",
                                          categories: DefaultCategories.items, defaultCurrency: "CNY")
        let anchored = local("iCloud", id: id)
        let plan = ImportConflictResolver.resolve(table: table, local: [anchored])
        let draft = try XCTUnwrap(plan.writes.first?.draft)
        XCTAssertEqual(draft.id, id)
        XCTAssertEqual(draft.notes, "", "整份快照里没有备注，就是真的没有备注")
        XCTAssertEqual(draft.reminderDays, 1)
        XCTAssertFalse(draft.shareEnabled)
        XCTAssertNil(plan.writes.first?.createdAt, "更新不该顺手改写本机的创建时间")
    }

    // MARK: - 预估与勾选

    func testProjectionCountsBlockedCreatesAndSkips() throws {
        let plan = try plan("""
        名称,金额,币种,周期
        新的,45,CNY,monthly
        Netflix,45,CNY,monthly
        读不出来,abc,CNY,monthly
        """, local: [local("Netflix")])
        let projection = plan.projection
        XCTAssertEqual(projection.total, 3)
        XCTAssertEqual(projection.creates, 1)
        XCTAssertEqual(projection.updates, 0)
        XCTAssertEqual(projection.skips, 2)
        XCTAssertEqual(projection.blocked, 1)
        XCTAssertTrue(projection.summaryText.contains("新增 1 条"), projection.summaryText)
        XCTAssertTrue(projection.summaryText.contains("纠错"), projection.summaryText)
        XCTAssertEqual(plan.writes.count, 1)
    }

    /// 全选把能导的都放上：本机有的走更新、没有的走新增，修不好的那行不参与。
    func testSelectAllEnablesEverythingThatCanBeEnabled() throws {
        let selected = try plan("""
        名称,金额,币种,周期
        新的,45,CNY,monthly
        Netflix,45,CNY,monthly
        读不出来,abc,CNY,monthly
        """, local: [local("Netflix")]).settingAll(true)
        XCTAssertEqual(selected.projection.creates, 1)
        XCTAssertEqual(selected.projection.updates, 1)
        XCTAssertEqual(selected.projection.skips, 1)
        XCTAssertTrue(selected.items[2].isBlocked)
        XCTAssertEqual(selected.items[2].decision, .skip, "修不好的行全选也不该被点亮")
        XCTAssertEqual(selected.items[2].allowedDecisions, [.skip])

        let cleared = selected.settingAll(false)
        XCTAssertTrue(cleared.projection.isNothingSelected)
        XCTAssertTrue(cleared.writes.isEmpty)
    }

    /// 改好字段之后同一行才允许新增：挡住的时候只有「跳过」能选。
    func testBlockedRowBecomesImportableAfterFixingIt() throws {
        let table = try parse("名称,金额,币种,周期\nNetflix,abc,CNY,monthly")
        var plan = ImportConflictResolver.resolve(table: table, local: [])
        XCTAssertTrue(plan.items[0].isBlocked)
        XCTAssertEqual(plan.items[0].allowedDecisions, [.skip])
        XCTAssertEqual(plan.items[0].headline, "先修好这 1 个问题")

        let fixed = table.editing(rowID: table.rows[0].id, field: .amount, to: "45")
        plan = ImportConflictResolver.resolve(table: fixed, local: [])
        XCTAssertFalse(plan.items[0].isBlocked)
        XCTAssertEqual(plan.items[0].decision, .create)
        XCTAssertEqual(plan.writes.count, 1)
    }

    /// 一行带着的历史事件要算进预估，跳过的行不贡献事件。
    func testProjectedEventsFollowSelectedRows() throws {
        let id = UUID()
        let event = SubscriptionImportExport.ExportedEvent(
            id: UUID(), subscriptionID: id, subscriptionName: "iCloud", type: "charged",
            amountMinorUnits: 2100, currencyCode: "CNY", note: "去年那笔",
            happenedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let item = SubscriptionImportExport.ExportedSubscription(
            id: id, name: "iCloud", plan: "", iconSymbolName: nil, iconImageFile: nil, iconColorHex: nil,
            colorHexes: [], priceMinorUnits: 2100, currencyCode: "CNY", cycle: "yearly", customMonths: 1,
            category: "cloud", state: "autoRenew", startDate: Date(timeIntervalSince1970: 1_600_000_000),
            endDate: nil, reminderDays: 3, shareEnabled: false, shareHeadcount: 1, shareMode: "even",
            shareMyMinorUnits: 0, paymentMethod: "", notes: "", createdAt: Date(timeIntervalSince1970: 1_600_000_000))
        let payload = SubscriptionImportExport.ExportPayload(exportedAt: Date(), subscriptions: [item],
                                                            events: [event])
        let table = try ImportParser.parse(data: JSONEncoder.backup.encode(payload), fileName: "导出.json",
                                           categories: DefaultCategories.items, defaultCurrency: "CNY")
        let plan = ImportConflictResolver.resolve(table: table, local: [])
        XCTAssertEqual(plan.projection.events, 1)
        XCTAssertEqual(plan.projection.summaryText.contains("历史事件"), true)
        XCTAssertEqual(plan.settingAll(false).projection.events, 0)
    }

    // MARK: - 落库

    @MainActor
    private func freshContext() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema(versionedSchema: SaurySchemaV4.self),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    /// 「取消后数据库不变」：一条都不选的时候什么都不写，本机数字原样。
    @MainActor
    func testNothingSelectedWritesNothing() throws {
        let context = try freshContext()
        let id = UUID()
        context.insert(Subscription(id: id, name: "Netflix", priceMinorUnits: 4500,
                                    currencyCode: "CNY", cycle: .monthly))
        try context.save()

        let plan = try plan("名称,金额,币种,周期\nNetflix,60,CNY,monthly",
                            local: [SubscriptionDraft(id: id, name: "Netflix", priceMinorUnits: 4500,
                                                      currencyCode: "CNY", cycle: .monthly)])
        XCTAssertEqual(plan.items[0].decision, .skip)
        let counts = try SubscriptionRepository(context: context).importRows(plan.writes)
        XCTAssertEqual(counts, SubscriptionRepository.RestoreCounts())
        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<Subscription>()).first)
        XCTAssertEqual(stored.priceMinorUnits, 4500, "没确认就不该动过一个数字")
    }

    /// 一条都不选时不该广播「数据变了」：提醒队列、小组件和同步都挂在这一拍上。
    /// 真写一条则正好广播一次，不多不少。
    @MainActor
    func testEmptyImportDoesNotBroadcastADataChange() throws {
        let context = try freshContext()
        let repository = SubscriptionRepository(context: context)
        var notifications = 0
        let token = NotificationCenter.default.addObserver(
            forName: .sauryDataChanged, object: nil, queue: nil
        ) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        XCTAssertNoThrow(try repository.importRows([]))
        XCTAssertEqual(notifications, 0)

        let write = SubscriptionRepository.ImportWrite(
            draft: SubscriptionDraft(name: "Netflix", priceMinorUnits: 4500,
                                    currencyCode: "CNY", cycle: .monthly),
            events: [])
        XCTAssertNoThrow(try repository.importRows([write]))
        XCTAssertEqual(notifications, 1, "一次导入只广播一遍")
    }

    /// 更新走的是本机那一条：不多出一行，也不冲掉文件没写的字段，创建时间照旧。
    @MainActor
    func testImportRowsUpdatesTheExistingRowInPlace() throws {
        let context = try freshContext()
        let createdAt = Date(timeIntervalSince1970: 1_400_000_000)
        let id = UUID()
        let stored = Subscription(id: id, name: "iCloud", priceMinorUnits: 6000,
                                  currencyCode: "CNY", cycle: .monthly)
        stored.notes = "本机备注"
        stored.reminderDays = 5
        stored.createdAt = createdAt
        context.insert(stored)
        try context.save()

        let table = try parse("名称,金额\niCloud,68")
        let plan = ImportConflictResolver.resolve(table: table, local: [BackupSubscription(stored).draft])
        let item = try XCTUnwrap(plan.items.first)
        XCTAssertEqual(item.matchKind, .sameName)
        let counts = try SubscriptionRepository(context: context)
            .importRows(plan.setting(rowID: item.id, decision: .update).writes)
        XCTAssertEqual(counts.subscriptionsUpdated, 1)
        XCTAssertEqual(counts.subscriptionsInserted, 0)

        let all = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertEqual(all.count, 1, "更新不该多出第二行")
        let result = try XCTUnwrap(all.first)
        XCTAssertEqual(result.priceMinorUnits, 6800)
        XCTAssertEqual(result.notes, "本机备注")
        XCTAssertEqual(result.reminderDays, 5)
        XCTAssertEqual(result.createdAt, createdAt, "导入不该把三年前的订阅变成今天建的")
    }

    /// 指向不存在订阅的事件不进库；同批正常的那些照写。
    @MainActor
    func testEventsAnchoredToTheRowActuallyWritten() throws {
        let context = try freshContext()
        let id = UUID()
        let eventID = UUID()
        let repository = SubscriptionRepository(context: context)
        // 事件草稿上写的归属和最终落库的订阅 id 不一致时，按订阅那一份认领。
        let counts = try repository.importRows([SubscriptionRepository.ImportWrite(
            draft: SubscriptionDraft(id: id, name: "iCloud", priceMinorUnits: 6800,
                                     currencyCode: "CNY", cycle: .monthly),
            createdAt: Date(timeIntervalSince1970: 1_500_000_000),
            events: [SubscriptionEventDraft(id: eventID, subscriptionID: UUID(), type: .charged,
                                            amountMinorUnits: 6800, currencyCode: "CNY",
                                            note: "去年那笔")]
        )])
        XCTAssertEqual(counts.subscriptionsInserted, 1)
        XCTAssertEqual(counts.eventsInserted, 1)
        let event = try XCTUnwrap(context.fetch(FetchDescriptor<SubscriptionEvent>()).first)
        XCTAssertEqual(event.subscriptionID, id, "事件要认得回真正落库的那条订阅")
        XCTAssertEqual(event.note, "去年那笔")
        let subscription = try XCTUnwrap(context.fetch(FetchDescriptor<Subscription>()).first)
        XCTAssertEqual(subscription.createdAt.timeIntervalSince1970, 1_500_000_000, accuracy: 1)
    }

    /// 名字空的写入是坏批：整批不写、直接抛出，不能留下一半再报「导入完成」。
    @MainActor
    func testNamelessWriteAbortsTheWholeBatch() throws {
        let context = try freshContext()
        let repository = SubscriptionRepository(context: context)
        let good = SubscriptionDraft(id: UUID(), name: "Netflix", priceMinorUnits: 4500,
                                     currencyCode: "CNY", cycle: .monthly)
        let bad = SubscriptionDraft(name: "   ")
        XCTAssertThrowsError(try repository.importRows([
            SubscriptionRepository.ImportWrite(draft: good, events: []),
            SubscriptionRepository.ImportWrite(draft: bad, events: []),
        ]))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Subscription>()), 0)
    }

    // MARK: - 没有预览界面时的快捷导入

    /// 快捷导入只写「本机肯定没有」的那些行：疑似重复一律原样报回去，一个数字都不改。
    @MainActor
    func testHeadlessImportNeverOverwritesExistingData() throws {
        let context = try freshContext()
        let stored = Subscription(name: "Netflix", priceMinorUnits: 4500,
                                  currencyCode: "CNY", cycle: .monthly)
        stored.notes = "本机备注"
        context.insert(stored)
        try context.save()

        let outcome = try SubscriptionImportExport.importCSV("""
        名称,金额,币种,周期
        Netflix,60,CNY,monthly
        百度网盘,68,CNY,每月
        """, into: context)
        XCTAssertEqual(outcome.imported, 1, "只有本机没有的那条能自动导")
        XCTAssertEqual(outcome.skipped.count, 1)
        XCTAssertTrue(outcome.skipped[0].contains("Netflix"), outcome.skipped[0])
        XCTAssertTrue(outcome.skipped[0].contains("未经确认"), outcome.skipped[0])

        let all = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertEqual(all.count, 2)
        let netflix = try XCTUnwrap(all.first { $0.name == "Netflix" })
        XCTAssertEqual(netflix.priceMinorUnits, 4500, "未经确认的数字不能覆盖")
        XCTAssertEqual(netflix.notes, "本机备注")
    }

    /// 读不出来的行不写库，原因按行列清楚：只报「成功几条」就是把失败藏了。
    @MainActor
    func testHeadlessImportReportsUnreadableRowsPerRow() throws {
        let context = try freshContext()
        let outcome = try SubscriptionImportExport.importCSV("""
        名称,金额,币种,周期
        坏金额,abc,CNY,monthly
        好行,45,CNY,monthly
        """, into: context)
        XCTAssertEqual(outcome.imported, 1)
        XCTAssertEqual(outcome.skipped.count, 1)
        XCTAssertTrue(outcome.skipped[0].contains("坏金额"), outcome.skipped[0])
        XCTAssertTrue(outcome.skipped[0].contains("abc"), outcome.skipped[0])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Subscription>()), 1)
    }

    // MARK: - 预览页的状态机

    /// 改完一个字段要重新比对：修好的那行回到它该有的建议，用户点过的那些一条都不动。
    /// 预览页每敲一个字都走这条路，两件事同时成立才敢把纠错做成实时的。
    func testReresolveAdoptsDefaultForFixedRowAndKeepsExplicitChoices() throws {
        let locals = [local("Netflix")]
        let table = try parse("""
        名称,金额,币种,周期
        Netflix,60,CNY,monthly
        Spotify,10,CNY,monthly
        坏金额,x,CNY,monthly
        """)
        let base = ImportConflictResolver.resolve(table: table, local: locals)
        XCTAssertEqual(base.items.map(\.suggested), [.skip, .create, .skip],
                       "同名的默认跳过、本机没有的默认新增、读不出来的被迫跳过")
        let spotifyID = try XCTUnwrap(base.items.first { $0.row.displayName == "Spotify" }).id
        let blockedID = try XCTUnwrap(base.items.first { $0.isBlocked }).id
        let touched = base.setting(rowID: spotifyID, decision: .skip)

        let fixed = table.editing(rowID: blockedID, field: .amount, to: "30")
        let plan = ImportConflictResolver.reresolve(table: fixed, local: locals, previous: touched)
        let byName = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.row.displayName, $0) })

        XCTAssertEqual(byName["Netflix"]?.decision, .skip, "没点过的行跟着新的默认走")
        XCTAssertEqual(byName["Spotify"]?.decision, .skip, "这是用户自己点掉的，重算不该把它勾回来")
        XCTAssertEqual(byName["坏金额"]?.decision, .create,
                       "之前那个「跳过」是被坏行逼出来的，不算用户的选择：修好了就该按新建议")
        XCTAssertEqual(plan.writes.count, 1)
        XCTAssertEqual(plan.writes.first?.draft.priceMinorUnits, 3000, "写入要带上改后的数")
    }

    /// 反过来：把字段改成读不出来的，之前点过的「更新本机这条」必须失效。
    /// 留着它等于让一个坏行还挂在写入清单里。
    func testReresolveDropsAChoiceTheRowNoLongerAllows() throws {
        let locals = [local("Netflix")]
        let table = try parse("名称,金额,币种,周期\nNetflix,60,CNY,monthly")
        let rowID = try XCTUnwrap(table.rows.first?.id)
        let chosen = ImportConflictResolver.resolve(table: table, local: locals)
            .setting(rowID: rowID, decision: .update)
        XCTAssertEqual(chosen.items[0].decision, .update)
        XCTAssertEqual(chosen.writes.count, 1)

        let broken = table.editing(rowID: rowID, field: .amount, to: "abc")
        let plan = ImportConflictResolver.reresolve(table: broken, local: locals, previous: chosen)
        XCTAssertTrue(plan.items[0].isBlocked)
        XCTAssertEqual(plan.items[0].decision, .skip, "行都读不出来了，那次「更新」不该还留在计划里")
        XCTAssertTrue(plan.writes.isEmpty)
    }

    /// 分栏要把每一行放且只放一格，而且「要先纠错」排最前：几百行时人要找的就是它。
    func testPreviewSectionsPutEachRowInExactlyOneBucket() throws {
        let plan = try plan("""
        名称,金额,币种,周期
        Netflix,60,CNY,monthly
        Spotify,10,CNY,monthly
        坏金额,x,CNY,monthly
        """, local: [local("Netflix")])
        let sections = plan.previewSections
        XCTAssertEqual(sections.map(\.kind), [.needsFix, .mayDuplicate, .fresh])
        XCTAssertEqual(sections.flatMap { $0.items }.count, plan.items.count, "没有哪一行被两栏同时收走，也没有哪一行没人收")
        XCTAssertEqual(Set(sections.flatMap { $0.items }.map(\.id)), Set(plan.items.map(\.id)))
        XCTAssertEqual(sections[0].items.map { $0.row.displayName }, ["坏金额"])
        XCTAssertEqual(sections[1].items.map { $0.row.displayName }, ["Netflix"])
        XCTAssertEqual(sections[2].items.map { $0.row.displayName }, ["Spotify"])
        XCTAssertEqual(plan.duplicateItemCount, 1)
        XCTAssertEqual(plan.importableItemCount, 2)
    }

    /// 「全选」只管修得好的那些行：坏行勾上也导不进去，不如让它保持跳过并说清为什么。
    func testSelectAllCoversOnlyFixableRows() throws {
        let plan = try plan("""
        名称,金额,币种,周期
        Netflix,60,CNY,monthly
        Spotify,10,CNY,monthly
        坏金额,x,CNY,monthly
        """, local: [local("Netflix")])
        XCTAssertFalse(plan.isEverythingSelected)
        XCTAssertEqual(plan.projection.creates, 1, "默认只有本机没有的那条被勾上")

        let all = plan.settingAll(true)
        XCTAssertEqual(all.items.filter { $0.isBlocked == false }.map(\.decision), [.update, .create])
        XCTAssertEqual(all.items.first { $0.isBlocked }?.decision, .skip, "全选不该把坏行勾上")
        XCTAssertTrue(all.isEverythingSelected)
        XCTAssertTrue(all.settingAll(false).projection.isNothingSelected)
    }

    /// 确认前要不要再问一遍，只看「这次更新会不会真的改掉本机已有的数」。
    /// 编号相同的那条本来就是同一个东西，问它等于把用户训练成看到弹窗就点确认。
    func testOverwriteWarningOnlyForRealValueChanges() throws {
        let locals = [local("Netflix")]
        XCTAssertTrue(ImportConflictResolver.willChangeLocalValues(
            try forcedUpdate("Netflix,60,CNY,monthly", local: locals)),
            "只按名字对上、数字又不一样：这才是需要问一遍的那种覆盖")

        let identical = try forcedUpdate("Netflix,45,CNY,monthly", local: locals)
        XCTAssertEqual(identical.matchKind, .sameContent)
        XCTAssertFalse(ImportConflictResolver.willChangeLocalValues(identical),
                       "覆盖一个和本机一模一样的值，不该冒充「会改数据」来吓人")

        let fresh = try plan("名称,金额,币种,周期\nSpotify,10,CNY,monthly", local: locals)
        XCTAssertFalse(ImportConflictResolver.willChangeLocalValues(try XCTUnwrap(fresh.items.first)), "新增不动本机")

        let id = UUID()
        let stable = ImportConflictResolver.resolve(
            table: try parseJSON("""
            [{"id":"\(id.uuidString)","name":"iCloud","price":"68","currency":"CNY","cycle":"monthly"}]
            """),
            local: [local("iCloud", id: id, price: 6000)])
        XCTAssertEqual(stable.items[0].decision, .update)
        XCTAssertFalse(ImportConflictResolver.willChangeLocalValues(stable.items[0]),
                       "编号相同就是同一条，更新它本来就是导入的意思")
    }

    /// 取「用户主动选中『更新本机这条』」之后的那一行。
    /// 表只解析一次：行 id 是每次解析现发的，解析两遍拿到的 id 对不上。
    private func forcedUpdate(_ line: String, local: [SubscriptionDraft]) throws -> ImportConflictResolver.Item {
        let table = try parse("名称,金额,币种,周期\n\(line)")
        let plan = ImportConflictResolver.resolve(table: table, local: local)
            .setting(rowID: try XCTUnwrap(table.rows.first?.id), decision: .update)
        return try XCTUnwrap(plan.items.first)
    }
}
