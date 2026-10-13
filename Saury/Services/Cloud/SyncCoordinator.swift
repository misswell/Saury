import Foundation
import SwiftData
import CloudKit
import Network
import os

/// 同步状态。顺序就是任务书 §4.2 要的那条链，一步都不能跳：
/// `idle → checkingAccount → fetching → merging → uploading → verifying → success / failed`
enum SyncPhase: Equatable {
    case idle
    case checkingAccount
    case fetching
    case merging
    case uploading
    case verifying
    case success(SyncReport)
    case failed(reason: String)

    var title: String {
        switch self {
        case .idle: return "没在同步"
        case .checkingAccount: return "在确认 iCloud 账户"
        case .fetching: return "在读云端"
        case .merging: return "在比对两边"
        case .uploading: return "在上传"
        case .verifying: return "在核对两边到底落没落下"
        case .success: return "刚刚同步完成"
        case .failed: return "同步没成"
        }
    }

    /// 正在做事的那几格。界面上用它的显示转圈。
    var isBusy: Bool {
        switch self {
        case .checkingAccount, .fetching, .merging, .uploading, .verifying: return true
        default: return false
        }
    }

    var report: SyncReport? { if case .success(let report) = self { return report } else { return nil } }
    var failure: String? { if case .failed(let reason) = self { return reason } else { return nil } }
}

/// 谁叫的同步。日志和「为什么突然转起来了」都靠它回答。
enum SyncReason: String, CaseIterable {
    /// 用户刚把「自动同步」打开
    case firstEnable
    /// 本机写了库（`SubscriptionRepository.commit` 的那一拍）
    case localChange
    /// 应用回到前台
    case foreground
    /// 页面上点了「立即同步」
    case manual
    /// 网络从离线恢复
    case networkRestored
    /// iCloud 账户状态变了（登录、退出、限制）
    case accountChanged

    /// 没开自动同步时，只有手点那一下值得真的动。
    var respectsAutoSwitch: Bool { self != .manual }
}

/// 云端现在的样子，来自最近一次真读到的清单。没读到过就是 nil —— 界面上写
/// 「这台设备还没读过云端」，不写 0：0 条和没读过是两件事。
struct RemoteCounts: Equatable {
    var subscriptions = 0
    var events = 0
    var tombstones = 0
}

/// 一次同步的账面结果。界面上报的就是这几个数，不许糊成一句「同步成功」。
struct SyncReport: Equatable {
    var remote = RemoteCounts()
    var appliedSubscriptions = 0
    var appliedEvents = 0
    /// 云端有、本机认领不到订阅的记录条数。它们不进库，但必须报出来。
    var skippedEvents = 0
    var appliedSettings = 0
    var trashed = 0
    var uploaded = 0
    var iconsRestored = 0
    /// 这一趟作废掉的删除凭据（本机这条被用户在回收站里捞回来了）。
    var revived = 0
    /// 这一趟从云端清掉的条数（到期销毁的凭据、它压着的记录、被作废的凭据）。
    var cloudCleared = 0
    /// 该清却没清掉的：本机日志留着，下一趟再试。
    var cloudCleanupDeferred = 0
    var conflicts = 0
    var finishedAt = Date()

    var summaryText: String {
        var lines = [
            "云端 \(remote.subscriptions) 条订阅、\(remote.events) 条记录、\(remote.tombstones) 张删除凭据。",
            """
            本机收下 \(appliedSubscriptions) 条订阅、\(appliedEvents) 条记录、\(appliedSettings) 组设置；\
            上传 \(uploaded) 条；按云端删除收进回收站 \(trashed) 条；补回图标 \(iconsRestored) 张。
            """,
        ]
        if skippedEvents > 0 {
            lines.append("另有 \(skippedEvents) 条云端记录找不到它属于哪条订阅，没进库。")
        }
        if revived > 0 {
            lines.append("有 \(revived) 张删除凭据被本机更新的一份作废掉了。")
        }
        if cloudCleared > 0 {
            lines.append("云端清掉 \(cloudCleared) 条（过期凭据、凭据压着的记录、作废的凭据）。")
        }
        if cloudCleanupDeferred > 0 {
            lines.append("有 \(cloudCleanupDeferred) 条该从云端清掉却没清成功，本机留着下次再试。")
        }
        if conflicts > 0 {
            lines.append("有 \(conflicts) 处两边不一致，谁都没盖谁，已原样留档。")
        }
        return lines.joined(separator: "\n")
    }
}

