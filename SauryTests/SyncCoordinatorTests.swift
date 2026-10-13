import XCTest
import SwiftData
@testable import Saury

/// 任务书 §4.2 对同步入口的四条要求，逐条考：
/// 1. 协调器必须真的拥有数据访问路径（它自己拿着容器，每次同步自己开上下文）；
/// 2. 「查询了云端就记录同步成功」这种假成功要能被测出来 —— `verifying` 那一格；
/// 3. 六个触发源共用一个入口，没开自动同步时只有手点那一下会真的动；
/// 4. 页面要能报出当前阶段、最近成功时间、明确的错误。
///
/// CloudKit 本身在这个环境里一次都跑不起来（签名没给 iCloud 能力），
/// 所以这里用的是同一条代码路径 + 一个内存版「云端」。
@MainActor
final class SyncCoordinatorTests: XCTestCase {
    private var devices: [TestDevice] = []

    override func tearDownWithError() throws {
        devices.forEach { $0.cleanUp() }
        devices = []
    }

    private func makeDevice(store: FakeCloudStore?) throws -> TestDevice {
        let device = try TestDevice(store: store)
        devices.append(device)
        return device
    }

    /// 页面上那个「最近成功时间」的凭据：只有走完一遍才算。
    private func lastSyncTime(_ device: TestDevice) -> Date? {
        device.defaults.object(forKey: SyncCoordinator.lastSyncKey) as? Date
    }

    // MARK: - §4.1 能力与诚实状态

    /// 没有 iCloud 能力：一步云端都不能碰，「上次同步」一个字节都不写。
    func testSyncWithoutCapabilityTouchesNothingAndWritesNoSuccessTime() async throws {
        let store = FakeCloudStore()
        let device = try TestDevice(store: store,
                                    access: .unavailable(reason: "App ID 没开 iCloud（CloudKit）能力"))
        device.context.insert(Subscription(name: "Netflix"))
        try device.context.save()

        await device.coordinator.requestSync(reason: .manual)

        XCTAssertEqual(store.indexReads, 0, "没能力的时候连清单都不该读")
        XCTAssertEqual(store.saveBatches, 0)
        XCTAssertNil(lastSyncTime(device))
        guard case .failed(let reason) = device.coordinator.phase else {
            return XCTFail("没能力必须落在 failed，实际是 \(device.coordinator.phase)")
        }
        XCTAssertTrue(reason.contains("App ID 没开 iCloud"), "错误信息要能把缺的那一样说出来：\(reason)")
    }

    /// 签名给了 iCloud 但容器 id 和预期不同：能用，但界面上必须显示真实的那个 id。
    func testContainerMismatchIsSurfacedNotSwallowed() throws {
        let device = try TestDevice(store: FakeCloudStore(),
                                    access: .ready(containerIdentifier: "iCloud.com.someone.else"))
        XCTAssertEqual(device.coordinator.access.containerMismatch, "iCloud.com.someone.else")
    }

    /// 探测读的是签名里那份描述文件，不是编译条件。
    func testCapabilityProbeReadsTheSignedEntitlements() {
        XCTAssertEqual(CloudAccess.status(profile: nil),
                       .unavailable(reason: "这个包没有签名描述文件，读不到 iCloud 能力"))
        XCTAssertEqual(CloudAccess.status(profile: ProvisioningFixture.profile(services: [], containers: [])),
                       .unavailable(reason: "App ID 没开 iCloud（CloudKit）能力"))
        XCTAssertEqual(CloudAccess.status(profile: ProvisioningFixture.profile(services: ["CloudKit"], containers: [])),
                       .unavailable(reason: "开了 iCloud，但描述文件里没有一个容器标识"))
        XCTAssertEqual(CloudAccess.status(profile: ProvisioningFixture.profile(services: ["CloudKit"],
                                                                              containers: [CloudAccess.expectedContainerIdentifier])),
                       .ready(containerIdentifier: CloudAccess.expectedContainerIdentifier))
    }

    // MARK: - §4.2 状态机

    /// 阶段链那条单独放在 `SyncPhaseChainTests.swift`：它要 `import Combine`，
    /// 而 Combine 自己也有一个 `Subscription`，和本项目的 SwiftData 模型撞名 ——
    /// 这个文件里到处是 `FetchDescriptor<Subscription>`，加了那个 import 就全歧义了。

