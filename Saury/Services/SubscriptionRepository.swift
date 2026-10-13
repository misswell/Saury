import Foundation
import SwiftData

/// 订阅写入的唯一入口（任务书 §2.3）。
///
/// 之前每个页面自己 `insert` / `delete` / 改字段，最后把落盘交给 SwiftData 的自动保存：
/// 赌赢了没人知道，赌输了页面早就关了，用户以为记上了、其实没有。
/// 现在校验、写库、错误上抛、变更通知只在这一处做，调用方只面对 `throws`：
/// 抛了就说明这次没写进去，页面必须留在原地告诉用户，不许当作成功。
@MainActor
struct SubscriptionRepository {
    let context: ModelContext
    /// 删除凭据的账本。彻底删除要往里记一笔，重新写进同一条要把那一笔抹掉 ——
    /// 同步靠它判断「这条是被判过死刑的，还是别人手上还活着的那条」。
    let tombstones: SyncTombstoneLog
    /// 图标文件所在的那个目录。彻底删除时由这里决定某张图还能不能留在磁盘上。
    let icons: IconImageStore

    /// 默认走全局那本账；测试里给一个跟着假 `UserDefaults` 走的，才不会把
    /// 墓碑写到别的用例那边去。`icons` 同一个道理，给一个临时目录，
    /// 单元测试就不会去动真的那份图标缓存。
    init(context: ModelContext, tombstones: SyncTombstoneLog? = nil, icons: IconImageStore? = nil) {
        self.context = context
        self.tombstones = tombstones ?? .shared
        self.icons = icons ?? .shared
    }

    // MARK: - 错误与撤销凭据

