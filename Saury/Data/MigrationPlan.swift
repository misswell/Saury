import Foundation
import SwiftData

//
//  SwiftData 版本化 schema 与迁移计划（方案 §11）。
//  旧库里的数据必须原样出现在新模型里，不允许删库重来。
//

enum SaurySchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [RenewalItem.self, DecisionRecord.self] }
}

enum SaurySchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] { [ExpiryItem.self, ExpiryEvent.self] }
}

/// 方案 §28 的本地商品模板。只是多了一张表，老数据一行都不动，
/// 所以 V2 → V3 交给 SwiftData 的轻量迁移。
enum SaurySchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }
    static var models: [any PersistentModel.Type] { [ExpiryItem.self, ExpiryEvent.self, ProductTemplate.self] }
}

/// 期见改做订阅管理的这一版，也是当前版本。旧「物品」里只有分类为订阅的记录还有业务意义，
/// 其余（食品、药品……）在新产品里没有对应概念，迁移时不再带过来。
enum SaurySchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }
    static var models: [any PersistentModel.Type] { [Subscription.self, SubscriptionEvent.self] }
}

/// 这一版给 `Subscription` 多加了一列 `remindersEnabled`，但它**不是一条迁移阶段**，
/// 原因是实测撞出来的：`VersionedSchema.models` 只能列活着的类型，
/// V4 和「提醒显式模型之后那一版」列的是同一批 class，CoreData 拿到的两份模型一模一样，
/// 于是 `.custom(fromVersion: V4, toVersion: V5)` 在建 stage 的当场就抛
/// 「The current model reference and the next model reference cannot be equal」——
/// 装上老库的设备一进 App 就闪退。列本身交给 CoreData 的自动轻量迁移补上（新增一列是它能推出来的改动），
/// 而**每一行该开还是该关**由 `ReminderIntentBackfill` 在启动时补一次。
///
/// 回填按**用户当时看到的说法**下结论，不按调度器的行为：
/// 旧库里 `reminderDays == 0` 在新增页和详情页都写着「不提醒」。
enum SauryMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SaurySchemaV1.self, SaurySchemaV2.self, SaurySchemaV3.self, SaurySchemaV4.self] }

    static var stages: [MigrationStage] {
        [
            .custom(
                fromVersion: SaurySchemaV1.self,
                toVersion: SaurySchemaV2.self,
                willMigrate: { source in
                    let renewals = try source.fetch(FetchDescriptor<RenewalItem>()).map(LegacyRenewalSnapshot.init)
                    let decisions = try source.fetch(FetchDescriptor<DecisionRecord>()).map(LegacyDecisionSnapshot.init)
                    SauryMigrationHandoff.load(renewals: renewals, decisions: decisions)
                },
                didMigrate: { destination in
                    // 目标表已经有的 id 跳过：重复列会撞 @Attribute(.unique)，
                    // 那样整个容器起不来，等于把用户的旧数据锁死。
                    let existingItemIDs = Set(try destination.fetch(FetchDescriptor<ExpiryItem>()).map(\.id))
                    let existingEventIDs = Set(try destination.fetch(FetchDescriptor<ExpiryEvent>()).map(\.id))
                    for snapshot in SauryMigrationHandoff.renewals where !existingItemIDs.contains(snapshot.id) {
                        destination.insert(ExpiryItem(migratedFrom: snapshot))
                    }
                    for snapshot in SauryMigrationHandoff.decisions where !existingEventIDs.contains(snapshot.id) {
                        destination.insert(ExpiryEvent(migratedFrom: snapshot))
                    }
                    SauryMigrationHandoff.clear()
                    try destination.save()
                }
            ),
            .lightweight(fromVersion: SaurySchemaV2.self, toVersion: SaurySchemaV3.self),
            .custom(
                fromVersion: SaurySchemaV3.self,
                toVersion: SaurySchemaV4.self,
                willMigrate: { source in
                    let items = try source.fetch(FetchDescriptor<ExpiryItem>())
                    let snapshots = items.map(LegacyExpirySnapshot.init)
                    let events = try source.fetch(FetchDescriptor<ExpiryEvent>())
                    SauryMigrationHandoff.load(expiryItems: snapshots,
                                               expiryEvents: events.map(LegacyExpiryEventSnapshot.init))
                },
                didMigrate: { destination in
                    let existingIDs = Set(try destination.fetch(FetchDescriptor<Subscription>()).map(\.id))
                    let existingEventIDs = Set(try destination.fetch(FetchDescriptor<SubscriptionEvent>()).map(\.id))
                    // 已经存在的订阅同样算「活下来的」：它的事件照样要接上。
                    var survivingItemIDs = existingIDs
                    for snapshot in SauryMigrationHandoff.expiryItems where !existingIDs.contains(snapshot.id) {
                        guard let converted = Subscription(migratedFrom: snapshot) else { continue }
                        destination.insert(converted)
                        survivingItemIDs.insert(snapshot.id)
                    }
                    // 流水账跟着走：旧版每一次「已续期」「已取消」都是用户真实做过的决定，
                    // 只搬物品不搬历史等于把账本删了一半。认领不到订阅的事件才丢。
                    for snapshot in SauryMigrationHandoff.expiryEvents
                    where survivingItemIDs.contains(snapshot.itemID) && !existingEventIDs.contains(snapshot.id) {
                        destination.insert(SubscriptionEvent(migratedFrom: snapshot))
                    }
                    SauryMigrationHandoff.clearExpiryItems()
                    try destination.save()
                }
            ),
        ]
    }

    // MARK: - 字段映射（方案 §11）

    /// 旧周期 → 新重复规则。免费试用按月亮，保持「到期后继续推进」的旧行为；
    /// 关闭了自动续费等价于不再重复；一买一断的记录不再产生下一次。
    static func recurrence(for snapshot: LegacyRenewalSnapshot) -> (rule: ExpiryRecurrence, intervalMonths: Int?) {
        guard snapshot.isAutoRenewing else { return (.none, nil) }
        switch LegacyRenewalCycle(rawValue: snapshot.cycleRawValue) ?? .monthly {
        case .oneTime: return (.none, nil)
        case .monthly, .freeTrial: return (.monthly, nil)
        case .yearly: return (.yearly, nil)
        case .customMonths: return (.custom, max(snapshot.intervalMonths, 1))
        }
    }

    /// 旧状态 → 用户状态。paused 是「先别看它」，对应归档；expired 不入库，
    /// 由 ExpiryEngine 按天数实时判定，所以旧库里已到期的记录回到跟踪中。
    static func state(for snapshot: LegacyRenewalSnapshot) -> ExpiryState {
        switch LegacyRenewalStatus(rawValue: snapshot.statusRawValue) ?? .active {
        case .active, .expired: return .active
        case .paused: return .archived
        case .cancelled: return .cancelled
        }
    }

    /// 旧决定 → 事件类型。
    static func eventType(for snapshot: LegacyDecisionSnapshot) -> ExpiryEventType {
        switch LegacyDecisionAction(rawValue: snapshot.actionRawValue) ?? .snoozed {
        case .cancelled: return .cancelled
        case .continued: return .renewed
        case .paused: return .archived
        case .snoozed: return .snoozed
        }
    }

    /// V3 流水账 → V4 事件类型。新产品里没有「用完/丢弃/改过」这些动作，
    /// 折到语义最近的一个，原始说法由 `SubscriptionEvent(migratedFrom:)` 写进备注。
    static func subscriptionEventType(for snapshot: LegacyExpiryEventSnapshot) -> SubscriptionEventType {
        switch ExpiryEventType(rawValue: snapshot.eventTypeRawValue) ?? .edited {
        case .renewed: return .charged
        case .cancelled, .archived, .discarded: return .paused
        case .snoozed: return .skipped
        case .restored: return .resumed
        case .created, .edited, .consumed: return .note
        }
    }
}

