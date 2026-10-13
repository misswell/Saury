import XCTest
import SwiftData
@testable import Saury

/// 任务书 §4.3 那张决定表的单元测试。
///
/// 为什么单独测这一层：合并、墓碑、幂等、冲突这些规矩全在 `SyncMerge` 里判完，
/// 它不碰数据库也不碰 CloudKit，所以这些承诺能被真考一遍 ——
/// CloudKit 在这个环境里一次都跑不起来（签名没给能力），
/// 把规矩写在 CKRecord 上面就等于一行没测。
final class SyncMergeTests: XCTestCase {

    // MARK: - 删除不许复活

    /// 设备 A 删了这条，云端留下删除凭据；设备 B 手里还留着活的那一条。
    /// B 这一趟只能把它收进回收站，**一条都不许作为活记录推回去**。
    func testRemoteDeletionTrashesLocalRowAndNeverReuploadsIt() {
        let id = UUID()
        let name = id.uuidString
        var local = LocalSyncState()
        local.subscriptions = [SyncFixtures.subscription(id: id, name: "Netflix", updatedAt: SyncFixtures.t1)]

        var remote = RemoteSyncState()
        remote.tombstones = [SyncFixtures.marker(.subscription, name: name, at: SyncFixtures.t2)]

        let plan = SyncMerge.plan(local: local, remote: remote, retentionCutoff: SyncFixtures.t3)

        XCTAssertEqual(plan.subscriptionsToTrash, [TrashEntry(name: name, deletedAt: SyncFixtures.t2)])
        XCTAssertFalse(plan.uploads.contains { $0.name == name }, "被删掉的那条不能当作活的重新上传")
        XCTAssertTrue(plan.subscriptionsToApply.isEmpty)
        // 云端已经有凭据了，不该再补一张。
        XCTAssertTrue(plan.tombstonesToRecord.isEmpty)
    }

    /// 本机这条早就判过死刑（本地墓碑），云端那份还写着活着：
    /// 上传的必须是「已删除」的那一份，而且本机日志里这笔要能推到云端。
    func testLocalTombstonePushesDeletedShapeNotAliveCopy() {
        let id = UUID()
        let name = id.uuidString
        let payload = SyncFixtures.subscriptionPayload(id: id, name: "Netflix")

        var local = LocalSyncState()
        local.subscriptionTombstones = [name: SyncFixtures.t2]

        var remote = RemoteSyncState()
        remote.subscriptions = [CloudRecord(kind: .subscription, name: name, updatedAt: SyncFixtures.t1,
                                           deletedAt: nil, payload: payload, icon: nil, iconChecksum: nil)]

        let plan = SyncMerge.plan(local: local, remote: remote, retentionCutoff: SyncFixtures.t3)

        XCTAssertEqual(plan.uploads.count, 1)
        XCTAssertEqual(plan.uploads.first?.deletedAt, SyncFixtures.t2)
        XCTAssertEqual(SyncFixtures.decode(plan.uploads.first?.payload)?.deletedAt, SyncFixtures.t2,
                       "payload 里的删除时间也要写上，免得云端一半说活一半说死")
        XCTAssertEqual(plan.tombstonesToRecord.map(\.name), [name])
        XCTAssertTrue(plan.subscriptionsToApply.isEmpty)
    }

    /// 删除时间和活记录的时间一模一样：算删除赢。「同一刻一边删一边改」不该复活。
    func testDeletionWinsTheTie() {
        let id = UUID()
        let name = id.uuidString
        var local = LocalSyncState()
        local.subscriptions = [SyncFixtures.subscription(id: id, name: "Netflix", updatedAt: SyncFixtures.t2)]
        var remote = RemoteSyncState()
        remote.tombstones = [SyncFixtures.marker(.subscription, name: name, at: SyncFixtures.t2)]

        let plan = SyncMerge.plan(local: local, remote: remote, retentionCutoff: SyncFixtures.t3)
        XCTAssertEqual(plan.subscriptionsToTrash.count, 1, "时刻相同算删除赢")
        XCTAssertTrue(plan.uploads.isEmpty)
    }