    func testAccountUnavailableStopsBeforeAnyLocalWrite() async throws {
        let store = FakeCloudStore()
        store.account = .noAccount
        let device = try makeDevice(store: store)
        let subscription = Subscription(name: "Netflix")
        device.context.insert(subscription)
        try device.context.save()

        await device.coordinator.requestSync(reason: .manual)

        XCTAssertEqual(store.saveBatches, 0, "账户不可用时一条都不该推上去")
        XCTAssertNil(lastSyncTime(device))
        XCTAssertEqual(device.coordinator.account, .noAccount)
        XCTAssertTrue(device.coordinator.phase.failure?.contains("iCloud 账户不可用") == true,
                      "要说清是哪一步拦住的：\(device.coordinator.phase.failure ?? "nil")")
    }

    /// 「查询了云端就记录同步成功」是上一版的真事故。这一条把它钉死：
    /// 服务端只是**没把这一条存下来**（没报错、少返回），必须是 failed 且没有成功时间。
    func testVerifyStageRejectsASuccessThatTheServerDidNotConfirm() async throws {
        let store = FakeCloudStore()
        let device = try makeDevice(store: store)
        let subscription = Subscription(name: "Netflix")
        device.context.insert(subscription)
        try device.context.save()
        store.drops = [subscription.id.uuidString]

        await device.coordinator.requestSync(reason: .manual)

        XCTAssertNil(lastSyncTime(device), "云端没收下就不能写「上次同步」")
        XCTAssertTrue(device.coordinator.phase.failure?.contains("云端没收下 1 条") == true,
                      "错误信息要带条数：\(device.coordinator.phase.failure ?? "nil")")
        XCTAssertEqual(store.records(of: .subscription).count, 0)
    }

    /// 整批被拒（CloudKit 的 batchRequestFailed）：本机数据一条没动，
    /// 原因要原样端出来，下一趟还得能原样重推 —— §4.3「批量失败可安全重试」。
    func testARefusedBatchReportsWhyAndIsRetriedOnTheNextPass() async throws {
        let store = FakeCloudStore()
        let device = try makeDevice(store: store)
        let subscription = Subscription(name: "Netflix")
        device.context.insert(subscription)
        try device.context.save()
        store.refuses = [subscription.id.uuidString]

        await device.coordinator.requestSync(reason: .manual)

        XCTAssertNil(lastSyncTime(device))
        XCTAssertTrue(device.coordinator.phase.failure?.contains("云端请求失败") == true,
                      "服务端那句原因要原样说出来：\(device.coordinator.phase.failure ?? "nil")")
        XCTAssertEqual(try device.context.fetch(FetchDescriptor<Subscription>()).count, 1,
                       "上传没成不该把本机那条弄丢")

        store.refuses = []
        await device.coordinator.requestSync(reason: .manual)
        XCTAssertEqual(store.records(of: .subscription).count, 1, "下一趟必须原样补推上去")
        XCTAssertNotNil(lastSyncTime(device))
    }

    /// 云端坏一条不该连累同批正常的那些：正常那条照样落库，坏的那条本机不动、报出来。
    func testOneUnreadableRemoteRowDoesNotStopTheRestOfTheBatch() async throws {
        let good = SyncFixtures.subscription(id: UUID(), name: "Netflix", updatedAt: SyncFixtures.t2)
        var brokenRecord = SyncFixtures.subscription(id: UUID(), name: "旧账号", updatedAt: SyncFixtures.t2)
        var broken = try XCTUnwrap(SyncFixtures.decode(brokenRecord.payload))
        broken.name = "   "     // 仓库整批校验会因为这种行把一切都退回，所以合并层先拦掉它
        brokenRecord.payload = (try? JSONEncoder.backup.encode(broken)) ?? Data()

        let store = FakeCloudStore()
        store.seed([good, brokenRecord])
        let device = try makeDevice(store: store)

        await device.coordinator.requestSync(reason: .manual)

        let rows = try device.context.fetch(FetchDescriptor<Subscription>())
        XCTAssertEqual(rows.map(\.name), ["Netflix"], "好行照常收下")
        XCTAssertEqual(device.coordinator.conflicts.count, 1, "坏行必须报出来，不能悄悄丢")
    }

    // MARK: - §4.2 六个触发源