// MARK: - 迁移中转

struct LegacyRenewalSnapshot {
    let id: UUID
    let name: String
    let amountMinorUnits: Int
    let currencyCode: String
    let nextRenewalDate: Date
    let cycleRawValue: String
    let intervalMonths: Int
    let anchorDay: Int
    let statusRawValue: String
    let isAutoRenewing: Bool
    let cancelByDate: Date?
    let reminderOffsets: [Int]
    let managementURLString: String
    let notes: String
    let createdAt: Date
    let updatedAt: Date

    init(
        id: UUID,
        name: String,
        amountMinorUnits: Int,
        currencyCode: String,
        nextRenewalDate: Date,
        cycleRawValue: String,
        intervalMonths: Int,
        anchorDay: Int,
        statusRawValue: String,
        isAutoRenewing: Bool,
        cancelByDate: Date?,
        reminderOffsets: [Int],
        managementURLString: String,
        notes: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.amountMinorUnits = amountMinorUnits
        self.currencyCode = currencyCode
        self.nextRenewalDate = nextRenewalDate
        self.cycleRawValue = cycleRawValue
        self.intervalMonths = intervalMonths
        self.anchorDay = anchorDay
        self.statusRawValue = statusRawValue
        self.isAutoRenewing = isAutoRenewing
        self.cancelByDate = cancelByDate
        self.reminderOffsets = reminderOffsets
        self.managementURLString = managementURLString
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(_ item: RenewalItem) {
        id = item.id
        name = item.name
        amountMinorUnits = item.amountMinorUnits
        currencyCode = item.currencyCode
        nextRenewalDate = item.nextRenewalDate
        cycleRawValue = item.cycleRawValue
        intervalMonths = item.intervalMonths
        anchorDay = item.anchorDay
        statusRawValue = item.statusRawValue
        isAutoRenewing = item.isAutoRenewing
        cancelByDate = item.cancelByDate
        reminderOffsets = item.reminderOffsets
        managementURLString = item.managementURLString
        notes = item.notes
        createdAt = item.createdAt
        updatedAt = item.updatedAt
    }
}

struct LegacyDecisionSnapshot {
    let id: UUID
    let renewalItemID: UUID
    let itemName: String
    let actionRawValue: String
    let amountMinorUnits: Int
    let currencyCode: String
    let happenedAt: Date