    // MARK: - 时间戳与冲突

    func testNewerRemoteRowWinsAndItsIconIsFetched() {
        let id = UUID()
        let icon = Data([0x89, 0x50, 0x4E, 0x47])
        let checksum = CloudRecord.iconChecksum(of: icon)
        var local = LocalSyncState()
        var remote = RemoteSyncState()
        remote.subscriptions = [SyncFixtures.subscription(id: id, name: "Netflix", updatedAt: SyncFixtures.t2,
                                                         icon: icon, iconChecksum: checksum)]

        let plan = SyncMerge.plan(local: local, remote: remote, retentionCutoff: SyncFixtures.t3)
        XCTAssertEqual(plan.subscriptionsToApply.map(\.name), ["Netflix"])
        XCTAssertEqual(plan.iconsToFetch, [IconFetch(name: id.uuidString, fileName: "\(id.uuidString).png", checksum: checksum)])
        XCTAssertTrue(plan.uploads.isEmpty, "本机这一条什么都没有，没有要往上推的东西")
    }

    /// 两边在同一时刻各写了一份不一样的：谁都不许覆盖，云端那份原样留档。
    func testEqualTimestampWithDifferentContentTouchesNeitherSide() {
        let id = UUID()
        var local = LocalSyncState()
        local.subscriptions = [SyncFixtures.subscription(id: id, name: "Netflix", updatedAt: SyncFixtures.t2, price: 4500)]
        var remote = RemoteSyncState()
        remote.subscriptions = [SyncFixtures.subscription(id: id, name: "Netflix", updatedAt: SyncFixtures.t2, price: 6800)]

        let plan = SyncMerge.plan(local: local, remote: remote, retentionCutoff: SyncFixtures.t3)
        XCTAssertTrue(plan.subscriptionsToApply.isEmpty, "不可判定时不许猜一份盖掉另一边")
        XCTAssertTrue(plan.uploads.isEmpty)
        XCTAssertEqual(plan.conflicts.count, 1)
        let conflict = try? XCTUnwrap(plan.conflicts.first)
        XCTAssertEqual(conflict?.subject, .subscription)
        XCTAssertEqual(SyncFixtures.decode(conflict?.remotePayload)?.priceMinorUnits, 6800,
                       "留档的必须是云端那一份原样")
    }

    func testOlderRemoteRowLosesAndLocalIsUploaded() {
        let id = UUID()
        var local = LocalSyncState()
        local.subscriptions = [SyncFixtures.subscription(id: id, name: "Netflix", updatedAt: SyncFixtures.t3)]
        var remote = RemoteSyncState()
        remote.subscriptions = [SyncFixtures.subscription(id: id, name: "Netflix", updatedAt: SyncFixtures.t1, price: 100)]

        let plan = SyncMerge.plan(local: local, remote: remote, retentionCutoff: SyncFixtures.t4)
        XCTAssertEqual(plan.uploads.map(\.name), [id.uuidString])
        XCTAssertTrue(plan.subscriptionsToApply.isEmpty)
        XCTAssertTrue(plan.conflicts.isEmpty)
    }

    // MARK: - 事件

    /// 事件按自己的编号合并：两边各自新增的都要到齐，同一个编号不会进两次。
    func testEventsMergeByTheirOwnIDFromBothDirections() {
        let kept = UUID()
        let onlyLocal = UUID()
        let onlyRemote = UUID()
        var local = LocalSyncState()
        local.events = [SyncFixtures.event(id: kept, subscriptionID: kept, updatedAt: SyncFixtures.t1),
                        SyncFixtures.event(id: onlyLocal, subscriptionID: kept, updatedAt: SyncFixtures.t1)]
        var remote = RemoteSyncState()
        remote.events = [SyncFixtures.event(id: kept, subscriptionID: kept, updatedAt: SyncFixtures.t1),
                         SyncFixtures.event(id: onlyRemote, subscriptionID: kept, updatedAt: SyncFixtures.t1)]

        let plan = SyncMerge.plan(local: local, remote: remote, retentionCutoff: SyncFixtures.t3)
        XCTAssertEqual(plan.eventsToApply.map(\.id), [onlyRemote])
        XCTAssertEqual(plan.uploads.map(\.name), [onlyLocal.uuidString])
        XCTAssertTrue(plan.conflicts.isEmpty, "内容一样的那一条不算冲突")
    }