    /// 没开自动同步时，除手点之外的五个来源都该被咽下 —— 但手点永远有效。
    func testAutoSwitchGatesTheFivePassiveTriggersButNotManual() async throws {
        let store = FakeCloudStore()
        let device = try makeDevice(store: store)
        device.coordinator.autoSyncEnabled = false

        for reason in [SyncReason.firstEnable, .localChange, .foreground, .networkRestored, .accountChanged] {
            await device.coordinator.requestSync(reason: reason)
        }
        XCTAssertEqual(store.indexReads, 0, "开关关着的时候五个被动来源都不该惊动云端")

        await device.coordinator.requestSync(reason: .manual)
        XCTAssertGreaterThan(store.indexReads, 0, "手点那一下必须真的跑")
    }

    /// 打开开关本身就是「首次启用」：不用等用户再点一次。
    func testTurningTheSwitchOnRunsOneFullSync() async throws {
        let store = FakeCloudStore()
        let device = try makeDevice(store: store)
        device.defaults.set(false, forKey: SyncCoordinator.autoSyncKey)

        device.coordinator.autoSyncEnabled = true
        XCTAssertTrue(device.coordinator.autoSyncEnabled)
        // 开关里挂的是 `Task { await ... }`，等它排完 —— 等的是条件本身，不是固定时长。
        try await waitFor { store.indexReads > 0 }
    }

    // MARK: - §4.3 同步范围与「删除不复活」

    /// 新设备第一次同步：云端那份订阅和它的记录都要落到库里，
    /// 落完之后本地时间不能是「刚刚」——那是备份恢复同一条规矩。
    func testFreshDeviceReceivesRemoteRowsIntoItsOwnDatabase() async throws {
        let id = UUID()
        let store = FakeCloudStore()
        store.seed([SyncFixtures.subscription(id: id, name: "Netflix", updatedAt: SyncFixtures.t2),
                    SyncFixtures.event(id: UUID(), subscriptionID: id, updatedAt: SyncFixtures.t2)])
        let device = try makeDevice(store: store)

        await device.coordinator.requestSync(reason: .manual)

        let rows = try device.context.fetch(FetchDescriptor<Subscription>())
        XCTAssertEqual(rows.map(\.name), ["Netflix"])
        XCTAssertEqual(rows.first?.updatedAt, SyncFixtures.t2, "照云端那份时间收下，不重新盖本机时刻")
        XCTAssertEqual(try device.context.fetch(FetchDescriptor<SubscriptionEvent>()).count, 1)
        let report = try XCTUnwrap(device.coordinator.phase.report)
        XCTAssertEqual(report.appliedSubscriptions, 1)
        XCTAssertEqual(report.appliedEvents, 1)
        XCTAssertEqual(report.remote.subscriptions, 1, "页面要能报出云端现在有几条")
        XCTAssertNotNil(lastSyncTime(device))
    }

    /// 任务书 §4.4 里最要命的那一条，用两台设备 + 一个共享「云端」演一遍：
    /// 设备 A 彻底删除、设备 B 当时离线、B 恢复上线后**不许**把它重新上传。
    func testDeletedOnOneDeviceDoesNotResurrectFromAnOfflineDevice() async throws {
        let store = FakeCloudStore()
        let a = try makeDevice(store: store)
        let b = try makeDevice(store: store)

        // A 建一条并同步上去。
        let subscription = Subscription(name: "Netflix", priceMinorUnits: 4500)
        a.context.insert(subscription)
        try a.context.save()
        await a.coordinator.requestSync(reason: .manual)
        XCTAssertEqual(store.records(of: .subscription).count, 1)

        // B 这会儿在线，收到这一条。
        await b.coordinator.requestSync(reason: .manual)
        XCTAssertEqual(try b.context.fetch(FetchDescriptor<Subscription>()).count, 1, "B 先要真的拿到这一条")

        // A 把它彻底删除 —— 行没了，只留下删除凭据。
        try SubscriptionRepository(context: a.context, tombstones: a.tombstones)
            .deletePermanently(subscription)
        XCTAssertNotNil(a.tombstones.date(for: .subscription, name: subscription.id.uuidString))
        await a.coordinator.requestSync(reason: .manual)
        XCTAssertNotNil(store.records(of: .subscription).first?.deletedAt,
                        "云端那条记录本身也要改成已删除，不能一半说活一半说死")
        XCTAssertEqual(store.records(of: .tombstone).count, 1, "凭据要能在云端看到")

        // B 一直离线（没同步过），现在上线。
        let remoteBeforeB = store.records(of: .subscription)
        let savesBeforeB = store.saveBatches
        await b.coordinator.requestSync(reason: .manual)

        let live = try b.context.fetch(FetchDescriptor<Subscription>()).filter { $0.deletedAt == nil }
        XCTAssertTrue(live.isEmpty, "B 手里那条必须进回收站，不能还是活的")
        XCTAssertEqual(try b.context.fetch(FetchDescriptor<Subscription>()).count, 1,
                       "进回收站不是硬删：用户自己还能看见、还能捞")
        XCTAssertEqual(store.records(of: .subscription).count, remoteBeforeB.count,
                       "B 这一趟不该往云端多出任何东西")
        XCTAssertEqual(store.records(of: .tombstone).count, 1, "凭据也不该被复制成两张")

        // 再同步一次（幂等）：还是不能被 B 复活，也不该反复重推。
        let report = try XCTUnwrap(b.coordinator.phase.report)
        XCTAssertEqual(report.uploaded, 0, "第一趟就该把该传的都传完了")
        await b.coordinator.requestSync(reason: .manual)
        XCTAssertTrue(try b.context.fetch(FetchDescriptor<Subscription>()).filter { $0.deletedAt == nil }.isEmpty)
        XCTAssertEqual(store.saveBatches, savesBeforeB, "第二趟一趟都不该再写云端")
    }

