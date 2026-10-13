import XCTest
import SwiftData
import UIKit
@testable import Saury

/// 备份 V2（任务书 §3.1）：带清单的压缩容器 + 恢复必须支持的八种场景。
///
/// 每条测试都真的走一遍「落盘再读回来」：独立的内存库、独立的临时图标目录、
/// 独立的 UserDefaults 套件，测试之间不共用状态。
final class BackupV2Tests: XCTestCase {
    @MainActor
    private func freshContext() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema(versionedSchema: SaurySchemaV4.self),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @MainActor
    private func makePreferences(_ tag: String = "main") -> SubPreferences {
        SubPreferences(defaults: UserDefaults(suiteName: "SauryBackupTests.\(tag).\(UUID().uuidString)")!)
    }

    private func makeIcons() -> IconImageStore {
        IconImageStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("SauryBackupTests-\(UUID().uuidString)", isDirectory: true))
    }

    /// 一张确定能编码出字节的图，不赌 SF 符号在测试环境里渲染得出渲染不出。
    private func makeImage(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }

    /// 每个字段都填成「一眼能看出对不对」的值：round-trip 后任何一处不一样都是丢数据。
    private func richSubscription(name: String = "Netflix", id: UUID = UUID()) -> Subscription {
        let calendar = BillingMath.calendar
        let subscription = Subscription(
            id: id,
            name: name,
            plan: "标准版 2 人",
            iconSymbolName: "play.tv.fill",
            iconColorHex: "#FF375F",
            colorSpec: CardColorSpec(hexes: ["#FF375F", "#FF9F0A"]),
            priceMinorUnits: 4501,
            currencyCode: "USD",
            cycle: .custom,
            customMonths: 4,
            category: "video",
            state: .manualRenew,
            startDate: calendar.date(from: DateComponents(year: 2024, month: 3, day: 7, hour: 9))!,
            endDate: calendar.date(from: DateComponents(year: 2027, month: 1, day: 1, hour: 0))!,
            reminderDays: 5,
            shareEnabled: true,
            shareHeadcount: 3,
            shareMode: .custom,
            shareMyMinorUnits: 1500,
            paymentMethod: "PayPal",
            notes: "和家庭组合订",
            sortOrder: 7,
            createdAt: calendar.date(from: DateComponents(year: 2024, month: 3, day: 7, hour: 9, minute: 12))!
        )
        subscription.updatedAt = calendar.date(from: DateComponents(year: 2025, month: 8, day: 2, hour: 20))!
        return subscription
    }

    @MainActor
    private func buildFile(from context: ModelContext, preferences: SubPreferences, icons: IconImageStore) throws -> Data {
        try BackupService.build(context: context, preferences: preferences, icons: icons).data
    }

    /// 手工打一个包：「清单说了但内容不对」这类文件走正式打包那条路造不出来。
    private func pack(payload: BackupPayload, icons: [String: Data] = [:]) throws -> Data {
        var blocks = [BackupContainer.Part(name: BackupManifest.documentPartName,
                                          data: try JSONEncoder.backup.encode(payload))]
        for (file, data) in icons.sorted(by: { $0.key < $1.key }) {
            blocks.append(.init(name: BackupManifest.iconPartName(forFile: file), data: data))
        }
        let manifestParts = blocks.map {
            BackupManifest.Part(name: $0.name,
                                sha256: BackupContainer.sha256($0.data),
                                byteLength: $0.data.count,
                                kind: $0.name == BackupManifest.documentPartName ? .document : .icon)
        }
        let manifest = BackupManifest(schemaVersion: BackupPayload.schemaVersion,
                                     createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                     appVersion: "测试",
                                     subscriptionCount: payload.subscriptions.count,
                                     eventCount: payload.events.count,
                                     iconCount: icons.count,
                                     parts: manifestParts)
        return try BackupContainer.write(manifest: try JSONEncoder.backup.encode(manifest), parts: blocks)
    }

    private func minimalPayload(subscription: Subscription? = nil) -> BackupPayload {
        BackupPayload(exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
                     subscriptions: [BackupSubscription(subscription ?? richSubscription())],
                     events: [],
                     categories: DefaultCategories.items,
                     paymentMethods: PaymentCatalog.builtIn,
                     preferences: BackupPreferences(),
                     iconFileNames: [])
    }

    @MainActor
    private func snapshot(_ context: ModelContext) throws -> [String] {
        try context.fetch(FetchDescriptor<Subscription>()).map {
            "\($0.id.uuidString)|\($0.name)|\($0.priceMinorUnits)|\($0.updatedAt.timeIntervalSince1970)"
        }.sorted()
    }

    // MARK: - 容器格式

    @MainActor
    func testBuiltFileIsAManifestedCompressedContainer() throws {
        let context = try freshContext()
        let icons = makeIcons()
        let subscription = richSubscription()
        subscription.iconImageFile = icons.store(makeImage(.systemPink), named: "netflix.png")
        context.insert(subscription)
        context.insert(SubscriptionEvent(subscriptionID: subscription.id, type: .charged,
                                         amountMinorUnits: 4501, currencyCode: "USD"))
        try context.save()

        let built = try BackupService.build(context: context, preferences: makePreferences(), icons: icons)
        XCTAssertEqual(built.data.prefix(BackupContainer.magic.count), BackupContainer.magic)
        XCTAssertEqual(built.manifest.schemaVersion, 2)
        XCTAssertEqual(built.manifest.subscriptionCount, 1)
        XCTAssertEqual(built.manifest.eventCount, 1)
        XCTAssertEqual(built.manifest.iconCount, 1)
        XCTAssertEqual(built.manifest.parts.count, 2, "正文 + 图标，清单里一块都不能少")
        // 压缩不是摆设：清单记的正文原始字节比整个包还大。
        let documentBytes = try XCTUnwrap(built.manifest.parts.first { $0.kind == .document }).byteLength
        XCTAssertGreaterThan(documentBytes, built.data.count)
    }

    @MainActor
    func testRoundTripRestoresEveryBusinessFieldAndTimestamp() throws {
        let source = try freshContext()
        let icons = makeIcons()
        let original = richSubscription()
        let storedFile = try XCTUnwrap(icons.store(makeImage(.systemPink), named: "netflix.png"))
        original.iconImageFile = storedFile
        original.pinnedAt = Date(timeIntervalSince1970: 1_600_000_000)
        source.insert(original)
        let event = SubscriptionEvent(subscriptionID: original.id, type: .priceChanged,
                                      amountMinorUnits: 5000, currencyCode: "USD",
                                      note: "涨了一次", happenedAt: Date(timeIntervalSince1970: 1_650_000_000))
        source.insert(event)
        try source.save()

        let preferences = makePreferences()
        preferences.accentHex = "#5E5CE6"
        preferences.defaultCurrency = "USD"
        preferences.paymentMethods = ["PayPal", "微信支付"]
        preferences.defaultReminderDays = 7
        preferences.notificationsEnabled = true

        let file = try buildFile(from: source, preferences: preferences, icons: icons)

        let target = try freshContext()
        let targetIcons = makeIcons()
        let targetPreferences = makePreferences("target")
        let report = try BackupService.restore(data: file, into: target,
                                              preferences: targetPreferences, icons: targetIcons)
        XCTAssertEqual(report.counts.subscriptionsInserted, 1)
        XCTAssertEqual(report.counts.eventsInserted, 1)
        XCTAssertTrue(report.isClean, report.summaryText)

        let restored = try XCTUnwrap(target.fetch(FetchDescriptor<Subscription>()).first)
        XCTAssertEqual(restored.id, original.id, "稳定 UUID 必须原样带过去")
        XCTAssertEqual(restored.name, original.name)
        XCTAssertEqual(restored.plan, original.plan)
        XCTAssertEqual(restored.iconSymbolName, original.iconSymbolName)
        XCTAssertEqual(restored.iconColorHex, original.iconColorHex)
        XCTAssertEqual(restored.colorSpec, original.colorSpec)
        XCTAssertEqual(restored.priceMinorUnits, 4501)
        XCTAssertEqual(restored.currencyCode, "USD")
        XCTAssertEqual(restored.cycle, .custom)
        XCTAssertEqual(restored.customMonths, 4)
        XCTAssertEqual(restored.categoryRawValue, "video")
        XCTAssertEqual(restored.state, .manualRenew)
        XCTAssertEqual(restored.startDate, original.startDate)
        XCTAssertEqual(restored.endDate, original.endDate)
        XCTAssertEqual(restored.reminderDays, 5)
        XCTAssertEqual(restored.shareEnabled, true)
        XCTAssertEqual(restored.shareHeadcount, 3)
        XCTAssertEqual(restored.shareMode, .custom)
        XCTAssertEqual(restored.shareMyMinorUnits, 1500)
        XCTAssertEqual(restored.paymentMethod, "PayPal")
        XCTAssertEqual(restored.notes, "和家庭组合订")
        XCTAssertEqual(restored.sortOrder, 7)
        XCTAssertEqual(restored.pinnedAt, original.pinnedAt)
        XCTAssertEqual(restored.archivedAt, nil)
        XCTAssertEqual(restored.deletedAt, nil)
        XCTAssertEqual(restored.createdAt, original.createdAt, "三年前加的订阅不该被恢复成刚刚创建")
        XCTAssertEqual(restored.updatedAt, original.updatedAt, "恢复不是修改，不该把更新时间推到现在")

        let restoredEvent = try XCTUnwrap(target.fetch(FetchDescriptor<SubscriptionEvent>()).first)
        XCTAssertEqual(restoredEvent.id, event.id)
        XCTAssertEqual(restoredEvent.subscriptionID, original.id)
        XCTAssertEqual(restoredEvent.type, .priceChanged)
        XCTAssertEqual(restoredEvent.amountMinorUnits, 5000)
        XCTAssertEqual(restoredEvent.note, "涨了一次")
        // 恢复不重放「调价改现价」那个副作用：现价就是备份里的最新值。
        XCTAssertEqual(restored.priceMinorUnits, 4501)

        XCTAssertEqual(targetPreferences.accentHex, "#5E5CE6")
        XCTAssertEqual(targetPreferences.defaultCurrency, "USD")
        // 支付方式是并集恢复：本机已有的选项不许被一份备份顶掉（不删用户数据）。
        XCTAssertTrue(Set(["PayPal", "微信支付"]).isSubset(of: Set(targetPreferences.paymentMethods)),
                      targetPreferences.paymentMethods.joined(separator: "、"))
        XCTAssertEqual(targetPreferences.paymentMethods.count,
                       Set(targetPreferences.paymentMethods).count, "并集不许并进重复项")
        XCTAssertEqual(targetPreferences.defaultReminderDays, 7)
        XCTAssertEqual(targetPreferences.notificationsEnabled, true)
        XCTAssertEqual(try XCTUnwrap(targetIcons.data(for: restored.iconImageFile)),
                       try XCTUnwrap(icons.data(for: storedFile)),
                       "图标要按原始字节落在新机器上")
    }

    func testReadingANonBackupFileReportsIt() throws {
        let text = Data("名称,金额\nNetflix,45".utf8)
        XCTAssertThrowsError(try BackupContainer.readManifest(text)) { error in
            XCTAssertEqual(error as? BackupContainer.Failure, .notABackupFile)
        }
    }

    func testUnsupportedContainerVersionIsNamed() throws {
        var tampered = try pack(payload: minimalPayload())
        tampered[BackupContainer.magic.count] = 9
        XCTAssertThrowsError(try BackupContainer.read(tampered)) { error in
            XCTAssertEqual(error as? BackupContainer.Failure, .unsupportedContainerVersion(9))
        }
    }

    @MainActor
    func testCorruptedIconBlockNamesThePart() throws {
        let icons = makeIcons()
        let file = try XCTUnwrap(icons.store(makeImage(.systemBlue), named: "blue.png"))
        let bytes = try XCTUnwrap(icons.data(for: file))
        let item = richSubscription()
        item.iconImageFile = file
        var payload = minimalPayload(subscription: item)
        payload.iconFileNames = [file]

        var tampered = try pack(payload: payload, icons: [file: bytes])
        // 从尾巴往前找一个不属于清单的字节：动包尾就撞上图标那块。
        let target = tampered.count - 6
        tampered[target] ^= 0xFF
        XCTAssertThrowsError(try BackupContainer.read(tampered)) { error in
            guard case .partCorrupted(let name)? = error as? BackupContainer.Failure else {
                return XCTFail("要说清楚坏在哪一块，实际报的是 \(error)")
            }
            XCTAssertEqual(name, BackupManifest.iconPartName(forFile: file))
        }
    }

    func testTruncatedFileFailsToRead() throws {
        let packed = try pack(payload: minimalPayload())
        XCTAssertThrowsError(try BackupContainer.read(packed.dropLast(6))) { error in
            XCTAssertTrue(error is BackupContainer.Failure, "实际抛出 \(error)")
        }
    }

    @MainActor
    func testManifestIsReadableWithoutTouchingIconBlocks() throws {
        // 预览页先把「包里有几条形、几张图」摊出来，不该为此把几百 KB 图标解进内存。
        let icons = makeIcons()
        let file = try XCTUnwrap(icons.store(makeImage(.systemGreen), named: "green.png"))
        let item = richSubscription()
        item.iconImageFile = file
        var payload = minimalPayload(subscription: item)
        payload.iconFileNames = [file]
        let packed = try pack(payload: payload, icons: [file: try XCTUnwrap(icons.data(for: file))])

        let manifest = try BackupContainer.readManifest(packed)
        XCTAssertEqual(manifest.subscriptionCount, 1)
        XCTAssertEqual(manifest.iconCount, 1)
        XCTAssertEqual(manifest.iconParts.count, 1)
        XCTAssertEqual(manifest.documentPart?.byteLength,
                       (try JSONEncoder.backup.encode(payload)).count)
    }

    // MARK: - 恢复的八种场景

    @MainActor
    func testRestoreIntoAFreshInstall() throws {
        let source = try freshContext()
        let icons = makeIcons()
        let subscription = richSubscription()
        subscription.iconImageFile = icons.store(makeImage(.systemRed), named: "red.png")
        source.insert(subscription)
        source.insert(SubscriptionEvent(subscriptionID: subscription.id, type: .charged,
                                       amountMinorUnits: 4501, currencyCode: "USD"))
        try source.save()
        let file = try buildFile(from: source, preferences: makePreferences(), icons: icons)

        let target = try freshContext()
        let report = try BackupService.restore(data: file, into: target,
                                             preferences: makePreferences(), icons: makeIcons())
        XCTAssertEqual(report.counts.subscriptionsInserted, 1)
        XCTAssertEqual(report.counts.eventsInserted, 1)
        XCTAssertEqual(report.iconsWritten, 1)
        XCTAssertTrue(report.isClean, report.summaryText)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<Subscription>()), 1)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<SubscriptionEvent>()), 1)
    }

    @MainActor
    func testLegacyJSONBackupRestoresSubscriptionsAndEvents() throws {
        let source = try freshContext()
        let repository = SubscriptionRepository(context: source)
        let subscription = try repository.apply(SubscriptionDraft(name: "iCloud+", priceMinorUnits: 600,
                                                                 currencyCode: "CNY", cycle: .monthly))
        try repository.record(SubscriptionEventDraft(subscriptionID: subscription.id, type: .charged,
                                                    amountMinorUnits: 600, currencyCode: "CNY"))
        let modern = SubscriptionImportExport.exportJSON(subscriptions: [subscription],
                                                       events: repository.events(subscriptionID: subscription.id))

        // 真·老文件：当年没有 id 这个字段，把编号全部抹掉再恢复。
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: modern) as? [String: Any])
        var subscriptions = try XCTUnwrap(object["subscriptions"] as? [[String: Any]])
        subscriptions[0].removeValue(forKey: "id")
        var events = try XCTUnwrap(object["events"] as? [[String: Any]])
        events[0].removeValue(forKey: "id")
        events[0].removeValue(forKey: "subscriptionID")
        object["subscriptions"] = subscriptions
        object["events"] = events
        let legacyFile = try JSONSerialization.data(withJSONObject: object)

        let target = try freshContext()
        let report = try BackupService.restore(data: legacyFile, into: target,
                                             preferences: makePreferences(), icons: makeIcons())
        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.counts.subscriptionsInserted, 1)
        XCTAssertEqual(report.counts.eventsInserted, 1, "老文件只靠名字认领，历史也不能丢")
        XCTAssertTrue(report.summaryText.contains("旧版 JSON"), report.summaryText)
        let restoredEvent = try XCTUnwrap(target.fetch(FetchDescriptor<SubscriptionEvent>()).first)
        XCTAssertEqual(restoredEvent.subscriptionID,
                       try XCTUnwrap(target.fetch(FetchDescriptor<Subscription>()).first).id)

        // 同一份老文件再恢复一次：没有稳定编号就按内容判重，一条都不许多出来。
        let again = try BackupService.restore(data: legacyFile, into: target,
                                            preferences: makePreferences(), icons: makeIcons())
        XCTAssertEqual(again.counts.subscriptionsInserted, 0)
        XCTAssertEqual(again.duplicatesSkippedByContent, 1)
        XCTAssertEqual(again.eventsSkippedAsDuplicates, 1)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<Subscription>()), 1, "重复恢复旧版备份不该多出第二条")
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<SubscriptionEvent>()), 1, "历史也不该变成双份")
    }

    @MainActor
    func testRestoringTheSameBackupTwiceIsIdempotent() throws {
        let source = try freshContext()
        for name in ["Netflix", "iCloud", "Spotify"] { source.insert(richSubscription(name: name)) }
        try source.save()
        let file = try buildFile(from: source, preferences: makePreferences(), icons: makeIcons())

        let target = try freshContext()
        let preferences = makePreferences()
        try BackupService.restore(data: file, into: target, preferences: preferences, icons: makeIcons())
        let afterFirst = try snapshot(target)

        let second = try BackupService.restore(data: file, into: target, preferences: preferences, icons: makeIcons())
        XCTAssertEqual(second.counts.subscriptionsInserted, 0)
        XCTAssertEqual(second.counts.subscriptionsUpdated, 3)
        XCTAssertTrue(second.isClean, second.summaryText)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<Subscription>()), 3)
        XCTAssertEqual(try snapshot(target), afterFirst, "再恢复一遍，库里一个字都不该变")
    }

    /// 本机已经有别的订阅时恢复：包里没有的一条都不动，这就是「部分数据已存在的合并恢复」。
    @MainActor
    func testMergeKeepsLocalOnlyRows() throws {
        let source = try freshContext()
        source.insert(richSubscription(name: "Netflix"))
        try source.save()
        let file = try buildFile(from: source, preferences: makePreferences(), icons: makeIcons())

        let target = try freshContext()
        target.insert(richSubscription(name: "本机自己的网盘"))
        try target.save()

        let report = try BackupService.restore(data: file, into: target,
                                             preferences: makePreferences(), icons: makeIcons())
        XCTAssertEqual(report.counts.subscriptionsInserted, 1)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<Subscription>()), 2, "本机独有的那条必须还在")
        XCTAssertTrue(report.isClean, report.summaryText)
    }

    @MainActor
    func testRestoreModesDisagreeOnTheSameRow() throws {
        let source = try freshContext()
        let shared = richSubscription(name: "Netflix", id: UUID())
        source.insert(shared)
        try source.save()
        let file = try buildFile(from: source, preferences: makePreferences(), icons: makeIcons())

        // 本机同一条（同一个 UUID）已经改成别的样子了。
        let target = try freshContext()
        let local = richSubscription(name: "本机改过的 Netflix", id: shared.id)
        local.priceMinorUnits = 9999
        target.insert(local)
        try target.save()

        let keepLocal = try BackupService.restore(data: file, into: target,
                                                preferences: makePreferences(),
                                                mode: .keepExisting, icons: makeIcons())
        XCTAssertEqual(keepLocal.counts.subscriptionsSkipped, 1)
        let untouched = try XCTUnwrap(target.fetch(FetchDescriptor<Subscription>()).first)
        XCTAssertEqual(untouched.priceMinorUnits, 9999, "本机优先就不许动本机那条")
        XCTAssertEqual(untouched.name, "本机改过的 Netflix")
        XCTAssertTrue(keepLocal.isClean, keepLocal.summaryText)

        let overwrite = try BackupService.restore(data: file, into: target,
                                                preferences: makePreferences(),
                                                mode: .overwrite, icons: makeIcons())
        XCTAssertEqual(overwrite.counts.subscriptionsUpdated, 1)
        let replaced = try XCTUnwrap(target.fetch(FetchDescriptor<Subscription>()).first)
        XCTAssertEqual(replaced.priceMinorUnits, 4501)
        XCTAssertEqual(replaced.name, "Netflix", "备份优先就整个按备份来，名字也算")
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<Subscription>()), 1)
    }

    @MainActor
    func testMissingIconIsReportedNotHidden() throws {
        let source = try freshContext()
        let subscription = richSubscription()
        subscription.iconImageFile = "已经不存在的图.png"
        source.insert(subscription)
        try source.save()

        let built = try BackupService.build(context: source, preferences: makePreferences(), icons: makeIcons())
        XCTAssertEqual(built.missingIconFileNames, ["已经不存在的图.png"])
        XCTAssertEqual(built.manifest.iconCount, 0)
        XCTAssertTrue(built.summaryText.contains("没进包"), built.summaryText)

        let target = try freshContext()
        let report = try BackupService.restore(data: built.data, into: target,
                                             preferences: makePreferences(), icons: makeIcons())
        XCTAssertEqual(report.counts.subscriptionsInserted, 1, "图标没了不能把订阅一起不恢复")
        XCTAssertEqual(report.consistency.missingIconFiles, ["已经不存在的图.png"])
        XCTAssertFalse(report.isClean)
        XCTAssertTrue(report.summaryText.contains("本机也没有"), report.summaryText)
    }

    @MainActor
    func testCorruptedFileWritesNothing() throws {
        let source = try freshContext()
        for name in ["Netflix", "iCloud"] { source.insert(richSubscription(name: name)) }
        try source.save()
        var tampered = try buildFile(from: source, preferences: makePreferences(), icons: makeIcons())
        tampered[tampered.count / 2] ^= 0xFF

        let target = try freshContext()
        XCTAssertThrowsError(try BackupService.restore(data: tampered, into: target,
                                                      preferences: makePreferences(), icons: makeIcons()))
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<Subscription>()), 0, "坏包一条都不许落库")
    }

    /// 恢复中途失败：一批里有一条不合格，整批不写，绝不留「半套备份 + 恢复成功」。
    @MainActor
    func testMidBatchFailureLeavesNoPartialRestore() throws {
        let context = try freshContext()
        let repository = SubscriptionRepository(context: context)
        let good = BackupSubscription(richSubscription(name: "好的那条"))
        let broken = BackupSubscription(richSubscription(name: "  "))

        XCTAssertThrowsError(try repository.restore(rows: [(good.draft, good.status), (broken.draft, broken.status)],
                                                   events: [],
                                                   mode: .overwrite))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Subscription>()), 0,
                       "整批里有一条不合格，那条好的也不许单独留在库里")
    }

    /// 恢复完成后的事件关联校验：指向不存在订阅的事件不进库，并且报得出来。
    @MainActor
    func testOrphanEventsAreDetectedAndSkipped() throws {
        let subscription = richSubscription(name: "Netflix")
        var payload = minimalPayload(subscription: subscription)
        let realEvent = SubscriptionEvent(subscriptionID: subscription.id, type: .charged,
                                         amountMinorUnits: 4501, currencyCode: "USD")
        let orphan = SubscriptionEvent(subscriptionID: UUID(), type: .charged,
                                      amountMinorUnits: 9000, currencyCode: "USD", note: "指向不存在的订阅")
        payload.events = [BackupEvent(realEvent), BackupEvent(orphan)]

        let target = try freshContext()
        let report = try BackupService.restore(data: try pack(payload: payload), into: target,
                                             preferences: makePreferences(), icons: makeIcons())
        XCTAssertEqual(report.counts.subscriptionsInserted, 1)
        XCTAssertEqual(report.counts.eventsInserted, 1)
        XCTAssertEqual(report.counts.eventsSkipped, 1)
        XCTAssertEqual(report.issues.count, 1)
        XCTAssertTrue(report.issues[0].text.contains("不在这份备份里"), report.issues[0].text)
        XCTAssertTrue(report.summaryText.contains("找不到所属订阅"), report.summaryText)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<SubscriptionEvent>()), 1, "孤儿事件不能进库")
        XCTAssertTrue(report.consistency.problems.isEmpty, report.summaryText)
    }

    @MainActor
    func testUnnamedRowIsSkippedWhileGoodRowsLand() throws {
        let good = richSubscription(name: "Netflix")
        let broken = richSubscription(name: "   ")
        var payload = minimalPayload(subscription: good)
        payload.subscriptions.append(BackupSubscription(broken))

        let target = try freshContext()
        let report = try BackupService.restore(data: try pack(payload: payload), into: target,
                                             preferences: makePreferences(), icons: makeIcons())
        XCTAssertEqual(report.counts.subscriptionsInserted, 1)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<Subscription>()), 1)
        XCTAssertEqual(report.issues.count, 1)
        XCTAssertTrue(report.issues[0].text.contains("没有名字"), report.issues[0].text)
    }

    @MainActor
    func testCategoriesAndPaymentMethodsMerge() throws {
        let sourcePreferences = makePreferences("source")
        sourcePreferences.categories = DefaultCategories.items + [
            SubscriptionCategory(id: "hosting", name: "服务器", colorHex: "#0FBFBF", symbol: "server.rack")
        ]
        sourcePreferences.paymentMethods = PaymentCatalog.builtIn + ["Stripe"]
        let source = try freshContext()
        let file = try buildFile(from: source, preferences: sourcePreferences, icons: makeIcons())

        let localPreferences = makePreferences("local")
        localPreferences.categories = DefaultCategories.items + [
            SubscriptionCategory(id: "transit", name: "交通", colorHex: "#64D2FF", symbol: "bus.fill")
        ]
        localPreferences.paymentMethods = ["支付宝"]
        let target = try freshContext()
        try BackupService.restore(data: file, into: target, preferences: localPreferences, icons: makeIcons())

        XCTAssertTrue(localPreferences.categories.contains { $0.id == "hosting" }, "备份里的自定义分类要进来")
        XCTAssertTrue(localPreferences.categories.contains { $0.id == "transit" }, "本机自定义的不能被顶掉")
        XCTAssertTrue(localPreferences.paymentMethods.contains("Stripe"))
        XCTAssertTrue(localPreferences.paymentMethods.contains("支付宝"))
    }

    /// 备份里没有的偏好键保持本机现状：老文件不该把用户挑过的主题色抹回默认。
    @MainActor
    func testPreferencesMissingFromBackupLeaveLocalValuesAlone() throws {
        let local = makePreferences("local")
        local.accentHex = "#FF9F0A"
        local.reminderHour = 21
        var payload = minimalPayload()
        payload.preferences = BackupPreferences(defaultCurrency: "JPY")

        let target = try freshContext()
        try BackupService.restore(data: try pack(payload: payload), into: target,
                                 preferences: local, icons: makeIcons())
        XCTAssertEqual(local.defaultCurrency, "JPY", "带了的那条要生效")
        XCTAssertEqual(local.accentHex, "#FF9F0A", "没带的不能被抹平")
        XCTAssertEqual(local.reminderHour, 21)
    }

    /// 全空的备份多半是拿错了文件：直接拒，别恢复完让用户对着一个空列表发懵。
    @MainActor
    func testEmptyBackupIsRefusedWithoutTouchingTheStore() throws {
        let context = try freshContext()
        var payload = minimalPayload()
        payload.subscriptions = []
        payload.categories = []
        payload.paymentMethods = []
        XCTAssertThrowsError(try BackupService.restore(data: try pack(payload: payload), into: context,
                                                      preferences: makePreferences(), icons: makeIcons())) { error in
            XCTAssertEqual(error as? BackupService.Failure, .emptyBackup)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Subscription>()), 0)
    }

    /// 只带分类和设置的备份是合法的（换机时先把偏好搬过去），不能按「空备份」拒掉。
    @MainActor
    func testSettingsOnlyBackupIsRestorable() throws {
        var payload = minimalPayload()
        payload.subscriptions = []
        payload.categories = [SubscriptionCategory(id: "hosting", name: "服务器", colorHex: "#0FBFBF", symbol: "server.rack")]
        let local = makePreferences("settings-only")
        local.defaultCurrency = "CNY"

        let context = try freshContext()
        let report = try BackupService.restore(data: try pack(payload: payload), into: context,
                                              preferences: local, icons: makeIcons())
        XCTAssertEqual(report.counts.subscriptionsInserted, 0)
        XCTAssertTrue(report.isClean, report.summaryText)
        XCTAssertTrue(local.categories.contains { $0.id == "hosting" })
        XCTAssertEqual(local.defaultCurrency, "CNY", "备份里没带币种就该保持本机现状")
    }

    // MARK: - 图标落盘的边界

    func testIconRestoreRejectsPathTraversalNames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SauryIconTests-\(UUID().uuidString)", isDirectory: true)
        let icons = IconImageStore(root: root)
        let bytes = makeImage(.systemPurple).pngData()!
        XCTAssertFalse(icons.restore(bytes, named: "../evil.png"))
        XCTAssertFalse(icons.restore(bytes, named: "子目录/x.png"))
        XCTAssertFalse(icons.restore(bytes, named: ""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("../evil.png").standardized.path))
        XCTAssertTrue(icons.restore(bytes, named: "ok.png"))
        XCTAssertEqual(icons.data(for: "ok.png"), bytes, "恢复按原始字节落盘，不重新编码")
    }

    @MainActor
    func testArchivedAndTrashedSubscriptionsAreBackedUpToo() throws {
        let source = try freshContext()
        let repository = SubscriptionRepository(context: source)
        let active = try repository.apply(SubscriptionDraft(name: "在用"))
        let archived = try repository.apply(SubscriptionDraft(name: "已归档"))
        try repository.archive(archived)
        let trashed = try repository.apply(SubscriptionDraft(name: "在回收站"))
        _ = try repository.moveToTrash(trashed)

        let file = try buildFile(from: source, preferences: makePreferences(), icons: makeIcons())
        let target = try freshContext()
        let report = try BackupService.restore(data: file, into: target,
                                             preferences: makePreferences(), icons: makeIcons())
        XCTAssertEqual(report.counts.subscriptionsInserted, 3, "归档和回收站里的也是用户数据")

        let restored = try target.fetch(FetchDescriptor<Subscription>())
        XCTAssertEqual(restored.first { $0.name == "在用" }?.archivedAt, nil)
        XCTAssertNotNil(restored.first { $0.name == "已归档" }?.archivedAt)
        XCTAssertNotNil(restored.first { $0.name == "在回收站" }?.deletedAt)
    }
}