    /// 同一个编号两边内容不同：事件身上的时间是「发生时间」，判不出谁后来改的，
    /// 所以两边都不动、只留档。
    func testEventContentMismatchKeepsBothSides() {
        let id = UUID()
        let owner = UUID()
        var local = LocalSyncState()
        local.events = [SyncFixtures.event(id: id, subscriptionID: owner, updatedAt: SyncFixtures.t1, amount: 4500)]
        var remote = RemoteSyncState()
        remote.events = [SyncFixtures.event(id: id, subscriptionID: owner, updatedAt: SyncFixtures.t1, amount: 6800)]

        let plan = SyncMerge.plan(local: local, remote: remote, retentionCutoff: SyncFixtures.t2)
        XCTAssertTrue(plan.eventsToApply.isEmpty)
        XCTAssertTrue(plan.uploads.isEmpty)
        XCTAssertEqual(plan.conflicts.map(\.subject), [.event])
    }

    func testEventDeletedByAnotherDeviceIsNotReuploaded() {
        let id = UUID()
        let owner = UUID()
        var local = LocalSyncState()
        local.events = [SyncFixtures.event(id: id, subscriptionID: owner, updatedAt: SyncFixtures.t1)]
        local.eventTombstones = [id.uuidString: SyncFixtures.t2]

        let plan = SyncMerge.plan(local: local, remote: RemoteSyncState(), retentionCutoff: SyncFixtures.t3)
        XCTAssertTrue(plan.uploads.isEmpty, "删过的记录不能再当作新增推上云")
    }

    // MARK: - 偏好

    /// 没盖过时间戳的旧值算不可信：**绝不拿它盖云端已有的那份**；
    /// 但云端那份是唯一有凭据的，本机要收下 —— 否则新装的设备一辈子拿不到分类和支付方式。
    func testUntrustedLocalSettingsOnlySeedAnEmptyCloud() {
        let content = SyncedSettings(defaultCurrency: "USD")
        var local = LocalSyncState()
        local.settings = [CloudRecord(kind: .setting, name: SyncedSettingGroup.currency.recordName,
                                      updatedAt: .distantPast, deletedAt: nil,
                                      payload: content.encoded, icon: nil, iconChecksum: nil)]

        let fresh = SyncMerge.plan(local: local, remote: RemoteSyncState(), retentionCutoff: SyncFixtures.t3)
        XCTAssertEqual(fresh.uploads.count, 1, "云端是空的，可以拿本机这份做第一份")

        var remote = RemoteSyncState()
        remote.settings = [CloudRecord(kind: .setting, name: SyncedSettingGroup.currency.recordName,
                                       updatedAt: SyncFixtures.t2, deletedAt: nil,
                                       payload: SyncedSettings(defaultCurrency: "CNY").encoded,
                                       icon: nil, iconChecksum: nil)]
        let stale = SyncMerge.plan(local: local, remote: remote, retentionCutoff: SyncFixtures.t3)
        XCTAssertTrue(stale.uploads.isEmpty, "本机这份没时间凭据，不能盖掉云端那一份")
        XCTAssertEqual(stale.settingsToApply.map(\.group), [.currency], "云端那份得收下来")
        XCTAssertEqual(stale.settingsToApply.first?.revisionAt, SyncFixtures.t2, "按云端那一刻记下来")
    }