    enum Failure: LocalizedError, Equatable {
        case nameRequired
        case notStored(String)
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .nameRequired: return "订阅名称不能为空"
            case .notStored(let what): return "「\(what)」已经不在库里，这次改动没保存"
            case .saveFailed(let reason): return "保存失败：\(reason)"
            }
        }
    }

    /// 改状态之前的样子。「撤销」就是把它原样写回去，
    /// 所以「归档过 → 进回收站 → 撤销」回到的是归档列表，不是订阅列表。
    struct StatusSnapshot: Equatable {
        let subscriptionID: UUID
        var pinnedAt: Date?
        var archivedAt: Date?
        var deletedAt: Date?
        /// 停用也在这个快照里。不带 `state` 的话「撤销停用」就没有原样可回，
        /// 只能靠猜一个「启用 = 改回自动续费」——那会把手动续费的那条悄悄改成自动。
        var state: SubscriptionState

        init(_ subscription: Subscription) {
            self.subscriptionID = subscription.id
            self.pinnedAt = subscription.pinnedAt
            self.archivedAt = subscription.archivedAt
            self.deletedAt = subscription.deletedAt
            self.state = subscription.state
        }
    }

    // MARK: - 新增与编辑

    /// 按 `draft.id` upsert：库里已有同一行就整字段覆盖，没有才新建。
    /// 表单连点两次保存走的是同一条路径，因此不会产生两份订阅。
    @discardableResult
    func apply(_ draft: SubscriptionDraft) throws -> Subscription {
        let name = draft.trimmedName
        guard !name.isEmpty else { throw Failure.nameRequired }

        let existing = subscription(id: draft.id)
        let isNew = existing == nil
        let subscription = existing ?? {
            let made = Subscription(id: draft.id, name: name)
            context.insert(made)
            return made
        }()
        write(draft, into: subscription)
        subscription.markUpdated()
        pardonIfAlive(subscription)
        try commitStrict("\(isNew ? "新增" : "编辑")订阅「\(name)」")
        return subscription
    }

    /// 新建和编辑共用这一份字段表，避免出现「编辑漏了个字段」那类 bug。
    private func write(_ draft: SubscriptionDraft, into subscription: Subscription) {
        subscription.name = draft.trimmedName
        subscription.plan = draft.trimmedPlan
        subscription.iconSymbolName = draft.iconSymbolName
        subscription.iconImageFile = draft.iconImageFile
        subscription.iconColorHex = draft.iconColorHex
        subscription.colorSpec = draft.colorSpec
        subscription.priceMinorUnits = max(draft.priceMinorUnits, 0)
        subscription.currencyCode = draft.currencyCode
        subscription.cycle = draft.cycle
        subscription.customMonths = max(draft.customMonths, 1)
        subscription.categoryRawValue = draft.category
        subscription.state = draft.state
        subscription.startDate = draft.startDate
        subscription.endDate = draft.endDate
        subscription.remindersEnabled = draft.remindersEnabled
        subscription.reminderDays = draft.reminderDays
        subscription.shareEnabled = draft.shareEnabled
        subscription.shareHeadcount = max(draft.shareHeadcount, 1)
        subscription.shareMode = draft.shareMode
        subscription.shareMyMinorUnits = max(draft.shareMyMinorUnits, 0)
        subscription.paymentMethod = draft.paymentMethod
        subscription.notes = draft.trimmedNotes
    }

    // MARK: - 置顶 / 归档 / 回收站

    @discardableResult
    func setPinned(_ subscription: Subscription, _ pinned: Bool) throws -> StatusSnapshot {
        let before = StatusSnapshot(subscription)
        try requireStored(subscription)
        subscription.pinnedAt = pinned ? Date() : nil
        subscription.markUpdated()
        try commitStrict("\(pinned ? "置顶" : "取消置顶")「\(subscription.name)」")
        return before
    }

    @discardableResult
    func archive(_ subscription: Subscription) throws -> StatusSnapshot {
        let before = StatusSnapshot(subscription)
        try requireStored(subscription)
        subscription.archivedAt = Date()
        subscription.markUpdated()
        try commitStrict("归档「\(subscription.name)」")
        return before
    }

    @discardableResult
    func unarchive(_ subscription: Subscription) throws -> StatusSnapshot {
        let before = StatusSnapshot(subscription)
        try requireStored(subscription)
        subscription.archivedAt = nil
        subscription.markUpdated()
        try commitStrict("从归档恢复「\(subscription.name)」")
        return before
    }

    /// 改续费方式 / 停用 / 启用。状态不是装饰：`isTracked`、`BillingMath` 的下次扣费、
    /// 提醒排班和统计都按它当真判，所以这一脚和置顶同等待遇 —— 同一份快照、同一次落盘。
    /// 这里**不**提供「启用就是改回自动续费」那种猜测，调用方必须说要成哪一个状态。
    @discardableResult
    func setState(_ subscription: Subscription, _ state: SubscriptionState) throws -> StatusSnapshot {
        let before = StatusSnapshot(subscription)
        try requireStored(subscription)
        subscription.state = state
        subscription.markUpdated()
        try commitStrict("「\(subscription.name)」改为\(state.title)")
        return before
    }

    @discardableResult
    func setState(_ subscriptions: [Subscription], _ state: SubscriptionState) throws -> [StatusSnapshot] {
        try requireStoredAll(subscriptions)
        let before = subscriptions.map(StatusSnapshot.init)
        for subscription in subscriptions {
            subscription.state = state
            subscription.markUpdated()
        }
        try commitStrict("\(subscriptions.count) 条订阅改为\(state.title)")
        return before
    }

    /// 软删除：进回收站，历史事件一条不动。
    @discardableResult
    func moveToTrash(_ subscription: Subscription) throws -> StatusSnapshot {
        let before = StatusSnapshot(subscription)
        try requireStored(subscription)
        subscription.deletedAt = Date()
        subscription.markUpdated()
        try commitStrict("移入回收站「\(subscription.name)」")
        return before
    }

    /// 只清删除标记：原本归档的仍回归档列表，撤销不该顺手改它的位置。
    @discardableResult
    func restoreFromTrash(_ subscription: Subscription) throws -> StatusSnapshot {
        let before = StatusSnapshot(subscription)
        try requireStored(subscription)
        subscription.deletedAt = nil
        subscription.markUpdated()
        // 用户亲手把它从回收站捞回来 = 比删除凭据更近的意图：那张死刑凭据作废，
        // 下一次同步这条才允许作为活记录推上去（见 SyncMerge 的作废规则）。
        pardonIfAlive(subscription)
        try commitStrict("从回收站恢复「\(subscription.name)」")
        return before
    }

    /// 撤销的落点：把状态按快照原样写回去。
    func restore(_ snapshot: StatusSnapshot) throws {
        guard let subscription = subscription(id: snapshot.subscriptionID) else {
            throw Failure.notStored("这条订阅")
        }
        subscription.pinnedAt = snapshot.pinnedAt
        subscription.archivedAt = snapshot.archivedAt
        subscription.deletedAt = snapshot.deletedAt
        subscription.state = snapshot.state
        subscription.markUpdated()
        pardonIfAlive(subscription)
        try commitStrict("撤销状态变更「\(subscription.name)」")
    }

    /// 整批撤销：一次落盘，不做 N 次保存。
    func restore(_ snapshots: [StatusSnapshot]) throws {
        for snapshot in snapshots {
            guard let subscription = subscription(id: snapshot.subscriptionID) else {
                throw Failure.notStored("这条订阅")
            }
            subscription.pinnedAt = snapshot.pinnedAt
            subscription.archivedAt = snapshot.archivedAt
            subscription.deletedAt = snapshot.deletedAt
            subscription.state = snapshot.state
            subscription.markUpdated()
            pardonIfAlive(subscription)
        }
        try commitStrict("撤销 \(snapshots.count) 条订阅的状态变更")
    }

    // MARK: - 批量

    /// 批量操作一次落盘，返回每条改动前的状态：整批撤销用的就是这份快照。
    @discardableResult
    func setPinned(_ subscriptions: [Subscription], _ pinned: Bool) throws -> [StatusSnapshot] {
        try requireStoredAll(subscriptions)
        let before = subscriptions.map(StatusSnapshot.init)
        for subscription in subscriptions {
            subscription.pinnedAt = pinned ? Date() : nil
            subscription.markUpdated()
        }
        try commitStrict("\(pinned ? "置顶" : "取消置顶") \(subscriptions.count) 条订阅")
        return before
    }

    @discardableResult
    func archive(_ subscriptions: [Subscription]) throws -> [StatusSnapshot] {
        try requireStoredAll(subscriptions)
        let before = subscriptions.map(StatusSnapshot.init)
        for subscription in subscriptions {
            subscription.archivedAt = Date()
            subscription.markUpdated()
        }
        try commitStrict("归档 \(subscriptions.count) 条订阅")
        return before
    }

    @discardableResult
    func moveToTrash(_ subscriptions: [Subscription]) throws -> [StatusSnapshot] {
        try requireStoredAll(subscriptions)
        let before = subscriptions.map(StatusSnapshot.init)
        for subscription in subscriptions {
            subscription.deletedAt = Date()
            subscription.markUpdated()
        }
        try commitStrict("移入回收站 \(subscriptions.count) 条订阅")
        return before
    }

    @discardableResult
    func unarchive(_ subscriptions: [Subscription]) throws -> [StatusSnapshot] {
        try requireStoredAll(subscriptions)
        let before = subscriptions.map(StatusSnapshot.init)
        for subscription in subscriptions {
            subscription.archivedAt = nil
            subscription.markUpdated()
        }
        try commitStrict("从归档恢复 \(subscriptions.count) 条订阅")
        return before
    }

    /// 整批从回收站捞回来：和单条一样，每一条的删除凭据跟着作废。
    @discardableResult
    func restoreFromTrash(_ subscriptions: [Subscription]) throws -> [StatusSnapshot] {
        try requireStoredAll(subscriptions)
        let before = subscriptions.map(StatusSnapshot.init)
        for subscription in subscriptions {
            subscription.deletedAt = nil
            subscription.markUpdated()
            pardonIfAlive(subscription)
        }
        try commitStrict("从回收站恢复 \(subscriptions.count) 条订阅")
        return before
    }

    // MARK: - 彻底删除

    /// 连同它的事件一起删：只删订阅会留下一堆没有主人的扣费记录，
    /// 账本把它们当孤儿丢掉后，用户看到的「累计支付」就凭空少一块。
    func deletePermanently(_ subscription: Subscription) throws {
        try requireStored(subscription)
        let name = subscription.name
        let targetID = subscription.id
        let iconFile = subscription.iconImageFile
        let related = (try? context.fetch(FetchDescriptor<SubscriptionEvent>(
            predicate: #Predicate { $0.subscriptionID == targetID }
        ))) ?? []
        let eventIDs = related.map(\.id)
        related.forEach(context.delete)
        context.delete(subscription)
        try commitStrict("彻底删除「\(name)」")
        // 凭据要等落盘成功才记：先记后写的话，一旦这次删除没成，库里那条还活着，
        // 手上却已经多了一张死刑凭据 —— 下一次同步会把它按进回收站，
        // 「没成功的删除」就变成了真删除。
        // 记在提交之后也不迟到：这里到下一行之间没有任何挂起点，
        // 提交时广播出去的那次同步只能排在本次执行之后才开始。
        let deletedAt = Date()
        tombstones.record(kind: .subscription, name: targetID.uuidString, at: deletedAt)
        eventIDs.forEach { tombstones.record(kind: .event, name: $0.uuidString, at: deletedAt) }
        if let iconFile { releaseIconFiles(named: [iconFile]) }
    }

    /// 整批彻底删除：一次落盘。逐条调上面那个方法会广播 N 次「数据变了」，
    /// 提醒队列和小组件就跟着重排 N 轮。
    func deletePermanently(_ subscriptions: [Subscription]) throws {
        try requireStoredAll(subscriptions)
        var eventIDs: [UUID] = []
        let subscriptionIDs = subscriptions.map(\.id)
        let iconFiles = subscriptions.compactMap(\.iconImageFile)
        for subscription in subscriptions {
            let targetID = subscription.id
            let related = (try? context.fetch(FetchDescriptor<SubscriptionEvent>(
                predicate: #Predicate { $0.subscriptionID == targetID }
            ))) ?? []
            eventIDs += related.map(\.id)
            related.forEach(context.delete)
            context.delete(subscription)
        }
        try commitStrict("彻底删除 \(subscriptions.count) 条订阅和 \(eventIDs.count) 条事件")
        let deletedAt = Date()
        subscriptionIDs.forEach { tombstones.record(kind: .subscription, name: $0.uuidString, at: deletedAt) }
        eventIDs.forEach { tombstones.record(kind: .event, name: $0.uuidString, at: deletedAt) }
        releaseIconFiles(named: iconFiles)
    }

    /// 「清空数据」：整库一次清完，失败必须让页面知道。
    /// 每一条都留下删除凭据，否则别的设备手上那份会在下一次同步原样爬回来。
    func wipeAll() throws {
        let events = (try? context.fetch(FetchDescriptor<SubscriptionEvent>())) ?? []
        let subscriptions = (try? context.fetch(FetchDescriptor<Subscription>())) ?? []
        let subscriptionIDs = subscriptions.map(\.id)
        let eventIDs = events.map(\.id)
        let iconFiles = subscriptions.compactMap(\.iconImageFile)
        events.forEach(context.delete)
        subscriptions.forEach(context.delete)
        try commitStrict("清空 \(subscriptions.count) 条订阅和 \(events.count) 条事件")
        let deletedAt = Date()
        subscriptionIDs.forEach { tombstones.record(kind: .subscription, name: $0.uuidString, at: deletedAt) }
        eventIDs.forEach { tombstones.record(kind: .event, name: $0.uuidString, at: deletedAt) }
        releaseIconFiles(named: iconFiles)
    }

    // MARK: - 回收站到期

    /// 回收站里已经满保留期、可以彻底清除的那几条（任务书 §10.6）。
    ///
    /// 「按日历天」这件事 `#Predicate` 里做不了（它要的是把两个时间各自削到零点再数天数），
    /// 所以库里只筛「在回收站里」，到期判断交给 `TrashPolicy`。
    /// 排序按删除时间从早到晚：`TrashJanitor` 要说「删了哪几条」，那个顺序得稳定。
    func expiredTrashRows(now: Date = Date()) -> [Subscription] {
        let rows = (try? context.fetch(FetchDescriptor<Subscription>(
            predicate: #Predicate { $0.deletedAt != nil }
        ))) ?? []
        return rows.filter { TrashPolicy.isDue(deletedAt: $0.deletedAt, now: now) }
            .sorted { ($0.deletedAt ?? .distantFuture) < ($1.deletedAt ?? .distantFuture) }
    }

    /// 图标文件的引用计数释放（§10.6「永久清理后的事件和图标处理规则必须一致」）。
    ///
    /// 事件一直是跟着订阅一起删的，图标以前一步都不做：彻底删除之后那张 PNG 继续躺在
    /// 磁盘上，用户看不见、也点不着，只有跑到「存储管理」手动清一次才会没。
    ///
    /// 不能拿到名字就删：App Store 搜来的图标按 trackId 存盘（`store(_:named:)`），
    /// 几条订阅共用同一张图是常规情况。只有「落盘之后库里再没有别条引用它」才许删文件 ——
    /// 回收站里躺着的那些也算还在引用，它们随时能被恢复。
    private func releaseIconFiles(named names: [String]) {
        let wanted = Set(names)
        guard wanted.isEmpty == false else { return }
        let remaining = Set(((try? context.fetch(FetchDescriptor<Subscription>())) ?? [])
            .compactMap(\.iconImageFile))
        for name in wanted where remaining.contains(name) == false {
            icons.delete(name)
        }
    }

    // MARK: - 事件

    /// 记一笔事件（扣费 / 调价 / 暂停 / 跳过 / 备注 / 内购）。
    /// 调价必须「改价 + 留痕」同一次落盘：只写成一半，后面的账就全对不上。
    @discardableResult
    func record(_ draft: SubscriptionEventDraft) throws -> SubscriptionEvent {
        let event = event(id: draft.id) ?? {
            let made = SubscriptionEvent(id: draft.id, subscriptionID: draft.subscriptionID, type: draft.type)
            context.insert(made)
            return made
        }()
        write(draft, into: event)

        var detail = draft.type.title
        if let subscription = subscription(id: draft.subscriptionID) {
            if draft.type == .priceChanged, draft.amountMinorUnits > 0 {
                subscription.priceMinorUnits = draft.amountMinorUnits
                detail += "「\(subscription.name)」现价改为 \(subscription.billAmount.amountText)"
            } else {
                detail += "「\(subscription.name)」"
            }
            subscription.markUpdated()
        } else {
            detail += "（找不到对应订阅 \(draft.subscriptionID.uuidString.prefix(8))）"
        }
        pardon(draft.id)
        try commitStrict(detail)
        return event
    }

    /// 把刚删掉的那条事件原样补回库 —— 撤销删除走这里，不走 `record`。
    ///
    /// 差别只有一处，但很要命：`record` 里带着「调价就把现价改掉」这一步。
    /// 删除本身没有动过现价，撤销自然也不该动 —— 补回来的那个价是当年那个数，
    /// 一旦删掉的不是最新那条调价，重放就会把现价盖回历史值。
    /// 和备份恢复同一条规矩：只写这条记录本身。
    @discardableResult
    func restore(_ draft: SubscriptionEventDraft) throws -> SubscriptionEvent {
        guard subscription(id: draft.subscriptionID) != nil else {
            throw Failure.notStored("这条订阅")
        }
        let event = self.event(id: draft.id) ?? {
            let made = SubscriptionEvent(id: draft.id, subscriptionID: draft.subscriptionID, type: draft.type)
            context.insert(made)
            return made
        }()
        write(draft, into: event)
        pardon(draft.id)
        try commitStrict("恢复一条\(draft.type.title)记录")
        return event
    }

    /// 事件草稿 → 行值。三处写入（记一笔、撤销删除、恢复/导入）共用这一份字段表。
    private func write(_ draft: SubscriptionEventDraft, into event: SubscriptionEvent) {
        event.type = draft.type
        event.amountMinorUnits = max(draft.amountMinorUnits, 0)
        event.currencyCode = draft.currencyCode
        event.note = draft.trimmedNote
        event.happenedAt = draft.happenedAt
    }

    func remove(_ event: SubscriptionEvent) throws {
        guard self.event(id: event.id) === event else { throw Failure.notStored(event.type.title) }
        let eventID = event.id
        context.delete(event)
        try commitStrict("删除一条\(event.type.title)记录")
        tombstones.record(kind: .event, name: eventID.uuidString, at: Date())
    }

    /// 事件当前的样子。删之前先拿一份，撤销就是按这一份补回同一行（`restore` 认稳定 id），
    /// 所以补回来的还是那一条，不会多出一条记录。
    func draft(of event: SubscriptionEvent) -> SubscriptionEventDraft {
        SubscriptionEventDraft(id: event.id,
                               subscriptionID: event.subscriptionID,
                               type: event.type,
                               amountMinorUnits: event.amountMinorUnits,
                               currencyCode: event.currencyCode,
                               note: event.note,
                               happenedAt: event.happenedAt)
    }

    // MARK: - 批量入库（导入、示例数据）

    /// 整批一次落盘：要么都记上，要么把错误原样告诉调用方。
    /// 安装 = 「这些订阅现在存在」的明确表态，它们身上的删除凭据（同一条曾经被
    /// 彻底删过）跟着作废，否则下一次同步会把刚装回来的那条按进回收站。
    func install(_ subscriptions: [Subscription]) throws {
        subscriptions.forEach(context.insert)
        subscriptions.forEach(pardonIfAlive)
        try commitStrict("导入 \(subscriptions.count) 条订阅")
    }

    func install(_ subscriptions: [Subscription], events: [SubscriptionEvent]) throws {
        subscriptions.forEach(context.insert)
        events.forEach(context.insert)
        subscriptions.forEach(pardonIfAlive)
        events.forEach { pardon($0.id) }
        try commitStrict("导入 \(subscriptions.count) 条订阅和 \(events.count) 条事件")
    }

    // MARK: - 备份恢复

    /// 恢复时「同一条订阅已经存在」怎么处理。
    enum RestoreMode: String, CaseIterable, Identifiable {
        /// 备份说了算：库里同一条整份覆盖成备份里的样子。
        /// 重复恢复同一份备份因此是幂等的，不会越恢复越多。
        case overwrite
        /// 本机说了算：库里已有这一条就原样留着，只补库里没有的。
        case keepExisting

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overwrite: return "备份优先"
            case .keepExisting: return "本机优先"
            }
        }

        var detail: String {
            switch self {
            case .overwrite:
                return "备份里有的订阅，本机同一条整个换成备份里的样子（含状态、时间与历史事件）。本机独有的不动。"
            case .keepExisting:
                return "本机已有的订阅一条都不改，只把备份里本机没有的补进来。"
            }
        }
    }

    /// 恢复写进去多少条。报给用户的就是这几个数，不许含糊成「恢复成功」。
    struct RestoreCounts: Equatable {
        var subscriptionsInserted = 0
        var subscriptionsUpdated = 0
        var subscriptionsSkipped = 0
        var eventsInserted = 0
        var eventsUpdated = 0
        var eventsSkipped = 0
    }

    /// 备份恢复的写入通道：按稳定 UUID 整批 upsert，一次落盘。
    ///
    /// 整体校验在写之前跑完：名字为空的行是坏行，整批不写、直接抛出去 ——
    /// 半途留下一半数据再告诉用户「恢复完成」，是任务书 §3.1 明令禁止的情形。
    /// 指向已经不存在的订阅的事件不进库：那种记录会让账本多出没有主人的支出，
    /// 但它不该连累同一批里正常的订阅，所以是记进 `eventsSkipped` 而不是 abort。
    func restore(rows: [(draft: SubscriptionDraft, status: BackupRow)],
                 events: [SubscriptionEventDraft],
                 mode: RestoreMode) throws -> RestoreCounts {
        var counts = RestoreCounts()
        for row in rows {
            guard !row.draft.trimmedName.isEmpty else { throw Failure.nameRequired }
        }

        for row in rows {
            let existing = subscription(id: row.draft.id)
            switch (existing, mode) {
            case (nil, _):
                let made = Subscription(id: row.draft.id, name: row.draft.trimmedName)
                context.insert(made)
                write(row.draft, into: made)
                apply(row.status, to: made)
                pardonIfAlive(made)
                counts.subscriptionsInserted += 1
            case (.some(let target), .overwrite):
                write(row.draft, into: target)
                apply(row.status, to: target)
                // 备份/iCloud 都把这条写成「活的」了，那张死刑凭据就该一起作废 ——
                // 判据同样是落库后的真实状态，回收站里躺着的那条不算。
                pardonIfAlive(target)
                counts.subscriptionsUpdated += 1
            case (.some, .keepExisting):
                counts.subscriptionsSkipped += 1
            }
        }

        for event in events {
            // 上一轮刚插进来的订阅要看得见，所以这里不缓存校验阶段的结果。
            guard subscription(id: event.subscriptionID) != nil else {
                counts.eventsSkipped += 1
                continue
            }
            let existing = self.event(id: event.id)
            // 恢复只写字段值，不重放「调价改现价」那套副作用：
            // 备份里的现价本来就是最新的，重等于把同一个数再推一遍，
            // 顺序一乱还会用旧事件覆盖掉新价格。
            let target = existing ?? {
                let made = SubscriptionEvent(id: event.id, subscriptionID: event.subscriptionID, type: event.type)
                context.insert(made)
                return made
            }()
            write(event, into: target)
            pardon(event.id)
            if existing == nil { counts.eventsInserted += 1 } else { counts.eventsUpdated += 1 }
        }

        try commitStrict("恢复 \(counts.subscriptionsInserted) 条新订阅、\(counts.subscriptionsUpdated) 条已有订阅")
        return counts
    }

    // MARK: - 交换格式导入

    /// 一次导入要写的东西。`draft` 由冲突解析器算好：
    /// 标成「更新」的那一份已经把本机原有、文件里没写的字段填回来了，
    /// 所以这里可以整字段覆盖，不会把用户三年没动的备注冲成空。
    struct ImportWrite {
        var draft: SubscriptionDraft
        /// 新增时才用；更新保留本机那条的创建时间。
        var createdAt: Date?
        var events: [SubscriptionEventDraft]
    }

    /// 导入的写入通道：新增插行、更新覆盖本机那一条，整批一次落盘。
    ///
    /// 写之前先整批校验：名字为空的行不写、整批抛出（同 `restore`）——
    /// 半途留下一半数据再说「导入完成」是不允许的。
    /// 空批次直接返回：一条都没写还广播「数据变了」，等于让提醒队列和小组件白跑一趟。
    func importRows(_ writes: [ImportWrite]) throws -> RestoreCounts {
        var counts = RestoreCounts()
        guard writes.isEmpty == false else { return counts }
        for entry in writes {
            guard entry.draft.trimmedName.isEmpty == false else { throw Failure.nameRequired }
        }

        for entry in writes {
            let existing = subscription(id: entry.draft.id)
            if let target = existing {
                write(entry.draft, into: target)
                target.markUpdated()
                pardonIfAlive(target)
                counts.subscriptionsUpdated += 1
            } else {
                let made = Subscription(id: entry.draft.id, name: entry.draft.trimmedName)
                context.insert(made)
                write(entry.draft, into: made)
                made.createdAt = entry.createdAt ?? Date()
                made.markUpdated()
                pardonIfAlive(made)
                counts.subscriptionsInserted += 1
            }
        }

        for entry in writes {
            guard subscription(id: entry.draft.id) != nil else { continue }
            for event in entry.events {
                // 「更新」那一份草稿可能换了归属写法，事件一律按最终落库的订阅 id 认领。
                var anchored = event
                anchored.subscriptionID = entry.draft.id
                let existing = self.event(id: anchored.id)
                let target = existing ?? {
                    let made = SubscriptionEvent(id: anchored.id,
                                                 subscriptionID: anchored.subscriptionID,
                                                 type: anchored.type)
                    context.insert(made)
                    return made
                }()
                // 和恢复一样不重放「调价改现价」：导入的现价就在草稿里，重放会按顺序覆盖成新值。
                write(anchored, into: target)
                pardon(anchored.id)
                if existing == nil { counts.eventsInserted += 1 } else { counts.eventsUpdated += 1 }
            }
        }

        try commitStrict("导入 \(counts.subscriptionsInserted) 条新订阅、\(counts.subscriptionsUpdated) 条已有订阅")
        return counts
    }

    /// 状态那一半单独写：`write(_:into:)` 是表单字段表，恢复的时间戳不属于它。
    /// 三个时间写的是备份里的原值，`updatedAt` 也一样照抄 ——
    /// 恢复不该把一条三年前的订阅变成「刚刚修改」。
    private func apply(_ status: BackupRow, to subscription: Subscription) {
        subscription.pinnedAt = status.pinnedAt
        subscription.archivedAt = status.archivedAt
        subscription.deletedAt = status.deletedAt
        subscription.sortOrder = status.sortOrder
        subscription.createdAt = status.createdAt
        subscription.updatedAt = status.updatedAt
    }

    // MARK: - 删除凭据

    /// 「这一条现在确实存在」的凭据清除。只有本机真的把一行写成活的时候才抹 ——
    /// 别的任何路径都不许撤墓碑，否则「删除不复活」这条规矩就白立了。
    /// 判据用落库后的真实状态，不写「这条草稿大概是活的」那种猜测。
    private func pardonIfAlive(_ subscription: Subscription) {
        guard subscription.deletedAt == nil else { return }
        tombstones.pardon(kind: .subscription, name: subscription.id.uuidString)
    }

    /// 事件没有「回收站」这一说，写进行里就是它存在。
    private func pardon(_ eventID: UUID) {
        tombstones.pardon(kind: .event, name: eventID.uuidString)
    }

    // MARK: - 落盘

    /// 唯一的 `save()` 出口。失败既写日志也上抛，由界面决定怎么告诉用户。
    /// 成功才发变更通知：通知会驱动提醒队列、小组件和同步，
    /// 写库没成功就广播一次，等于把没落盘的状态推给全设备。
    func commit(_ operation: String = "写入订阅数据") throws {
        do {
            try context.save()
        } catch {
            SauryLog.saveFailed(operation, error)
            throw Failure.saveFailed(error.localizedDescription)
        }
        NotificationCenter.default.post(name: .sauryDataChanged, object: nil)
    }

    /// 面向用户操作的提交：失败就把这批未落盘的改动整个撤掉。
    /// 不然界面上会留着一个「看起来改好了、其实没进库」的半成品，
    /// 用户下一次打开看到的是新值，数据却还是旧的。
    private func commitStrict(_ operation: String) throws {
        do {
            try commit(operation)
        } catch {
            context.rollback()
            throw error
        }
    }

    // MARK: - 读

    func subscription(id: UUID) -> Subscription? {
        (try? context.fetch(FetchDescriptor<Subscription>(
            predicate: #Predicate { $0.id == id }
        )))?.first
    }

    func event(id: UUID) -> SubscriptionEvent? {
        (try? context.fetch(FetchDescriptor<SubscriptionEvent>(
            predicate: #Predicate { $0.id == id }
        )))?.first
    }

    func events(subscriptionID: UUID) -> [SubscriptionEvent] {
        (try? context.fetch(FetchDescriptor<SubscriptionEvent>(
            predicate: #Predicate { $0.subscriptionID == subscriptionID }
        ))) ?? []
    }

    // MARK: - 校验

    /// 不属于当前库的对象（预览造出来的、别的 context 拿来的）改了也落不了盘，
    /// 与其假装成功不如直接报错。同一个库里同一行拿回来的是同一个实例，所以对得上。
    private func requireStored(_ subscription: Subscription) throws {
        guard self.subscription(id: subscription.id) === subscription else {
            throw Failure.notStored(subscription.name)
        }
    }

    private func requireStoredAll(_ subscriptions: [Subscription]) throws {
        for subscription in subscriptions { try requireStored(subscription) }
    }
}
