import Foundation

/// 同步的决定表：本机这一趟要传什么、要改什么、哪些冲突不能自动解决。
///
/// 整个文件不碰数据库、不碰网络、不碰 CloudKit，输入输出全是值。
/// 任务书 §4.3 那些要求 —— 删除不复活、幂等、事件按编号合并、冲突不许随机覆盖、
/// 不可判定时保留可恢复记录 —— 全在这里判，所以全部能用单元测试考。
/// `CloudKitRecordStore` 只是把这些决定搬给 iCloud 的搬运工。
struct LocalSyncState {
    var subscriptions: [CloudRecord] = []
    var events: [CloudRecord] = []
    var settings: [CloudRecord] = []
    /// 本地墓碑日志：彻底删除之后库里没行了，靠这里证明「这条被判过死刑」。
    var subscriptionTombstones: [String: Date] = [:]
    var eventTombstones: [String: Date] = [:]
    /// 订阅稳定名 → 磁盘上的图标文件名。上传时按它取字节。
    var iconFileNames: [String: String] = [:]
    /// 库里有 `iconImageFile`、磁盘上却没这张图（换机、清缓存、留底重建）。
    /// 云端要是有带校验和的同名图标，就从云端捞回来。
    var missingIconFiles: [String: String] = [:]
}

struct RemoteSyncState {
    var subscriptions: [CloudRecord] = []
    var events: [CloudRecord] = []
    var settings: [CloudRecord] = []
    var tombstones: [SyncTombstoneMarker] = []
}

/// 要从云端取回一张图标。带着文件名和云端声明的校验和：
/// 落盘前必须验过，验不过就不写 —— 「图标看着回来了其实是另一张图」不是修复。
struct IconFetch: Equatable {
    var name: String
    var fileName: String
    var checksum: String
}

/// 被云端墓碑压住的本机订阅：进回收站，不硬删（用户还能自己把它捞回来）。
struct TrashEntry: Equatable {
    var name: String
    var deletedAt: Date
}

/// 一组要从云端写回本机的偏好。`revisionAt` 是云端那份的改动时间，
/// 收下之后本机要把它当作这一组的改动时间记下来，否则下一轮会把自己刚收下的
/// 东西当成本机新改动原样推回去 —— 幂等就断在这里。
struct SettingUpdate: Equatable {
    var group: SyncedSettingGroup
    var content: SyncedSettings
    var revisionAt: Date
}

/// 云端要清掉的一条：墓碑本身，或它压着的那条记录。
struct CloudDeletion: Equatable, Hashable {
    var kind: CloudRecordKind
    var name: String
}

/// 一张删除凭据的位置：订阅和事件在同一张墓碑表里靠类型分开。
struct TombstonePointer: Equatable {
    var kind: CloudRecordKind
    var name: String
}

/// 一次「本机 vs 云端」的比对结果。
struct SyncPlan: Equatable {
    // 往本机写的
    var subscriptionsToApply: [BackupSubscription] = []
    /// 要把图标字节取回来的订阅。
    var iconsToFetch: [IconFetch] = []
    var subscriptionsToTrash: [TrashEntry] = []
    var eventsToApply: [BackupEvent] = []
    var settingsToApply: [SettingUpdate] = []

    // 往云端写的
    var uploads: [CloudRecord] = []
    /// uploads 里哪几条订阅要顺带把图标字节装上（协调器按文件名去磁盘取，取不到就只传记录）。
    var uploadIconNames: [String] = []
    /// 本次当成删除推上去的凭据：协调器要把它们补进本地墓碑日志。
    var tombstonesToRecord: [SyncTombstoneMarker] = []
    /// 墓碑过了保留期：连墓碑带它压着的那条记录一起从云端清掉。
    var cloudDeletions: [CloudDeletion] = []
    /// 被「活过来的那一条」作废掉的本地凭据（用户在回收站里把它捞回来了）。
    /// 不清的话这条订阅会被自己手里的证据一直按着，两边永远读出不一致的结论。
    var revivedTombstones: [TombstonePointer] = []