    /// 两边都没盖过戳：谁都不动，云端那份原样留档。
    /// 猜一份就是拿装机默认值盖掉用户挑过的设置。
    func testBothUntrustedSettingsTouchNeitherSide() {
        var local = LocalSyncState()
        local.settings = [CloudRecord(kind: .setting, name: SyncedSettingGroup.currency.recordName,
                                      updatedAt: .distantPast, deletedAt: nil,
                                      payload: SyncedSettings(defaultCurrency: "USD").encoded,
                                      icon: nil, iconChecksum: nil)]
        var remote = RemoteSyncState()
        remote.settings = [CloudRecord(kind: .setting, name: SyncedSettingGroup.currency.recordName,
                                       updatedAt: .distantPast, deletedAt: nil,
                                       payload: SyncedSettings(defaultCurrency: "CNY").encoded,
                                       icon: nil, iconChecksum: nil)]

        let plan = SyncMerge.plan(local: local, remote: remote, retentionCutoff: SyncFixtures.t3)
        XCTAssertTrue(plan.uploads.isEmpty)
        XCTAssertTrue(plan.settingsToApply.isEmpty)
        XCTAssertEqual(plan.conflicts.count, 1, "两边都没凭据也要说出来，不能悄悄不处理")
    }

    /// 收下云端那份之后，本机的「这组改动时间」必须对齐到云端那一刻，
    /// 否则下一轮会把自己刚收下的东西当成本机新改动原样推回去 —— 幂等就断在这里。
    func testAppliedSettingsCarryTheRemoteRevisionStamp() {
        var local = LocalSyncState()
        local.settings = [CloudRecord(kind: .setting, name: SyncedSettingGroup.currency.recordName,
                                      updatedAt: SyncFixtures.t1, deletedAt: nil,
                                      payload: SyncedSettings(defaultCurrency: "USD").encoded,
                                      icon: nil, iconChecksum: nil)]
        var remote = RemoteSyncState()
        remote.settings = [CloudRecord(kind: .setting, name: SyncedSettingGroup.currency.recordName,
                                       updatedAt: SyncFixtures.t2, deletedAt: nil,
                                       payload: SyncedSettings(defaultCurrency: "CNY").encoded,
                                       icon: nil, iconChecksum: nil)]

        let plan = SyncMerge.plan(local: local, remote: remote, retentionCutoff: SyncFixtures.t3)
        XCTAssertEqual(plan.settingsToApply.map(\.group), [.currency])
        XCTAssertEqual(plan.settingsToApply.first?.revisionAt, SyncFixtures.t2)
        XCTAssertEqual(plan.settingsToApply.first?.content.defaultCurrency, "CNY")
    }

    // MARK: - 保留期

    func testExpiredCredentialClearsMarkerAndTheRowUnderIt() {
        let id = UUID()
        let name = id.uuidString
        var local = LocalSyncState()
        local.subscriptionTombstones = [name: SyncFixtures.t1]
        var remote = RemoteSyncState()
        remote.tombstones = [SyncFixtures.marker(.subscription, name: name, at: SyncFixtures.t1)]

        let plan = SyncMerge.plan(local: local, remote: remote, retentionCutoff: SyncFixtures.t2)
        let names = Set(plan.cloudDeletions.map { "\($0.kind)\($0.name)" })
        XCTAssertTrue(names.contains("\(CloudRecordKind.tombstone)\(SyncFixtures.markerName(.subscription, name: name))"),
                      "到期凭据本身要从云端清掉")
        XCTAssertTrue(names.contains("\(CloudRecordKind.subscription)\(name)"),
                      "它压着的那条记录也要一起清掉")
    }

    /// 回收站里还躺着这一条：不能把云端那份清掉，否则下一轮本机又把它当新增传回去，
    /// 每趟同步都白删一次、白传一次。
    func testExpirySkipsRowsThatAreStillInLocalTrash() {
        let id = UUID()
        let name = id.uuidString
        var local = LocalSyncState()
        local.subscriptionTombstones = [name: SyncFixtures.t1]
        local.subscriptions = [SyncFixtures.subscription(id: id, name: "Netflix", updatedAt: SyncFixtures.t1,
                                                        deletedAt: SyncFixtures.t1)]
        var remote = RemoteSyncState()
        remote.tombstones = [SyncFixtures.marker(.subscription, name: name, at: SyncFixtures.t1)]

        let plan = SyncMerge.plan(local: local, remote: remote, retentionCutoff: SyncFixtures.t2)
        XCTAssertTrue(plan.cloudDeletions.isEmpty)
    }

    // MARK: - 恢复与作废