    /// 云端那份里带的归档和置顶，恢复下来必须一个都不清空（§4.3）。
    func testArchivedAndPinnedStatesSurviveTheRoundTrip() async throws {
        let id = UUID()
        var record = SyncFixtures.subscription(id: id, name: "Netflix", updatedAt: SyncFixtures.t2)
        var payload = try XCTUnwrap(SyncFixtures.decode(record.payload))
        payload.archivedAt = SyncFixtures.t1
        payload.pinnedAt = SyncFixtures.t1
        payload.deletedAt = SyncFixtures.t1
        record.payload = (try? JSONEncoder.backup.encode(payload)) ?? Data()

        let store = FakeCloudStore()
        store.seed([record])
        let device = try makeDevice(store: store)

        await device.coordinator.requestSync(reason: .manual)

        let row = try XCTUnwrap(try device.context.fetch(FetchDescriptor<Subscription>()).first)
        XCTAssertEqual(row.archivedAt, SyncFixtures.t1)
        XCTAssertEqual(row.pinnedAt, SyncFixtures.t1)
        XCTAssertEqual(row.deletedAt, SyncFixtures.t1, "回收站状态也是数据，不能被同步悄悄清掉")
    }

    /// 图标字节只在缺的时候才取，而且必须验过校验和才落盘。
    /// 校验和对不上就是不落 —— 「看着回来了其实是另一张图」不是修复。
    func testIconBytesLandOnlyWhenTheChecksumMatches() async throws {
        let id = UUID()
        let good = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let record = SyncFixtures.subscription(id: id, name: "Netflix", updatedAt: SyncFixtures.t2,
                                              icon: good, iconChecksum: CloudRecord.iconChecksum(of: good))
        let store = FakeCloudStore()
        store.seed([record])
        let device = try makeDevice(store: store)

        await device.coordinator.requestSync(reason: .manual)
        XCTAssertEqual(device.icons.data(for: "\(id.uuidString).png"), good, "校验和对了才落盘")

        // 第二台设备：云端那份的字节和它自己声明的校验和不一致。
        let forged = SyncFixtures.subscription(id: UUID(), name: "别家的图", updatedAt: SyncFixtures.t2,
                                               icon: Data([0xFF]), iconChecksum: "不可能等于上面那个的校验和")
        let liar = FakeCloudStore()
        liar.seed([forged])
        let other = try makeDevice(store: liar)
        await other.coordinator.requestSync(reason: .manual)
        let file = "\(forged.name).png"
        XCTAssertFalse(other.icons.exists(file), "校验和对不上就不许写盘")
    }