/// 同步的唯一入口（任务书 §4）。
///
/// 上一版的问题：开自动同步走的是不带 `ModelContext` 的 `syncNow()`，那个方法只在
/// 恰好拿到上下文时才合并和推送 —— 于是它查了一圈云端、把「上次同步」时间写上、
/// 报「已同步到 iCloud」，而本机一条数据都没动过。这一版从结构上堵死三件事：
/// 1. 协调器**必须**拿着一个 `ModelContainer` 才建得起来，每次同步自己开上下文；
/// 2. `success` 之前必须走完 `verifying`：服务端确认收下了上传的每一条，
///    且本机该落的行真的读得回来；
/// 3. 没有 iCloud 能力或账户不可用时落成 `failed`，「上次同步」时间一个字节都不写。
@MainActor
final class SyncCoordinator: ObservableObject {
    private static let logger = Logger(subsystem: "com.guofeng.saury", category: "cloud")

    static let autoSyncKey = "saury.cloudAutoSync"
    static let lastSyncKey = "saury.cloudLastSync"
    static let conflictKey = "saury.cloud.conflicts"
    private static let conflictLimit = 50

    @Published private(set) var phase: SyncPhase = .idle
    @Published private(set) var account: CloudAccountStatus = .unknown
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var conflicts: [SyncConflict] = []
    @Published private(set) var access: CloudAccess.Status
    @Published private(set) var remote: RemoteCounts?

    var autoSyncEnabled: Bool {
        get { defaults.bool(forKey: Self.autoSyncKey) }
        set {
            defaults.set(newValue, forKey: Self.autoSyncKey)
            // 打开的那一下就是 §4.2 里的「首次启用」：立刻跑一次完整的。
            if newValue { Task { await requestSync(reason: .firstEnable) } }
        }
    }

    private let container: ModelContainer
    private let preferences: SubPreferences
    private let defaults: UserDefaults
    private let tombstones: SyncTombstoneLog
    private let icons: IconImageStore
    private let store: CloudRecordStore?
    private var tokens: [NSObjectProtocol] = []
    private let pathMonitor = NWPathMonitor()
    private var triggersStarted = false
    private var networkWasDown = false

    /// 正在跑的那一次。一次写库可能连着广播十几拍，后面的不重开，攒着跑完再补一次。
    private var isRunning = false
    private var queued: [SyncReason] = []

    init(container: ModelContainer,
         preferences: SubPreferences,
         defaults: UserDefaults = .standard,
         access: CloudAccess.Status? = nil,
         store: CloudRecordStore? = nil,
         tombstones: SyncTombstoneLog? = nil,
         icons: IconImageStore = .shared,
         observesLocalChanges: Bool = false) {
        let resolved = access ?? CloudAccess.current
        self.access = resolved
        self.container = container
        self.preferences = preferences
        self.defaults = defaults
        self.tombstones = tombstones ?? SyncTombstoneLog(defaults: defaults)
        self.icons = icons
        self.store = store
        self.lastSuccess = defaults.object(forKey: Self.lastSyncKey) as? Date
        self.conflicts = Self.storedConflicts(in: defaults)
        if observesLocalChanges { startTriggers() }
    }

    /// 由 App 建那一个真的：能力探测 + CloudKit 搬运工。
    /// 探测不通过就**不给它搬运工**：后面的每一步都会诚实地报「没能力」，
    /// 而不是拿着一个会当场抛异常的 CKContainer 往下走。
    static func live(container: ModelContainer, preferences: SubPreferences) -> SyncCoordinator {
        let access = CloudAccess.current
        var store: CloudRecordStore?
        if case .ready(let identifier) = access {
            store = CloudKitRecordStore(containerIdentifier: identifier)
        }
        return SyncCoordinator(container: container,
                               preferences: preferences,
                               access: access,
                               store: store,
                               observesLocalChanges: true)
    }

    // MARK: - 状态机

    /// 三条往云端去的路（同步、以本机为准、修复图标）都必须先过这一关。
    /// 判两件事，因为它们各说一件：能力是签名给的，通道是探测通过之后才建得起来。
    /// 过不去就把缺的那句话原样端出来，「上次同步」时间一个字节都不写。
    private func readyStore() -> CloudRecordStore? {
        guard access.isReady, let store else {
            let detail = access.isReady ? "这个 App 没有可用的云端通道" : access.displayText
            phase = .failed(reason: "这台设备还没有 iCloud 能力：\(detail)")
            Self.logger.error("云端操作没启动（\(!self.access.isReady ? "无 iCloud 能力" : "无云端通道", privacy: .public)）：\(detail, privacy: .public)")
            return nil
        }
        return store
    }