    // 要说出来的
    var conflicts: [SyncConflict] = []

    var hasLocalWrites: Bool {
        !subscriptionsToApply.isEmpty || !eventsToApply.isEmpty || !settingsToApply.isEmpty
            || !subscriptionsToTrash.isEmpty || !iconsToFetch.isEmpty
    }
}

/// 不可自动解决的冲突：同一时刻两边各写了一份不一样的，或者本机这条被远端删过。
/// 处理方式是**两边都不动**，把远端那一份原样留档报出来 —— 覆盖掉任何一边都是猜。
struct SyncConflict: Equatable, Identifiable {
    enum Subject: String, Codable {
        case subscription = "订阅"
        case event = "记录"
        case setting = "设置"
    }

    let subject: Subject
    let name: String
    let localUpdatedAt: Date
    let remoteUpdatedAt: Date
    /// 留档下来的远端那一份（订阅 / 事件 / 设置的原始 JSON），一个字节都不改。
    let remotePayload: Data
    let note: String

    var id: String { "\(subject.rawValue)-\(name)-\(remoteUpdatedAt.timeIntervalSince1970)" }
}

enum SyncMerge {
    /// 判一次。`retentionCutoff` = 「比这个时刻更早的删除凭据可以销毁」，测试里给定死的时刻。
    static func plan(local: LocalSyncState, remote: RemoteSyncState, retentionCutoff: Date) -> SyncPlan {
        var plan = SyncPlan()
        let remoteTombstones = Dictionary(uniqueKeysWithValues: remote.tombstones.map { ($0.recordName, $0) })

        mergeSubscriptions(local: keyed(local.subscriptions),
                           remote: keyed(remote.subscriptions),
                           localTombstones: local.subscriptionTombstones,
                           remoteTombstones: remoteTombstones,
                           iconFileNames: local.iconFileNames,
                           missingIcons: local.missingIconFiles,
                           into: &plan)
        mergeEvents(local: keyed(local.events),
                    remote: keyed(remote.events),
                    localTombstones: local.eventTombstones,
                    remoteTombstones: remoteTombstones,
                    into: &plan)
        mergeSettings(local: keyed(local.settings),
                      remote: keyed(remote.settings),
                      into: &plan)
        expire(kind: .subscription,
                local: local.subscriptionTombstones,
                remote: remoteTombstones,
                stillPresent: Set(local.subscriptions.map(\.name)),
                cutoff: retentionCutoff,
                into: &plan)
        expire(kind: .event,
               local: local.eventTombstones,
               remote: remoteTombstones,
               stillPresent: Set(local.events.map(\.name)),
               cutoff: retentionCutoff,
               into: &plan)
        normalize(&plan)
        return plan
    }