    /// 用户亲手把这条从回收站捞回来了（本机这份的时间比凭据新）：
    /// 本机这份赢，但那两张凭据必须一起作废，否则它会被一直按着、两边永远各说各话。
    func testRowNewerThanItsOwnDeletionCredentialVoidsItAndReportsIt() {
        let id = UUID()
        let name = id.uuidString
        var local = LocalSyncState()
        local.subscriptions = [SyncFixtures.subscription(id: id, name: "Netflix", updatedAt: SyncFixtures.t3)]
        local.subscriptionTombstones = [name: SyncFixtures.t1]

        var remote = RemoteSyncState()
        remote.tombstones = [SyncFixtures.marker(.subscription, name: name, at: SyncFixtures.t1)]

        let plan = SyncMerge.plan(local: local, remote: remote, retentionCutoff: SyncFixtures.t4)
        XCTAssertEqual(plan.uploads.map(\.name), [name], "本机这份要重新推上去")
        XCTAssertEqual(plan.revivedTombstones, [TombstonePointer(kind: .subscription, name: name)])
        XCTAssertTrue(plan.cloudDeletions.contains(CloudDeletion(kind: .tombstone,
                                                                name: SyncFixtures.markerName(.subscription, name: name))),
                      "云端那张凭据也要跟着删掉")
        XCTAssertEqual(plan.conflicts.count, 1, "复活是策略决定，但必须说出来")
        XCTAssertTrue(plan.subscriptionsToTrash.isEmpty)
    }

    /// 软删除之后用户自己在回收站里恢复：这是界面允许的常规操作，不该报成冲突。
    func testOrdinaryTrashRoundTripIsNotReportedAsConflict() {
        let id = UUID()
        let name = id.uuidString
        var local = LocalSyncState()
        local.subscriptions = [SyncFixtures.subscription(id: id, name: "Netflix", updatedAt: SyncFixtures.t3)]
        // 只有云端记录上的 deletedAt 字段，没有任何一张正式凭据。
        var remote = RemoteSyncState()
        remote.subscriptions = [SyncFixtures.subscription(id: id, name: "Netflix", updatedAt: SyncFixtures.t2,
                                                         deletedAt: SyncFixtures.t2)]

        let plan = SyncMerge.plan(local: local, remote: remote, retentionCutoff: SyncFixtures.t4)
        XCTAssertEqual(plan.uploads.map(\.name), [name])
        XCTAssertTrue(plan.conflicts.isEmpty)
    }

    // MARK: - 幂等与确定性

    /// 「这一趟和下一趟判得一样」：同样的两边状态，输入顺序打乱也必须给出逐字节相同的计划。
    /// 字典遍历顺序每次都不一样，不排序的话幂等这条命题根本没法证。
    func testPlanDoesNotDependOnInputOrder() {
        // 编号必须两边共用同一批：每次现造 UUID 的话比的是随机数，不是顺序。
        let a = UUID(), b = UUID(), c = UUID()
        func makePlan(shuffled: Bool) -> SyncPlan {
            var local = LocalSyncState()
            local.subscriptions = [SyncFixtures.subscription(id: a, name: "A", updatedAt: SyncFixtures.t2),
                                   SyncFixtures.subscription(id: b, name: "B", updatedAt: SyncFixtures.t1),
                                   SyncFixtures.subscription(id: c, name: "C", updatedAt: SyncFixtures.t3)]
            local.subscriptionTombstones = [b.uuidString: SyncFixtures.t4]
            var remote = RemoteSyncState()
            remote.subscriptions = shuffled
                ? [SyncFixtures.subscription(id: c, name: "C2", updatedAt: SyncFixtures.t1),
                   SyncFixtures.subscription(id: b, name: "B2", updatedAt: SyncFixtures.t1),
                   SyncFixtures.subscription(id: a, name: "A2", updatedAt: SyncFixtures.t1)]
                : [SyncFixtures.subscription(id: a, name: "A2", updatedAt: SyncFixtures.t1),
                   SyncFixtures.subscription(id: b, name: "B2", updatedAt: SyncFixtures.t1),
                   SyncFixtures.subscription(id: c, name: "C2", updatedAt: SyncFixtures.t1)]
            remote.tombstones = [SyncFixtures.marker(.subscription, name: b.uuidString, at: SyncFixtures.t4)]
            return SyncMerge.plan(local: local, remote: remote, retentionCutoff: SyncFixtures.t5)
        }
        XCTAssertEqual(makePlan(shuffled: false), makePlan(shuffled: true))
    }