    /// 分类 / 支付方式 / 基础货币 / 默认提醒这四组偏好都要真的走云端，
    /// 而且收下之后不能被下一趟原样推回去。
    func testSettingsGroupsSyncBothWaysAndSettleDown() async throws {
        let store = FakeCloudStore()
        let a = try makeDevice(store: store)
        let b = try makeDevice(store: store)

        a.preferences.categories = [SubscriptionCategory(id: "video", name: "视频",
                                                         colorHex: "#FF0000", symbol: "play.tv")]
        a.preferences.defaultReminderDays = 7
        await a.coordinator.requestSync(reason: .manual)
        XCTAssertEqual(store.records(of: .setting).count, SyncedSettingGroup.allCases.count,
                       "四组偏好每组一条云端记录")

        // B 装机后一个戳都没有（那份是本机默认值，不可信）：现在能收到云端那份了。
        await b.coordinator.requestSync(reason: .manual)
        XCTAssertEqual(b.preferences.categories.map(\.name), ["视频"])
        XCTAssertEqual(b.preferences.defaultReminderDays, 7)

        let before = store.saveBatches
        await b.coordinator.requestSync(reason: .manual)
        XCTAssertEqual(store.saveBatches, before, "刚收下的设置不能再当本机新改动推回去")
    }

    // MARK: - 冲突留档

    /// 两边同一时刻各写一份：本机不动、云端那份原样留着，而且重启还在。
    func testUnresolvableConflictLeavesLocalAloneAndKeepsTheRemoteCopy() async throws {
        let id = UUID()
        let store = FakeCloudStore()
        store.seed([SyncFixtures.subscription(id: id, name: "Netflix", updatedAt: SyncFixtures.t2, price: 6800)])
        let device = try makeDevice(store: store)

        let local = Subscription(id: id, name: "Netflix", priceMinorUnits: 4500)
        device.context.insert(local)
        try device.context.save()
        local.updatedAt = SyncFixtures.t2   // 同一时刻，内容不同
        try device.context.save()

        await device.coordinator.requestSync(reason: .manual)

        let row = try XCTUnwrap(try device.context.fetch(FetchDescriptor<Subscription>()).first)
        XCTAssertEqual(row.priceMinorUnits, 4500, "不可判定时不许猜一份盖掉另一边")
        let conflict = try XCTUnwrap(device.coordinator.conflicts.first)
        XCTAssertEqual(conflict.name, id.uuidString)
        XCTAssertEqual(SyncFixtures.decode(conflict.remotePayload)?.priceMinorUnits, 6800,
                       "留档的必须是云端那一份原样")

        // 「重启之后还在」：同一个偏好域再建一个协调器。
        let restarted = SyncCoordinator(container: device.container, preferences: device.preferences,
                                        defaults: device.defaults, access: device.coordinator.access,
                                        store: store, tombstones: device.tombstones, icons: device.icons)
        XCTAssertEqual(restarted.conflicts.count, 1)
        restarted.clearConflictLog()
        XCTAssertNil(device.defaults.data(forKey: SyncCoordinator.conflictKey))
    }

    /// 一张删除凭据在后面每一趟都得还在，而且不该牵连别的订阅：
    /// 凭据一旦在半路丢了，那条订阅下一轮就会被当成「云端没有的新订阅」原样传回去。
    func testADeletionCredentialSurvivesEveryLaterSyncAndDoesNotTouchOtherRows() async throws {
        let store = FakeCloudStore()
        let device = try makeDevice(store: store)
        let subscription = Subscription(name: "Netflix")
        device.context.insert(subscription)
        try device.context.save()
        await device.coordinator.requestSync(reason: .manual)

        // 先删：本机日志和云端都留下凭据。
        try SubscriptionRepository(context: device.context, tombstones: device.tombstones)
            .deletePermanently(subscription)
        await device.coordinator.requestSync(reason: .manual)
        XCTAssertEqual(store.records(of: .tombstone).count, 1)

        // 用户又建了一条同名的新订阅（新编号，不冲突）：正常同步不该碰那张凭据。
        let fresh = Subscription(name: "Netflix")
        device.context.insert(fresh)
        try device.context.save()
        await device.coordinator.requestSync(reason: .manual)
        XCTAssertEqual(store.records(of: .tombstone).count, 1, "别的订阅不该被这张凭据牵连")
        XCTAssertNotNil(device.tombstones.date(for: .subscription, name: subscription.id.uuidString),
                        "凭据要一直留在本机日志里，不然那条死掉的订阅会被重新当活的传上去")
    }