    init(
        id: UUID,
        renewalItemID: UUID,
        itemName: String,
        actionRawValue: String,
        amountMinorUnits: Int,
        currencyCode: String,
        happenedAt: Date
    ) {
        self.id = id
        self.renewalItemID = renewalItemID
        self.itemName = itemName
        self.actionRawValue = actionRawValue
        self.amountMinorUnits = amountMinorUnits
        self.currencyCode = currencyCode
        self.happenedAt = happenedAt
    }

    init(_ record: DecisionRecord) {
        id = record.id
        renewalItemID = record.renewalItemID
        itemName = record.itemName
        actionRawValue = record.actionRawValue
        amountMinorUnits = record.amountMinorUnits
        currencyCode = record.currencyCode
        happenedAt = record.happenedAt
    }
}

/// willMigrate 和 didMigrate 是两个不同 schema 的 context，
/// 数据只能经这里过一手。SwiftData 在同一次迁移里按顺序调用二者，
/// 且一个进程只会迁移一次。
enum SauryMigrationHandoff {
    nonisolated(unsafe) private(set) static var renewals: [LegacyRenewalSnapshot] = []
    nonisolated(unsafe) private(set) static var decisions: [LegacyDecisionSnapshot] = []
    nonisolated(unsafe) private(set) static var expiryItems: [LegacyExpirySnapshot] = []
    nonisolated(unsafe) private(set) static var expiryEvents: [LegacyExpiryEventSnapshot] = []

    static func load(renewals: [LegacyRenewalSnapshot], decisions: [LegacyDecisionSnapshot]) {
        self.renewals = renewals
        self.decisions = decisions
    }

    static func load(expiryItems: [LegacyExpirySnapshot], expiryEvents: [LegacyExpiryEventSnapshot] = []) {
        self.expiryItems = expiryItems
        self.expiryEvents = expiryEvents
    }

    static func clear() {
        renewals = []
        decisions = []
        clearExpiryItems()
    }

    static func clearExpiryItems() {
        expiryItems = []
        expiryEvents = []
    }
}

/// V3 物品在迁移过桥时的形状。只有分类是订阅的记录会被接进 V4。
struct LegacyExpirySnapshot {
    let id: UUID
    let name: String
    let categoryRawValue: String
    let expiryDate: Date
    let priceMinorUnits: Int?
    let currencyCode: String?
    let recurrenceRawValue: String
    let recurrenceInterval: Int?
    let stateRawValue: String
    let notes: String
    let createdAt: Date
    let updatedAt: Date

    init(_ item: ExpiryItem) {
        id = item.id
        name = item.name
        categoryRawValue = item.categoryRawValue
        expiryDate = item.expiryDate
        priceMinorUnits = item.priceMinorUnits
        currencyCode = item.currencyCode
        recurrenceRawValue = item.recurrenceRawValue
        recurrenceInterval = item.recurrenceInterval
        stateRawValue = item.stateRawValue
        notes = item.notes
        createdAt = item.createdAt
        updatedAt = item.updatedAt
    }
}

/// V3 流水账在迁移过桥时的形状。新产品里没有「用完/丢弃」，
/// 但这些决定是用户真实做过的，金额和时间必须接着往下走。
struct LegacyExpiryEventSnapshot {
    let id: UUID
    let itemID: UUID
    let itemName: String
    let eventTypeRawValue: String
    let priceMinorUnits: Int?
    let currencyCode: String?
    let happenedAt: Date

    init(_ event: ExpiryEvent) {
        id = event.id
        itemID = event.itemID
        itemName = event.itemName
        eventTypeRawValue = event.eventTypeRawValue
        priceMinorUnits = event.priceMinorUnits
        currencyCode = event.currencyCode
        happenedAt = event.happenedAt
    }

