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

enum SauryMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SaurySchemaV1.self, SaurySchemaV2.self, SaurySchemaV3.self] }

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
            .lightweight(fromVersion: SaurySchemaV2.self, toVersion: SaurySchemaV3.self)
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

    static func load(renewals: [LegacyRenewalSnapshot], decisions: [LegacyDecisionSnapshot]) {
        self.renewals = renewals
        self.decisions = decisions
    }

    static func clear() {
        renewals = []
        decisions = []
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