    /// 彻底删过之后本机又出现一份时间更新的活版本（从备份恢复、导入旧表都算）：
    /// 按策略本机这份赢，但那张凭据必须本机日志和云端两边一起清掉，而且要说出来 ——
    /// 悄悄复活和悄悄消失一样糟（§4.3「删除与更新冲突要有明确策略」）。
    func testALiveRowNewerThanItsOwnCredentialClearsItOnBothSides() async throws {
        let id = UUID()
        let store = FakeCloudStore()
        let device = try makeDevice(store: store)
        let subscription = Subscription(id: id, name: "Netflix", priceMinorUnits: 4500)
        device.context.insert(subscription)
        try device.context.save()
        await device.coordinator.requestSync(reason: .manual)
        try SubscriptionRepository(context: device.context, tombstones: device.tombstones)
            .deletePermanently(subscription)
        await device.coordinator.requestSync(reason: .manual)
        XCTAssertEqual(store.records(of: .tombstone).count, 1, "先确认云端真有一张凭据，后面才谈作废")

        let revived = Subscription(id: id, name: "Netflix", priceMinorUnits: 6800)
        device.context.insert(revived)
        try device.context.save()
        revived.updatedAt = Date()
        try device.context.save()

        await device.coordinator.requestSync(reason: .manual)

        let row = try XCTUnwrap(device.context.fetch(FetchDescriptor<Subscription>()).first)
        XCTAssertNil(row.deletedAt, "本机这份赢了，它就得是活的")
        XCTAssertNil(device.tombstones.date(for: .subscription, name: id.uuidString), "本机日志里那张作废的凭据要抹掉")
        XCTAssertTrue(store.records(of: .tombstone).isEmpty, "云端那张也得跟着删，不然两边各说一件")
        let report = try XCTUnwrap(device.coordinator.phase.report)
        XCTAssertEqual(report.revived, 1)
        XCTAssertEqual(report.cloudCleared, 1)
        let conflict = try XCTUnwrap(device.coordinator.conflicts.first)
        XCTAssertEqual(conflict.name, id.uuidString, "复活不能悄悄发生：得留一条能说出口的记载")
    }

    /// 到期凭据的销毁顺序：云端确认删掉了才动本机日志。
    /// 反着来会出最坏的那种状态 —— 云端还压着墓碑，本机却已经不知道这件事了。
    func testExpiryOnlyClearsTheLocalLogAfterTheCloudConfirms() async throws {
        let id = UUID()
        let longAgo = Date(timeIntervalSince1970: 400_000_000)   // 远在 180 天保留期之前
        let store = FakeCloudStore()
        store.seed([SyncFixtures.subscription(id: id, name: "Netflix", updatedAt: longAgo)])
        let device = try makeDevice(store: store)
        device.tombstones.record(kind: .subscription, name: id.uuidString, at: longAgo)
        store.deleteFails = true

        await device.coordinator.requestSync(reason: .manual)

        XCTAssertNotNil(device.tombstones.date(for: .subscription, name: id.uuidString),
                        "云端没确认删掉，本机日志不许先忘")
        let first = try XCTUnwrap(device.coordinator.phase.report)
        XCTAssertEqual(first.cloudCleanupDeferred, 1, "这一趟云端只欠着那一条订阅记录")
        XCTAssertEqual(first.cloudCleared, 0)

        // 云端肯删了：先删干净，再动本机日志。
        store.deleteFails = false
        await device.coordinator.requestSync(reason: .manual)

        let second = try XCTUnwrap(device.coordinator.phase.report)
        XCTAssertEqual(second.cloudCleared, 2, "墓碑和它压着的那条一起清掉")
        XCTAssertEqual(second.cloudCleanupDeferred, 0)
        XCTAssertNil(device.tombstones.date(for: .subscription, name: id.uuidString))
        XCTAssertTrue(store.records(of: .tombstone).isEmpty)
        XCTAssertTrue(store.records(of: .subscription).isEmpty)
    }

    // MARK: - 等待