    /// 唯一的同步入口。六个来源（首次启用、本机改动、回前台、手点、网络恢复、
    /// 账户变化）都走这里，不留任何自己偷偷并行的路径。
    func requestSync(reason: SyncReason) async {
        if isRunning {
            queued.append(reason)
            return
        }
        if reason.respectsAutoSwitch && autoSyncEnabled == false { return }

        guard let store = readyStore() else { return }

        isRunning = true
        defer {
            isRunning = false
            let pending = queued
            queued.removeAll()
            if let last = pending.last {
                Task { await self.requestSync(reason: last) }
            }
        }

        let context = ModelContext(container)
        Self.logger.info("同步开始（\(reason.rawValue, privacy: .public)）")

        phase = .checkingAccount
        do {
            account = try await store.accountStatus()
            guard account.isAvailable else {
                phase = .failed(reason: "iCloud 账户不可用：\(account.title)")
                return
            }

            phase = .fetching
            let remoteState = RemoteSyncState(subscriptions: try await store.index(of: .subscription),
                                              events: try await store.index(of: .event),
                                              settings: try await store.index(of: .setting),
                                              tombstones: try await store.index(of: .tombstone)
                                                  .compactMap { SyncTombstoneMarker($0.payload) })
            let counts = RemoteCounts(subscriptions: remoteState.subscriptions.count,
                                      events: remoteState.events.count,
                                      tombstones: remoteState.tombstones.count)
            remote = counts

            phase = .merging
            let cutoff = Date().addingTimeInterval(-SyncTombstoneLog.retention)
            let local = localState(context: context, stamp: nil)
            let plan = SyncMerge.plan(local: local, remote: remoteState, retentionCutoff: cutoff)
            let written = try await apply(plan, context: context, store: store)

            // 本机日志里的凭据抹掉：这一步在上传之前，否则刚作废的墓碑又被原样推回云端。
            for pointer in plan.revivedTombstones {
                tombstones.pardon(kind: pointer.kind, name: pointer.name)
            }

            phase = .uploading
            var uploads = plan.uploads
            uploads += plan.tombstonesToRecord.map { marker in
                CloudRecord(kind: .tombstone,
                            name: marker.recordName,
                            updatedAt: marker.deletedAt,
                            deletedAt: marker.deletedAt,
                            payload: marker.encoded,
                            icon: nil,
                            iconChecksum: nil)
            }
            uploads = attachIcons(to: uploads, local: local)
            let saved = try await store.save(uploads)
            for marker in plan.tombstonesToRecord {
                tombstones.record(kind: marker.kind, name: marker.name, at: marker.deletedAt)
            }

            // 到期凭据的销毁：云端确认删掉了才动本机日志。反过来做的话，
            // 云端还留着墓碑而本机不再知道这件事 —— 那条订阅就可能复活。
            var cloudCleanupDeferred = 0
            if plan.cloudDeletions.isEmpty == false {
                let confirmed = await deleteRemotely(plan.cloudDeletions, store: store)
                cloudCleanupDeferred = plan.cloudDeletions.count - confirmed.count
                if cloudCleanupDeferred == 0 {
                    let forgotten = tombstones.forgetExpired(before: cutoff)
                    if forgotten.isEmpty == false {
                        Self.logger.info("本机销毁了 \(forgotten.count, privacy: .public) 张到期删除凭据")
                    }
                }
            }

            phase = .verifying
            // 核对读的是服务端这次真正给了什么，不是「我叫了 save」。
            let savedNames = Set(saved.map(\.name))
            let missing = uploads.filter { savedNames.contains($0.name) == false }
            guard missing.isEmpty else {
                phase = .failed(reason: "云端没收下 \(missing.count) 条，本机数据一条没丢，下次同步再试")
                return
            }
            // 本机这一侧也要回读：写库没成功就不能算同步完成。
            let storedIDs = Set(try context.fetch(FetchDescriptor<Subscription>()).map { $0.id.uuidString })
            let unapplied = plan.subscriptionsToApply.map(\.id.uuidString)
                .filter { storedIDs.contains($0) == false }
            guard unapplied.isEmpty else {
                phase = .failed(reason: "云端那份读到了，可本机有 \(unapplied.count) 条没落进库，这次不算同步完成")
                return
            }

            let report = SyncReport(remote: counts,
                                    appliedSubscriptions: written.appliedSubscriptions,
                                    appliedEvents: written.appliedEvents,
                                    skippedEvents: written.skippedEvents,
                                    appliedSettings: written.appliedSettings,
                                    trashed: written.trashed,
                                    uploaded: uploads.count,
                                    iconsRestored: written.iconsRestored,
                                    revived: plan.revivedTombstones.count,
                                    cloudCleared: plan.cloudDeletions.count - cloudCleanupDeferred,
                                    cloudCleanupDeferred: cloudCleanupDeferred,
                                    conflicts: plan.conflicts.count,
                                    finishedAt: Date())
            lastSuccess = report.finishedAt
            defaults.set(report.finishedAt, forKey: Self.lastSyncKey)
            rememberConflicts(plan.conflicts)
            phase = .success(report)
            Self.logger.info("同步完成：\(report.summaryText.replacingOccurrences(of: "\n", with: "；"), privacy: .public)")
        } catch {
            // 上面每一步都在真的改本机或云端的状态，所以出错必须停在原地说明原因。
            // 尤其不能因为「查询云端成功了」就把 lastSuccess 往前推。
            let reason = error.localizedDescription
            phase = .failed(reason: reason)
            Self.logger.error("同步失败：\(reason, privacy: .public)")
        }
    }