    /// 幂等的真命题：把这一趟的结论落回本机之后，再判一次必须是空计划。
    /// 这里模拟的是「本机已经变成应该变的样子」，云端那份一个字没动。
    func testSecondPassAfterApplyingThePlanIsEmpty() {
        let id = UUID()
        let icon = Data([0x01, 0x02])
        let checksum = CloudRecord.iconChecksum(of: icon)
        let deletedID = UUID()
        let deletedName = deletedID.uuidString

        var remote = RemoteSyncState()
        let incoming = SyncFixtures.subscription(id: id, name: "Netflix", updatedAt: SyncFixtures.t2,
                                                 icon: icon, iconChecksum: checksum)
        remote.subscriptions = [incoming,
                                SyncFixtures.subscription(id: deletedID, name: "旧账号", updatedAt: SyncFixtures.t1,
                                                          deletedAt: SyncFixtures.t1)]
        remote.events = [SyncFixtures.event(id: UUID(), subscriptionID: id, updatedAt: SyncFixtures.t2)]
        remote.settings = [CloudRecord(kind: .setting, name: SyncedSettingGroup.currency.recordName,
                                       updatedAt: SyncFixtures.t2, deletedAt: nil,
                                       payload: SyncedSettings(defaultCurrency: "CNY").encoded,
                                       icon: nil, iconChecksum: nil)]
        remote.tombstones = [SyncFixtures.marker(.subscription, name: deletedName, at: SyncFixtures.t1)]

        // 一台全新的设备：库里什么都没有，日志里也没有。
        // 保留期截点故意压在 t1 之前：这一条测的是「收到之后不再回推」，
        // 到期销毁另有测试管，两件事搅在一起就说不清是谁的责任了。
        let first = SyncMerge.plan(local: LocalSyncState(), remote: remote, retentionCutoff: SyncFixtures.t1)
        XCTAssertTrue(first.hasLocalWrites, "第一趟总得收到点东西")
        XCTAssertEqual(first.subscriptionsToApply.map(\.name), ["Netflix"], "已删除的那一条不能被当成新订阅收下来")

        // 落回本机：收到的那条按云端的时间收下（不重新盖自己的时间戳），
        // 云端那张删除凭据也进了本机日志，图标字节落了盘。
        var settled = LocalSyncState()
        settled.subscriptions = [incoming]
        settled.events = remote.events
        settled.settings = remote.settings
        settled.subscriptionTombstones = [deletedName: SyncFixtures.t1]
        settled.iconFileNames = [id.uuidString: "\(id.uuidString).png"]

        let second = SyncMerge.plan(local: settled, remote: remote, retentionCutoff: SyncFixtures.t1)
        XCTAssertTrue(second.subscriptionsToApply.isEmpty)
        XCTAssertTrue(second.eventsToApply.isEmpty)
        XCTAssertTrue(second.settingsToApply.isEmpty)
        XCTAssertTrue(second.uploads.isEmpty, "刚收下的东西不能再当本机新改动推回去")
        XCTAssertTrue(second.subscriptionsToTrash.isEmpty)
        XCTAssertTrue(second.conflicts.isEmpty)
        XCTAssertTrue(second.iconsToFetch.isEmpty)
        XCTAssertTrue(second.tombstonesToRecord.isEmpty)
        XCTAssertTrue(second.cloudDeletions.isEmpty)
    }

    /// 云端那条读不出内容（坏 payload）：本机不动，但要报出来，不能悄悄丢掉。
    func testUndecodableRemoteRowIsReportedInsteadOfSilentlyDropped() {
        var remote = RemoteSyncState()
        remote.subscriptions = [CloudRecord(kind: .subscription, name: UUID().uuidString,
                                            updatedAt: SyncFixtures.t2, deletedAt: nil,
                                            payload: Data("not json".utf8), icon: nil, iconChecksum: nil)]
        let plan = SyncMerge.plan(local: LocalSyncState(), remote: remote, retentionCutoff: SyncFixtures.t3)
        XCTAssertEqual(plan.conflicts.count, 1)
        XCTAssertTrue(plan.subscriptionsToApply.isEmpty)
    }