    /// 旧事件类型的人话名字；认不出来就退回原始字符串，不编一个假动作。
    var legacyActionTitle: String {
        ExpiryEventType(rawValue: eventTypeRawValue)?.title ?? eventTypeRawValue
    }
}

extension Subscription {
    /// V3 里分类为「订阅」的到期记录直接变成一条订阅；
    /// 其余分类（食品、药品、证件……）在新产品里没有对应物，不再迁移。
    convenience init?(migratedFrom snapshot: LegacyExpirySnapshot) {
        guard snapshot.categoryRawValue == ExpiryCategory.subscription.rawValue else { return nil }
        let cycle: BillingCycle
        let customMonths: Int
        switch ExpiryRecurrence(rawValue: snapshot.recurrenceRawValue) ?? .none {
        case .none: cycle = .oneTime; customMonths = 2
        case .weekly: cycle = .weekly; customMonths = 2
        case .monthly: cycle = .monthly; customMonths = 2
        case .quarterly: cycle = .quarterly; customMonths = 3
        case .everySixMonths: cycle = .semiannual; customMonths = 6
        case .yearly: cycle = .yearly; customMonths = 12
        case .custom: cycle = .custom; customMonths = max(snapshot.recurrenceInterval ?? 1, 1)
        }
        let state: SubscriptionState = snapshot.stateRawValue == ExpiryState.active.rawValue ? .autoRenew : .inactive
        self.init(
            id: snapshot.id,
            name: snapshot.name,
            priceMinorUnits: snapshot.priceMinorUnits ?? 0,
            currencyCode: snapshot.currencyCode ?? "CNY",
            cycle: cycle,
            customMonths: customMonths,
            category: "other",
            state: state,
            startDate: snapshot.expiryDate,
            reminderDays: 3,
            notes: snapshot.notes,
            createdAt: snapshot.createdAt
        )
        updatedAt = snapshot.updatedAt
    }
}

extension ExpiryItem {
    /// 旧订阅全部归入「订阅」分类：那条到期日是续费日，不是包装上的保质期。
    convenience init(migratedFrom snapshot: LegacyRenewalSnapshot) {
        let recurrence = SauryMigrationPlan.recurrence(for: snapshot)
        self.init(
            id: snapshot.id,
            name: snapshot.name,
            category: .subscription,
            expiryDate: snapshot.nextRenewalDate,
            quantity: 1,
            unit: "次",
            priceMinorUnits: snapshot.amountMinorUnits > 0 ? snapshot.amountMinorUnits : nil,
            currencyCode: snapshot.currencyCode,
            recurrence: recurrence.rule,
            recurrenceInterval: recurrence.intervalMonths,
            anchorDay: snapshot.anchorDay,
            actionDeadline: snapshot.cancelByDate,
            sourceURL: snapshot.managementURLString.isEmpty ? nil : snapshot.managementURLString,
            reminderOffsets: snapshot.reminderOffsets.isEmpty
                ? ReminderPolicy.defaultOffsets(for: .subscription)
                : snapshot.reminderOffsets,
            state: SauryMigrationPlan.state(for: snapshot),
            notes: snapshot.notes,
            createdAt: snapshot.createdAt
        )
        updatedAt = snapshot.updatedAt
    }
}

extension ExpiryEvent {
    convenience init(migratedFrom snapshot: LegacyDecisionSnapshot) {
        self.init(
            id: snapshot.id,
            itemID: snapshot.renewalItemID,
            itemName: snapshot.itemName,
            eventType: SauryMigrationPlan.eventType(for: snapshot),
            priceMinorUnits: snapshot.amountMinorUnits > 0 ? snapshot.amountMinorUnits : nil,
            currencyCode: snapshot.currencyCode,
            happenedAt: snapshot.happenedAt
        )
    }
}

extension SubscriptionEvent {
    /// V3 的流水账接到 V4 的时间轴上：编号、所属、金额、时间一个都不改，
    /// 类型折到语义最近的那一个，原来的说法原样留在备注里 ——
    /// 旧版根本没有「用完/丢弃」对应的订阅动作，硬套不如写清楚。
    convenience init(migratedFrom snapshot: LegacyExpiryEventSnapshot) {
        self.init(
            id: snapshot.id,
            subscriptionID: snapshot.itemID,
            type: SauryMigrationPlan.subscriptionEventType(for: snapshot),
            amountMinorUnits: snapshot.priceMinorUnits ?? 0,
            currencyCode: snapshot.currencyCode ?? "CNY",
            note: "旧版记录：\(snapshot.legacyActionTitle)",
            happenedAt: snapshot.happenedAt
        )
    }
}