    /// 「以本机为准」：这台设备上的每一条都打上最新时刻整包推上去，
    /// 别的设备多出来的东西不受影响。归档和删除状态一起照本机写 ——
    /// 这一条是任务书 §4.3 明确要求的（「归档与删除不能在云端恢复时清空」的反面）。
    func pushLocalAsSource() async {
        guard let store = readyStore() else { return }
        guard isRunning == false else { return }
        isRunning = true
        defer { isRunning = false }

        let context = ModelContext(container)
        let now = Date()
        phase = .uploading
        let local = localState(context: context, stamp: now)
        var uploads = local.subscriptions + local.events + local.settings + localTombstoneRecords(local)
        uploads = attachIcons(to: uploads, local: local)
        do {
            let saved = try await store.save(uploads)
            let savedNames = Set(saved.map(\.name))
            let missing = uploads.filter { savedNames.contains($0.name) == false }
            guard missing.isEmpty else {
                phase = .failed(reason: "云端只收下了 \(uploads.count - missing.count)/\(uploads.count) 条，剩下的下次再推")
                return
            }
            // 推上去的这份现在就是「最新」，四组偏好的改动时间也一起对齐到这一刻，
            // 否则下一轮合并会把它们判成本机没动过的旧值。
            for group in SyncedSettingGroup.allCases {
                preferences.recordSettingRevision(group, at: now)
            }
            lastSuccess = now
            defaults.set(now, forKey: Self.lastSyncKey)
            phase = .success(SyncReport(remote: remote ?? RemoteCounts(), uploaded: uploads.count, finishedAt: now))
        } catch {
            phase = .failed(reason: error.localizedDescription)
        }
    }

    /// 图标修复：本机丢了图（换机、清缓存、库被重建过）就按名字从云端取回来。
    func repairIcons() async {
        guard let store = readyStore() else { return }
        let context = ModelContext(container)
        let local = localState(context: context, stamp: nil)
        guard local.missingIconFiles.isEmpty == false else {
            phase = .success(SyncReport(remote: remote ?? RemoteCounts(), finishedAt: Date()))
            return
        }
        let wanted = local.missingIconFiles.keys.sorted().map {
            IconFetch(name: $0, fileName: local.missingIconFiles[$0] ?? "\($0).png", checksum: "")
        }
        do {
            // 这里没有云端声明的校验和（清单里才有），所以先取详情、按详情那份校验和自验。
            let records = try await store.records(of: .subscription, names: wanted.map(\.name))
            let restored = storeIcons(records: records, wanted: wanted)
            phase = .success(SyncReport(remote: remote ?? RemoteCounts(), iconsRestored: restored, finishedAt: Date()))
        } catch {
            phase = .failed(reason: error.localizedDescription)
        }
    }

    func refreshAccountStatus() async {
        guard let store else {
            account = .unknown
            return
        }
        account = (try? await store.accountStatus()) ?? .unknown
    }