    /// 名字为空的坏行不能连累同批正常的那些：它不进库，其余照常收下。
    func testBadRowDoesNotAbortTheRestOfTheBatch() {
        let good = UUID(), bad = UUID()
        var local = LocalSyncState()
        var remote = RemoteSyncState()
        remote.subscriptions = [SyncFixtures.subscription(id: bad, name: "   ", updatedAt: SyncFixtures.t2),
                                SyncFixtures.subscription(id: good, name: "Netflix", updatedAt: SyncFixtures.t2)]

        let plan = SyncMerge.plan(local: local, remote: remote, retentionCutoff: SyncFixtures.t3)
        XCTAssertEqual(plan.subscriptionsToApply.map(\.name), ["Netflix"])
        XCTAssertEqual(plan.conflicts.count, 1)
    }
}

/// 造两边状态用的固定时刻。全部写死：这些测试比的是先后关系，
/// 用 `Date()` 的话「同一刻」那几条就永远测不到。
enum SyncFixtures {
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    static let t1 = epoch.addingTimeInterval(60)
    static let t2 = epoch.addingTimeInterval(120)
    static let t3 = epoch.addingTimeInterval(180)
    static let t4 = epoch.addingTimeInterval(240)
    static let t5 = epoch.addingTimeInterval(300)

    static func subscriptionPayload(id: UUID, name: String, price: Int = 4500,
                                    updatedAt: Date = SyncFixtures.t1,
                                    deletedAt: Date? = nil,
                                    archivedAt: Date? = nil,
                                    iconFile: String? = nil) -> Data {
        var item = BackupSubscription(Subscription(id: id, name: name,
                                                   iconImageFile: iconFile ?? "\(id.uuidString).png",
                                                   priceMinorUnits: price))
        item.updatedAt = updatedAt
        item.deletedAt = deletedAt
        item.archivedAt = archivedAt
        return (try? JSONEncoder.backup.encode(item)) ?? Data()
    }

    static func subscription(id: UUID, name: String, updatedAt: Date,
                             price: Int = 4500,
                             deletedAt: Date? = nil,
                             icon: Data? = nil,
                             iconChecksum: String? = nil) -> CloudRecord {
        CloudRecord(kind: .subscription,
                    name: id.uuidString,
                    updatedAt: updatedAt,
                    deletedAt: deletedAt,
                    payload: subscriptionPayload(id: id, name: name, price: price,
                                                 updatedAt: updatedAt, deletedAt: deletedAt),
                    icon: icon,
                    iconChecksum: iconChecksum)
    }

    static func event(id: UUID, subscriptionID: UUID, updatedAt: Date, amount: Int = 4500) -> CloudRecord {
        let item = BackupEvent(SubscriptionEvent(id: id, subscriptionID: subscriptionID,
                                                 type: .charged, amountMinorUnits: amount,
                                                 currencyCode: "CNY", note: "", happenedAt: updatedAt))
        return CloudRecord(kind: .event, name: id.uuidString, updatedAt: updatedAt, deletedAt: nil,
                           payload: (try? JSONEncoder.backup.encode(item)) ?? Data(),
                           icon: nil, iconChecksum: nil)
    }

    static func markerName(_ kind: CloudRecordKind, name: String) -> String {
        SyncTombstoneMarker(kind: kind, name: name, deletedAt: .distantPast).recordName
    }

    static func marker(_ kind: CloudRecordKind, name: String, at: Date) -> SyncTombstoneMarker {
        SyncTombstoneMarker(kind: kind, name: name, deletedAt: at)
    }

    static func decode(_ data: Data?) -> BackupSubscription? {
        guard let data else { return nil }
        return try? JSONDecoder.backup.decode(BackupSubscription.self, from: data)
    }
}