    /// 字典遍历顺序每次都不一样，而「这一趟和上一趟判得一样」是幂等要证的命题。
    /// 所以出的计划一律按稳定键排一遍：同一对状态两次算出来的计划逐字节可比。
    private static func normalize(_ plan: inout SyncPlan) {
        plan.subscriptionsToApply.sort { $0.id.uuidString < $1.id.uuidString }
        plan.eventsToApply.sort { $0.id.uuidString < $1.id.uuidString }
        plan.subscriptionsToTrash.sort { $0.name < $1.name }
        plan.iconsToFetch = unique(plan.iconsToFetch.sorted { ($0.name, $0.fileName) < ($1.name, $1.fileName) })
        plan.settingsToApply.sort { $0.group.rawValue < $1.group.rawValue }
        plan.uploads.sort { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
        plan.uploadIconNames = unique(plan.uploadIconNames.sorted())
        plan.tombstonesToRecord = unique(plan.tombstonesToRecord.sorted { $0.recordName < $1.recordName })
        plan.cloudDeletions = unique(plan.cloudDeletions.sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) })
        plan.revivedTombstones = unique(plan.revivedTombstones.sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) })
        plan.conflicts = unique(plan.conflicts.sorted { ($0.name, $0.subject.rawValue) < ($1.name, $1.subject.rawValue) })
    }

    /// 相邻去重：同一张图标既可能来自「远端更新」也可能来自「本机丢了重取」，
    /// 两次判定不该变成两次下载。列表已经排过序，重复项必然挨着。
    private static func unique<T: Equatable>(_ items: [T]) -> [T] {
        var kept: [T] = []
        for item in items where kept.last != item { kept.append(item) }
        return kept
    }

    private static func keyed(_ records: [CloudRecord]) -> [String: CloudRecord] {
        Dictionary(uniqueKeysWithValues: records.map { ($0.name, $0) })
    }

    // MARK: - 订阅

    /// 规则（任务书 §4.3）：
    /// 1. 有删除凭据且本机这份不比它新：删除赢，时间戳相等也算删除赢。
    ///    本机那条进回收站（还能捞），绝不作为活记录上传。
    /// 2. 本机这份确实更新（删过之后又改过、或在回收站里被恢复）：本机赢，
    ///    那张凭据跟着作废，并把这件事报出来 —— 悄悄复活和悄悄消失一样糟。
    /// 3. 没凭据：`updatedAt` 新的一方赢。
    /// 4. 时间戳相同而内容不同：不覆盖任何一边，留档报出来。
    /// 5. 云端没有这一条：本机这份传上去（第一次同步、新设备新增都走这里）。
    private static func mergeSubscriptions(local: [String: CloudRecord],
                                           remote: [String: CloudRecord],
                                           localTombstones: [String: Date],
                                           remoteTombstones: [String: SyncTombstoneMarker],
                                           iconFileNames: [String: String],
                                           missingIcons: [String: String],
                                           into plan: inout SyncPlan) {
        for name in Set(local.keys).union(remote.keys).union(localTombstones.keys) {
            let localRecord = local[name]
            let remoteRecord = remote[name]
            let tombstoneKey = markerKey(.subscription, name)
            /// 有没有一张「正式的死刑凭据」存在过：本地日志或云端墓碑任一处有就算。
            /// 只有云端记录上那个 deletedAt 字段的不算 —— 那多半是一次软删除，用户自己还能撤。
            let credentialExists = remoteTombstones[tombstoneKey] != nil || localTombstones[name] != nil
            let deletion = deleteStamp(name: name,
                                       localTombstones: localTombstones,
                                       remoteTombstones: remoteTombstones,
                                       remoteRecord: remoteRecord)
            let liveStamp = max(localRecord?.updatedAt ?? .distantPast, remoteRecord?.updatedAt ?? .distantPast)

            if let deletion, deletion >= liveStamp {
                // 删除赢了：本机这条还活着就先收进回收站，云端两边都留下死刑凭据。
                if let localRecord, localRecord.deletedAt == nil {
                    plan.subscriptionsToTrash.append(TrashEntry(name: name, deletedAt: deletion))
                }
                if remoteTombstones[tombstoneKey] == nil {
                    plan.tombstonesToRecord.append(SyncTombstoneMarker(kind: .subscription, name: name, deletedAt: deletion))
                }
                // 云端那条记录本身还写着「活着」的话，一并改成删掉的样子，
                // 免得出下一个人要一边靠墓碑、一边靠记录，两边读出不一致的结论。
                if let remoteRecord, remoteRecord.deletedAt == nil {
                    plan.uploads.append(deletedCopy(of: remoteRecord, at: deletion))
                }
                repairIcon(name: name,
                           missingIcons: missingIcons,
                           remoteRecord: remoteRecord,
                           into: &plan)
                continue
            }

            guard let localRecord else {
                // 本机没有这一条：新设备、或这条本来就在别的设备上建的。
                if let remoteRecord, let subscription = readableSubscription(from: remoteRecord.payload) {
                    plan.subscriptionsToApply.append(subscription)
                    if let checksum = remoteRecord.iconChecksum {
                        plan.iconsToFetch.append(IconFetch(name: name,
                                                            fileName: subscription.iconImageFile ?? "\(name).png",
                                                            checksum: checksum))
                    }
                    if subscription.deletedAt == nil {
                        voidDeletion(ifAny: deletion,
                                     name: name,
                                     tombstoneKey: tombstoneKey,
                                     localTombstones: localTombstones,
                                     remoteTombstones: remoteTombstones,
                                     into: &plan)
                    }
                } else if let remoteRecord {
                    plan.conflicts.append(SyncConflict(subject: .subscription,
                                                       name: name,
                                                       localUpdatedAt: .distantPast,
                                                       remoteUpdatedAt: remoteRecord.updatedAt,
                                                       remotePayload: remoteRecord.payload,
                                                       note: "云端这一条读不出内容，本机没有建它。"))
                }
                continue
            }

            guard let remoteRecord else {
                upload(localRecord, iconFileNames: iconFileNames, into: &plan)
                if localRecord.deletedAt == nil {
                    if credentialExists {
                        // 云端这一条已经不在了、只剩一张凭据：这一样是「本机把删过的东西带回来了」，
                        // 该说出来。报不报不该取决于云端那份记录本身还在不在。
                        revivalConflict(name: name, local: localRecord, remote: nil,
                                        deletion: deletion ?? localRecord.updatedAt, into: &plan)
                    }
                    voidDeletion(ifAny: deletion,
                                 name: name,
                                 tombstoneKey: tombstoneKey,
                                 localTombstones: localTombstones,
                                 remoteTombstones: remoteTombstones,
                                 into: &plan)
                }
                continue
            }

            if localRecord.updatedAt == remoteRecord.updatedAt {
                if localRecord.payload != remoteRecord.payload {
                    plan.conflicts.append(SyncConflict(subject: .subscription,
                                                       name: name,
                                                       localUpdatedAt: localRecord.updatedAt,
                                                       remoteUpdatedAt: remoteRecord.updatedAt,
                                                       remotePayload: remoteRecord.payload,
                                                       note: "两边在同一时刻各写了一份，谁都没盖掉谁：远端那一份已经原样留档。"))
                }
                repairIcon(name: name, missingIcons: missingIcons, remoteRecord: remoteRecord, into: &plan)
                continue
            }

            if remoteRecord.updatedAt > localRecord.updatedAt {
                if let subscription = readableSubscription(from: remoteRecord.payload) {
                    plan.subscriptionsToApply.append(subscription)
                    // 本机这份被远端盖掉，图标也得跟着换：按远端的校验和取回来。
                    if let checksum = remoteRecord.iconChecksum {
                        plan.iconsToFetch.append(IconFetch(name: name,
                                                            fileName: subscription.iconImageFile ?? "\(name).png",
                                                            checksum: checksum))
                    }
                    if subscription.deletedAt == nil {
                        voidDeletion(ifAny: deletion,
                                     name: name,
                                     tombstoneKey: tombstoneKey,
                                     localTombstones: localTombstones,
                                     remoteTombstones: remoteTombstones,
                                     into: &plan)
                    }
                } else {
                    plan.conflicts.append(SyncConflict(subject: .subscription,
                                                       name: name,
                                                       localUpdatedAt: localRecord.updatedAt,
                                                       remoteUpdatedAt: remoteRecord.updatedAt,
                                                       remotePayload: remoteRecord.payload,
                                                       note: "云端这一条读不出内容，本机的那份原样留着。"))
                }
            } else {
                upload(localRecord, iconFileNames: iconFileNames, into: &plan)
                if localRecord.deletedAt == nil {
                    if credentialExists {
                        // 「哪台设备永久删过它，这台设备之后又动了它」——策略是本机这份赢，
                        // 但这件事必须说出来：悄悄复活和悄悄消失一样糟。
                        // 单纯「软删除后又自己恢复」不算冲突，那本来就是回收站允许的
                        // （那种情况只会有记录上的 `deletedAt` 字段，没有正式凭据，`credentialExists` 为假）。
                        revivalConflict(name: name, local: localRecord, remote: remoteRecord,
                                        deletion: deletion ?? remoteRecord.updatedAt, into: &plan)
                    }
                    voidDeletion(ifAny: deletion,
                                 name: name,
                                 tombstoneKey: tombstoneKey,
                                 localTombstones: localTombstones,
                                 remoteTombstones: remoteTombstones,
                                 into: &plan)
                }
            }
        }
    }

    /// 「本机这一份比一张删除凭据还新」这件事要说出来：策略上本机赢，
    /// 但悄悄复活和悄悄消失一样糟。云端那一份若还在就原样留档；
    /// 只剩凭据、记录已经不在了的时候，留档没有原件可留，但这一样是同一件事，
    /// 报不报不该取决于云端那份记录本身还在不在。
    private static func revivalConflict(name: String,
                                        local: CloudRecord,
                                        remote: CloudRecord?,
                                        deletion: Date,
                                        into plan: inout SyncPlan) {
        plan.conflicts.append(SyncConflict(subject: .subscription,
                                           name: name,
                                           localUpdatedAt: local.updatedAt,
                                           remoteUpdatedAt: remote?.updatedAt ?? deletion,
                                           remotePayload: remote?.payload ?? Data(),
                                           note: remote == nil
                                            ? "云端这一条已经不在了，只留着一张删除凭据；本机这一份的时间比它新，所以按本机这份留下了，那张凭据已经作废。"
                                            : "云端留着一张这条订阅的删除凭据，本机这一份的时间比它新，所以按本机这份留下了；那张凭据已经作废。"))
    }

    /// 一条活着的订阅赢过了一张删除凭据 —— 也就是「用户在某台设备上把它从回收站
    /// 捞回来了，或在它被删之后又动过它」。作废要有凭据才作废得掉：
    /// 本机日志里那笔由本机抹（`revivedTombstones`），云端那张由这一次同步删掉。
    /// 不做这一步的话，恢复好的那条会被旧凭据一直按着，两边永远各说各话。
    private static func voidDeletion(ifAny deletion: Date?,
                                     name: String,
                                     tombstoneKey: String,
                                     localTombstones: [String: Date],
                                     remoteTombstones: [String: SyncTombstoneMarker],
                                     into plan: inout SyncPlan) {
        guard deletion != nil else { return }
        if localTombstones[name] != nil {
            plan.revivedTombstones.append(TombstonePointer(kind: .subscription, name: name))
        }
        if remoteTombstones[tombstoneKey] != nil {
            plan.cloudDeletions.append(CloudDeletion(kind: .tombstone, name: tombstoneKey))
        }
    }

    /// 删除时间的四个来源：本地墓碑、云端墓碑记录、云端记录的 `deletedAt` 列、
    /// payload 里那份 `deletedAt`。取最新的一个。
    private static func deleteStamp(name: String,
                                    localTombstones: [String: Date],
                                    remoteTombstones: [String: SyncTombstoneMarker],
                                    remoteRecord: CloudRecord?) -> Date? {
        var candidates: [Date] = []
        if let date = localTombstones[name] { candidates.append(date) }
        if let marker = remoteTombstones[markerKey(.subscription, name)] { candidates.append(marker.deletedAt) }
        if let date = remoteRecord?.deletedAt { candidates.append(date) }
        if let payload = remoteRecord?.payload, let subscription = decode(BackupSubscription.self, from: payload),
           let date = subscription.deletedAt {
            candidates.append(date)
        }
        return candidates.max()
    }

    /// 把一份记录复制成「已删除」的样子：payload 里的 `deletedAt` 一起写上，
    /// 免得云端出现「记录说还活着、墓碑说死了」这种两边都要猜的状态。
    private static func deletedCopy(of record: CloudRecord, at deletedAt: Date) -> CloudRecord {
        var copy = record
        copy.deletedAt = deletedAt
        copy.updatedAt = max(record.updatedAt, deletedAt)
        if var subscription = decode(BackupSubscription.self, from: record.payload) {
            subscription.deletedAt = deletedAt
            subscription.updatedAt = copy.updatedAt
            copy.payload = (try? JSONEncoder.backup.encode(subscription)) ?? record.payload
        }
        copy.icon = nil
        return copy
    }

    private static func upload(_ record: CloudRecord,
                               iconFileNames: [String: String],
                               into plan: inout SyncPlan) {
        plan.uploads.append(record)
        if iconFileNames[record.name] != nil { plan.uploadIconNames.append(record.name) }
    }

    /// 本机丢了图、云端有：按云端那条的校验和取回来验一遍再落盘。
    private static func repairIcon(name: String,
                                  missingIcons: [String: String],
                                  remoteRecord: CloudRecord?,
                                  into plan: inout SyncPlan) {
        guard let fileName = missingIcons[name], let checksum = remoteRecord?.iconChecksum else { return }
        plan.iconsToFetch.append(IconFetch(name: name, fileName: fileName, checksum: checksum))
    }

    // MARK: - 事件

    /// 事件按自己的编号合并：两边各自新增的都会到齐，同一个编号不重复。
    /// 云端没有 → 上传；本机没有 → 收下；两边都有但内容不同 → 谁都不覆盖、留档
    /// （事件身上的时间是「发生时间」，判不出哪一份是后来改的，那就都不动）。
    private static func mergeEvents(local: [String: CloudRecord],
                                    remote: [String: CloudRecord],
                                    localTombstones: [String: Date],
                                    remoteTombstones: [String: SyncTombstoneMarker],
                                    into plan: inout SyncPlan) {
        for name in Set(local.keys).union(remote.keys) {
            let markerKey = markerKey(.event, name)
            if localTombstones[name] != nil || remoteTombstones[markerKey] != nil {
                // 这条被哪一台删过了：不再上传。本机已有的一份不硬删，报出来由人决定。
                if local[name] != nil, remoteTombstones[markerKey] != nil {
                    plan.conflicts.append(SyncConflict(subject: .event,
                                                       name: name,
                                                       localUpdatedAt: local[name]?.updatedAt ?? .distantPast,
                                                       remoteUpdatedAt: remoteTombstones[markerKey]?.deletedAt ?? .distantPast,
                                                       remotePayload: Data(),
                                                       note: "另一台设备删掉了这条记录。本机这一条留着没动，也没有再上传。"))
                }
                continue
            }
            switch (local[name], remote[name]) {
            case (nil, let remoteRecord?):
                if let event = decode(BackupEvent.self, from: remoteRecord.payload) {
                    plan.eventsToApply.append(event)
                }
            case (let localRecord?, nil):
                plan.uploads.append(localRecord)
            case (let localRecord?, let remoteRecord?):
                if localRecord.payload != remoteRecord.payload {
                    plan.conflicts.append(SyncConflict(subject: .event,
                                                       name: name,
                                                       localUpdatedAt: localRecord.updatedAt,
                                                       remoteUpdatedAt: remoteRecord.updatedAt,
                                                       remotePayload: remoteRecord.payload,
                                                       note: "同一条记录两边内容不一样，谁都没盖谁：远端那一份已经原样留档。"))
                }
            case (nil, nil):
                continue
            }
        }
    }

    // MARK: - 偏好

    /// 一组一条记录，按 `updatedAt` 比。这个时间是「这组偏好上次被人动是什么时候」，
    /// 由 `SubPreferences` 在写这些键的时候盖。没盖过的（装机前就存在的旧值）算不可信：
    /// 不可信的那份**绝不往云端盖** —— 宁可不同步，不可猜着盖；
    /// 但云端那份若是唯一有凭据的，本机收下它（新设备靠这一条拿到分类和支付方式）。
    /// 两边都没凭据时谁都不动，只留档。
    private static func mergeSettings(local: [String: CloudRecord],
                                      remote: [String: CloudRecord],
                                      into plan: inout SyncPlan) {
        for group in SyncedSettingGroup.allCases {
            guard let localRecord = local[group.recordName] else { continue }
            let remoteRecord = remote[group.recordName]
            if localRecord.updatedAt == .distantPast {
                guard let remoteRecord else {
                    // 云端还没有这一组：本机这份虽然没盖过戳，填个空位是安全的。
                    plan.uploads.append(localRecord)
                    continue
                }
                if remoteRecord.updatedAt == .distantPast {
                    // 两边都没有凭据：谁都不盖，报出来。猜一份就是拿装机默认值盖用户挑过的设置。
                    if localRecord.payload != remoteRecord.payload {
                        plan.conflicts.append(SyncConflict(subject: .setting,
                                                           name: group.recordName,
                                                           localUpdatedAt: .distantPast,
                                                           remoteUpdatedAt: .distantPast,
                                                           remotePayload: remoteRecord.payload,
                                                           note: "\(group.title)两边都没有改动时间凭据，本机这份没动：云端那一份已经原样留档。"))
                    }
                    continue
                }
                // 本机这份没盖过戳（多半是刚装机的默认值），云端那份是唯一有凭据的：收下来。
                // 不这么处理的话，新设备永远同步不到分类和支付方式 —— 它一个戳都还没有。
                if let content = SyncedSettings(data: remoteRecord.payload) {
                    plan.settingsToApply.append(SettingUpdate(group: group, content: content,
                                                              revisionAt: remoteRecord.updatedAt))
                }
                continue
            }
            guard let remoteRecord else {
                plan.uploads.append(localRecord)
                continue
            }
            if remoteRecord.updatedAt > localRecord.updatedAt {
                if let content = SyncedSettings(data: remoteRecord.payload) {
                    plan.settingsToApply.append(SettingUpdate(group: group, content: content,
                                                              revisionAt: remoteRecord.updatedAt))
                }
            } else if localRecord.updatedAt > remoteRecord.updatedAt {
                plan.uploads.append(localRecord)
            } else if localRecord.payload != remoteRecord.payload {
                plan.conflicts.append(SyncConflict(subject: .setting,
                                                   name: group.recordName,
                                                   localUpdatedAt: localRecord.updatedAt,
                                                   remoteUpdatedAt: remoteRecord.updatedAt,
                                                   remotePayload: remoteRecord.payload,
                                                   note: "\(group.title)两边在同一时刻各改了一份，本机这份没动：远端那一份已经原样留档。"))
            }
        }
    }

    // MARK: - 保留期

    /// 墓碑到期：把墓碑本身和它压着的那条记录一起从云端清掉。
    /// 只清本机日志里过期的那批 —— 别人留下的凭据由留它的那台负责清，
    /// 别的设备不该替它决定什么时候销毁。
    ///
    /// 库里还留着这一条（回收站里躺着没删干净）的名字跳过：清了云端那份，本机这条
    /// 下一轮又会原样传回去，等于每张同步都白删白传一次。等它真被彻底删除再清。
    private static func expire(kind: CloudRecordKind,
                               local: [String: Date],
                               remote: [String: SyncTombstoneMarker],
                               stillPresent: Set<String>,
                               cutoff: Date,
                               into plan: inout SyncPlan) {
        for (name, date) in local where date < cutoff && stillPresent.contains(name) == false {
            let marker = SyncTombstoneMarker(kind: kind, name: name, deletedAt: date)
            if remote[marker.recordName] != nil {
                plan.cloudDeletions.append(CloudDeletion(kind: .tombstone, name: marker.recordName))
            }
            plan.cloudDeletions.append(CloudDeletion(kind: kind, name: name))
        }
    }

    private static func markerKey(_ kind: CloudRecordKind, _ name: String) -> String {
        SyncTombstoneMarker(kind: kind, name: name, deletedAt: .distantPast).recordName
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder.backup.decode(type, from: data)
    }

    /// 名字为空的订阅不能进库：`SubscriptionRepository` 整批校验时会因为它把
    /// 这一趟同步收到的东西全部退回。云端坏一条不该连累同批正常的那些，
    /// 所以这里就把它当「读不出内容」处理，本机不动、报出来。
    private static func readableSubscription(from data: Data) -> BackupSubscription? {
        guard let subscription = decode(BackupSubscription.self, from: data) else { return nil }
        return subscription.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : subscription
    }
}