    // MARK: - 触发源

    /// 生产路径才装：测试里假件也装的话，别的用例写一次库就会把这台「设备」叫醒，
    /// 测试结果就取决于谁先跑完 —— 那不再是测试。
    func startTriggers() {
        guard triggersStarted == false else { return }
        triggersStarted = true
        tokens.append(NotificationCenter.default.addObserver(
            forName: .sauryDataChanged, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await self.requestSync(reason: .localChange) }
        })
        tokens.append(NotificationCenter.default.addObserver(
            forName: Notification.Name.CKAccountChanged, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                await self.refreshAccountStatus()
                await self.requestSync(reason: .accountChanged)
            }
        })
        // 网络从断到通的那一下才叫一次：路径一直通着不该反复同步。
        // 状态存在 MainActor 的属性上而不是闭包捕获的局部变量里 ——
        // `pathUpdateHandler` 跑在监控队列上，抓一个可变局部变量在 Swift 6 下就是数据竞争。
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if satisfied, self.networkWasDown {
                    await self.requestSync(reason: .networkRestored)
                }
                self.networkWasDown = satisfied == false
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.guofeng.saury.cloud.path"))
    }

    func stopTriggers() {
        guard triggersStarted else { return }
        triggersStarted = false
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
        tokens = []
        pathMonitor.cancel()
    }

    // MARK: - 本机这一侧的清单

    /// 把库里的东西摆成和云端同一种形状。图标字节不在这里读 ——
    /// 只记文件名，真字节由 `attachIcons` 在上传前按需取。
    /// - Parameter stamp: 给「以本机为准」用的统一时刻；`nil` 表示各按自己库里的时间。
    private func localState(context: ModelContext, stamp: Date?) -> LocalSyncState {
        var state = LocalSyncState()
        let subscriptions = (try? context.fetch(FetchDescriptor<Subscription>())) ?? []
        let events = (try? context.fetch(FetchDescriptor<SubscriptionEvent>())) ?? []

        for subscription in subscriptions {
            let payload = BackupSubscription(subscription)
            let name = subscription.id.uuidString
            if let file = subscription.iconImageFile {
                if icons.exists(file) {
                    state.iconFileNames[name] = file
                } else {
                    state.missingIconFiles[name] = file
                }
            }
            state.subscriptions.append(CloudRecord(kind: .subscription,
                                                   name: name,
                                                   updatedAt: stamp ?? payload.updatedAt,
                                                   deletedAt: payload.deletedAt,
                                                   payload: encoded(payload),
                                                   icon: nil,
                                                   iconChecksum: nil))
        }
        for event in events {
            let payload = BackupEvent(event)
            state.events.append(CloudRecord(kind: .event,
                                            name: event.id.uuidString,
                                            // 事件身上没有「改动时间」这一列：加它要动 schema、
                                            // 要赌一次真实库迁移，赌错整个库打不开
                                            // （V4 的版本号和在用模型是同一份定义）。
                                            // 所以这里用发生时间当戳，内容不一致时不覆盖 —— 见 SyncMerge。
                                            updatedAt: stamp ?? payload.happenedAt,
                                            deletedAt: nil,
                                            payload: encoded(payload),
                                            icon: nil,
                                            iconChecksum: nil))
        }
        for group in SyncedSettingGroup.allCases {
            let content = SyncedSettings.current(for: group, from: preferences)
            state.settings.append(CloudRecord(kind: .setting,
                                              name: group.recordName,
                                              // 没盖过戳的组算「不可信」，合并时只填空、不盖。
                                              updatedAt: preferences.settingRevision(group) ?? .distantPast,
                                              deletedAt: nil,
                                              payload: content.encoded,
                                              icon: nil,
                                              iconChecksum: nil))
        }
        state.subscriptionTombstones = tombstones.entries(for: .subscription)
            .mapValues { Date(timeIntervalSince1970: $0) }
        state.eventTombstones = tombstones.entries(for: .event)
            .mapValues { Date(timeIntervalSince1970: $0) }
        return state
    }

    private func localTombstoneRecords(_ local: LocalSyncState) -> [CloudRecord] {
        var records: [CloudRecord] = []
        for (kind, log) in [(CloudRecordKind.subscription, local.subscriptionTombstones),
                            (.event, local.eventTombstones)] {
            records += log.map { name, date in
                let marker = SyncTombstoneMarker(kind: kind, name: name, deletedAt: date)
                return CloudRecord(kind: .tombstone, name: marker.recordName, updatedAt: date,
                                   deletedAt: date, payload: marker.encoded, icon: nil, iconChecksum: nil)
            }
        }
        return records
    }

    /// 上传前把图标字节装上。取不到字节就让它只有记录：
    /// 「本机的图丢了」这件事不能变成「假装传上去了」。
    private func attachIcons(to uploads: [CloudRecord], local: LocalSyncState) -> [CloudRecord] {
        uploads.map { record in
            guard record.kind == .subscription, let file = local.iconFileNames[record.name],
                  let data = icons.data(for: file) else { return record }
            var filled = record
            filled.icon = data
            filled.iconChecksum = CloudRecord.iconChecksum(of: data)
            return filled
        }
    }

    private func encoded<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder.backup.encode(value)) ?? Data()
    }

    // MARK: - 往本机写

    private struct WrittenCounts {
        var appliedSubscriptions = 0
        var appliedEvents = 0
        var skippedEvents = 0
        var appliedSettings = 0
        var trashed = 0
        var iconsRestored = 0
    }

    /// 落库走的是备份恢复那条已经测过的批量写入通道（`SubscriptionRepository.restore`）：
    /// 一次 `save()`、整批校验、孤儿事件按条跳过并计数 —— 同步不该另立一套写库规矩。
    private func apply(_ plan: SyncPlan,
                       context: ModelContext,
                       store: CloudRecordStore) async throws -> WrittenCounts {
        var written = WrittenCounts()
        guard plan.hasLocalWrites else { return written }

        var existing: [String: Subscription] = [:]
        for subscription in (try? context.fetch(FetchDescriptor<Subscription>())) ?? [] {
            existing[subscription.id.uuidString] = subscription
        }

        var rows: [(draft: SubscriptionDraft, status: BackupRow)] = []
        // 1) 远端更新的那几条：整字段照抄，归档 / 置顶 / 删除时间一个都不清空。
        for payload in plan.subscriptionsToApply {
            rows.append((payload.draft, payload.status))
        }
        // 2) 被远端删除压住的那几条：进回收站，时间戳对齐到删除那一刻。
        //    硬删不做 —— 「不删除现有用户数据」，而且回收站里用户自己还能看见、还能捞。
        for entry in plan.subscriptionsToTrash {
            guard let subscription = existing[entry.name] else { continue }
            var frozen = BackupSubscription(subscription)
            guard (frozen.deletedAt ?? .distantPast) < entry.deletedAt else { continue }
            frozen.deletedAt = entry.deletedAt
            frozen.updatedAt = max(frozen.updatedAt, entry.deletedAt)
            rows.append((frozen.draft, frozen.status))
            written.trashed += 1
        }

        // 3) 事件按自己的编号补：已有的一条都不动，所以同一个事件不会重复。
        let eventDrafts = plan.eventsToApply.map(\.draft)
        if rows.isEmpty == false || eventDrafts.isEmpty == false {
            let repository = SubscriptionRepository(context: context, tombstones: tombstones)
            let counts = try repository.restore(rows: rows, events: eventDrafts, mode: .overwrite)
            written.appliedSubscriptions = plan.subscriptionsToApply.count
            written.appliedEvents = counts.eventsInserted
            written.skippedEvents = counts.eventsSkipped
        }

        // 4) 设置：收下远端那份之后，把这组的「改动时间」写成远端的时间。
        //    不这么干的话，刚收下的东西会被算成本机新改动，下一轮又原样推回去 ——
        //    幂等就是在这一步断掉的。
        // 例外：这一版给偏好组加了列（提醒多了「要不要提醒」），旧载荷缺的那一列
        // 按旧语义补齐之后，本机这份和云端那份内容就不一样了（补齐 = 迁移，不是有人改了它）。
        // 保持远端时间戳的话，两边同一时刻各留一份内容，往后每次同步都报一次冲突；
        // 所以只在「真的对不齐」时重盖一个新鲜时间，让这一版往上推一次，两边就此对齐。
        for entry in plan.settingsToApply {
            entry.content.apply(to: preferences)
            let incoming = BackupContainer.sha256(entry.content.encoded)
            if SyncedSettings.fingerprint(entry.group, from: preferences) == incoming {
                preferences.recordSettingRevision(entry.group, at: entry.revisionAt)
            } else {
                preferences.recordSettingRevision(entry.group, at: Date())
                Self.logger.info("收下\(entry.group.title)时按旧语义补齐了缺的列，本机这份将推上云端一次")
            }
            written.appliedSettings += 1
        }

        // 5) 图标：按名字取回来，验过校验和才落盘。落盘只写文件，不动库，
        //    所以不需要再走一次提交。
        if plan.iconsToFetch.isEmpty == false {
            let records = try await store.records(of: .subscription, names: plan.iconsToFetch.map(\.name))
            written.iconsRestored = storeIcons(records: records, wanted: plan.iconsToFetch)
        }
        return written
    }

    /// 落盘并校验：校验和对不上的图不写，写进去的必须是云端那份原样。
    /// `wanted` 里的 checksum 为空表示「本机不知道该有什么」，只信云端那份自带的。
    private func storeIcons(records: [CloudRecord], wanted: [IconFetch]) -> Int {
        var restored = 0
        let byName = Dictionary(uniqueKeysWithValues: records.map { ($0.name, $0) })
        for entry in wanted {
            guard let record = byName[entry.name], let data = record.icon else { continue }
            guard CloudRecord.iconChecksum(of: data) == record.iconChecksum else { continue }
            guard entry.checksum.isEmpty || entry.checksum == record.iconChecksum else { continue }
            // 文件名是「<订阅 id>.png」这种稳定标识，落盘按原名，不产生第二份副本。
            if icons.restore(data, named: entry.fileName) { restored += 1 }
        }
        return restored
    }

    /// 逐类型删，返回服务端确认删掉的那些。没确认的那几条原样留着下次再试。
    private func deleteRemotely(_ items: [CloudDeletion],
                                store: CloudRecordStore) async -> Set<CloudDeletion> {
        var confirmed: Set<CloudDeletion> = []
        for kind in Set(items.map(\.kind)) {
            let names = items.filter { $0.kind == kind }.map(\.name)
            do {
                let deleted = try await store.delete(kind, names: names)
                let deletedNames = Set(deleted)
                confirmed = confirmed.union(items.filter { $0.kind == kind && deletedNames.contains($0.name) })
            } catch {
                Self.logger.error("云端删除失败（\(kind.cloudKitType, privacy: .public)）：\(error.localizedDescription, privacy: .public)")
            }
        }
        return confirmed
    }

    // MARK: - 冲突留档

    private static func storedConflicts(in defaults: UserDefaults) -> [SyncConflict] {
        guard let data = defaults.data(forKey: conflictKey),
              let decoded = try? JSONDecoder.backup.decode([StoredConflict].self, from: data) else { return [] }
        return decoded.map(\.conflict)
    }

    private func rememberConflicts(_ new: [SyncConflict]) {
        guard new.isEmpty == false else { return }
        // 同一对冲突不该每同步一次就多一条：按 id 去过重，只留最近这些。
        var merged = conflicts + new
        var seen = Set<String>()
        merged = merged.reversed().filter { seen.insert($0.id).inserted }.reversed()
        conflicts = Array(merged.suffix(Self.conflictLimit))
        if let data = try? JSONEncoder.backup.encode(conflicts.map(StoredConflict.init)) {
            defaults.set(data, forKey: Self.conflictKey)
        }
    }

    func clearConflictLog() {
        conflicts = []
        defaults.removeObject(forKey: Self.conflictKey)
    }
}

/// `SyncConflict` 里带的是 Date 和 Data，留档要有一套确定的编码，
/// 所以包一层 Codable 的形状。留档的意义在那份原始 JSON：
/// 想找回被覆盖前的样子，读它 —— 任务书 §4.3「不可判定时保留可恢复记录」。
struct StoredConflict: Codable, Equatable {
    let subject: SyncConflict.Subject
    let name: String
    let localUpdatedAt: Date
    let remoteUpdatedAt: Date
    let remotePayload: Data
    let note: String

    init(_ conflict: SyncConflict) {
        subject = conflict.subject
        name = conflict.name
        localUpdatedAt = conflict.localUpdatedAt
        remoteUpdatedAt = conflict.remoteUpdatedAt
        remotePayload = conflict.remotePayload
        note = conflict.note
    }

    var conflict: SyncConflict {
        SyncConflict(subject: subject, name: name, localUpdatedAt: localUpdatedAt,
                     remoteUpdatedAt: remoteUpdatedAt, remotePayload: remotePayload, note: note)
    }
}