    /// 开关里挂的是 `Task { await ... }`：轮询而不是睡固定时间，
    /// 免得把「等多久」变成测试里的隐性约定。
    private func waitFor(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while condition() == false {
            if Date() > deadline { XCTFail("等到的应该是条件，不是超时就当通过"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

// MARK: - 内存版云端

/// 一台设备看得见的「云端」就是这个对象。
/// 它按 CloudKit 的规矩做三件事：清单不带图标字节、整批要么全收要么报错、
/// 删除只认真删掉的名字。合并和核对的规矩全都由生产代码判，这里只当搬运工。
final class FakeCloudStore: CloudRecordStore {
    private var buckets: [CloudRecordKind: [String: CloudRecord]] = [:]
    var account: CloudAccountStatus = .available
    /// 这些名字服务端**默默不收**：整批照样返回，但返回值里缺这几条。
    /// 「我叫了保存就一定存上了」是上一版的假成功，这一条专门考它。
    var drops: Set<String> = []
    /// 这些名字服务端不肯收：整个批次直接报错（CloudKit 的 batchRequestFailed 就是这个形状）。
    var refuses: Set<String> = []
    var deleteFails = false
    private(set) var indexReads = 0
    private(set) var saveBatches = 0

    func seed(_ records: [CloudRecord]) {
        for record in records { store(record) }
    }

    func records(of kind: CloudRecordKind) -> [CloudRecord] {
        (buckets[kind] ?? [:]).values.sorted { $0.name < $1.name }
    }

    func index(of kind: CloudRecordKind) async throws -> [CloudRecord] {
        indexReads += 1
        // 清单里就是没有图标字节：想要图得单独按名字取。
        return records(of: kind).map { var trimmed = $0; trimmed.icon = nil; return trimmed }
    }

    func records(of kind: CloudRecordKind, names: [String]) async throws -> [CloudRecord] {
        names.compactMap { buckets[kind]?[$0] }
    }

    @discardableResult
    func save(_ records: [CloudRecord]) async throws -> [CloudRecord] {
        guard records.isEmpty == false else { return [] }
        saveBatches += 1
        if let refused = records.first(where: { refuses.contains($0.name) }) {
            throw CloudStoreError.requestFailed("云端没收下这一条：\(refused.name)")
        }
        let stored = records.filter { drops.contains($0.name) == false }
        for record in stored { store(record) }
        // 返回的是「真正存下来的」，不是「我叫它存的那些」。
        return stored
    }

    @discardableResult
    func delete(_ kind: CloudRecordKind, names: [String]) async throws -> [String] {
        if deleteFails { throw CloudStoreError.requestFailed("云端不肯删") }
        return names.filter { (buckets[kind]?[$0]) != nil }
            .map { name in
                buckets[kind]?.removeValue(forKey: name)
                return name
            }
    }

    func accountStatus() async throws -> CloudAccountStatus { account }

    private func store(_ record: CloudRecord) {
        var bucket = buckets[record.kind] ?? [:]
        bucket[record.name] = record
        buckets[record.kind] = bucket
    }
}

// MARK: - 一台设备

/// 「设备」= 自己的容器 + 自己的偏好域 + 自己的删除凭据日志 + 自己的图标目录。
/// 这些必须各来一份：共用偏好日志的话，A 的凭据会直接出现在 B 眼前，
/// 那条最要命的离线复活路径就没法测了。
@MainActor
final class TestDevice {
    let suiteName: String
    let defaults: UserDefaults
    let preferences: SubPreferences
    let tombstones: SyncTombstoneLog
    let icons: IconImageStore
    let container: ModelContainer
    let context: ModelContext
    let coordinator: SyncCoordinator
    private let iconRoot: URL

    init(store: FakeCloudStore?,
         access: CloudAccess.Status = .ready(containerIdentifier: CloudAccess.expectedContainerIdentifier)) throws {
        suiteName = "saury.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        preferences = SubPreferences(defaults: defaults)
        tombstones = SyncTombstoneLog(defaults: defaults)
        iconRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("saury-icons-\(UUID().uuidString)", isDirectory: true)
        icons = IconImageStore(root: iconRoot)
        container = try PersistenceController.makeInMemoryContainer()
        context = ModelContext(container)
        coordinator = SyncCoordinator(container: container, preferences: preferences, defaults: defaults,
                                      access: access, store: store, tombstones: tombstones, icons: icons)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: iconRoot)
    }
}

/// 造一份描述文件的壳：真实文件是 CMS 包着一段 XML plist，这里同样只在前后塞垃圾字节，
/// 考的就是「从签名的字节里读权限」这一段而不是「读一个 plist 文件」。
enum ProvisioningFixture {
    static func profile(services: [String], containers: [String]) -> Data {
        let plist: [String: Any] = ["Entitlements": [
            "com.apple.developer.icloud-services": services,
            "com.apple.developer.icloud-container-identifiers": containers,
        ]]
        let xml = (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
        // CMS 包在 plist 外面：前后都是二进制垃圾字节，`<?xml` 之前那几个就是 \0 和 \1。
        let head = Data([0x63, 0x63, 0x63, 0x63, 0x00, 0x01] + Array("junk".utf8))
        let tail = Data(Array("\0trailing".utf8))
        return head + xml + tail
    }
}
