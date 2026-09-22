import Foundation
import SwiftData

//
//  旧订阅域的数据层。类名和属性名都是**承重结构**：
//  已经装在用户手机上的 SQLite 里就是按这些名字建的表，
//  SaurySchemaV1 必须和它逐字一致，迁移才读得到旧数据。
//  因此这里只保留存储字段，展示逻辑（标题、图标、默认提醒）全部删除，
//  新代码一律使用 ExpiryItem / ExpiryEvent。
//

/// 旧到期提醒记录（RenewalItem → ExpiryItem 的迁移来源）。
@Model
final class RenewalItem {
    @Attribute(.unique) var id: UUID
    var name: String
    var amountMinorUnits: Int
    var currencyCode: String
    var nextRenewalDate: Date
    var anchorDay: Int
    var cycleRawValue: String
    var intervalMonths: Int
    var categoryRawValue: String
    var statusRawValue: String
    var isAutoRenewing: Bool
    var cancelByDate: Date?
    var reminderOffsetsData: Data
    var managementURLString: String
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        amountMinorUnits: Int = 0,
        currencyCode: String = "CNY",
        nextRenewalDate: Date,
        cycleRawValue: String = "monthly",
        intervalMonths: Int = 1,
        categoryRawValue: String = "productivity",
        statusRawValue: String = "active",
        isAutoRenewing: Bool = true,
        cancelByDate: Date? = nil,
        reminderOffsets: [Int] = [7 * 24 * 60, 3 * 24 * 60, 24 * 60, 0],
        managementURLString: String = "",
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.amountMinorUnits = max(amountMinorUnits, 0)
        self.currencyCode = currencyCode
        self.nextRenewalDate = nextRenewalDate
        self.anchorDay = ExpiryEngine.calendar.component(.day, from: nextRenewalDate)
        self.cycleRawValue = cycleRawValue
        self.intervalMonths = max(intervalMonths, 1)
        self.categoryRawValue = categoryRawValue
        self.statusRawValue = statusRawValue
        self.isAutoRenewing = isAutoRenewing
        self.cancelByDate = cancelByDate
        self.reminderOffsetsData = (try? JSONEncoder().encode(reminderOffsets)) ?? Data()
        self.managementURLString = managementURLString
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var reminderOffsets: [Int] {
        (try? JSONDecoder().decode([Int].self, from: reminderOffsetsData)) ?? ReminderPolicy.defaultOffsets(for: .subscription)
    }
}

/// 旧决定记录（DecisionRecord → ExpiryEvent 的迁移来源）。
@Model
final class DecisionRecord {
    @Attribute(.unique) var id: UUID
    var renewalItemID: UUID
    var itemName: String
    var actionRawValue: String
    var amountMinorUnits: Int
    var currencyCode: String
    var happenedAt: Date

    init(
        id: UUID = UUID(),
        renewalItemID: UUID,
        itemName: String,
        actionRawValue: String,
        amountMinorUnits: Int = 0,
        currencyCode: String = "CNY",
        happenedAt: Date = Date()
    ) {
        self.id = id
        self.renewalItemID = renewalItemID
        self.itemName = itemName
        self.actionRawValue = actionRawValue
        self.amountMinorUnits = amountMinorUnits
        self.currencyCode = currencyCode
        self.happenedAt = happenedAt
    }
}

/// 旧 cycleRawValue 的取值集合，只用于迁移映射。
enum LegacyRenewalCycle: String {
    case monthly
    case yearly
    case customMonths
    case oneTime
    case freeTrial
}

/// 旧 statusRawValue 的取值集合，只用于迁移映射。
enum LegacyRenewalStatus: String {
    case active
    case paused
    case cancelled
    case expired
}

/// 旧 actionRawValue 的取值集合，只用于迁移映射。
enum LegacyDecisionAction: String {
    case cancelled
    case continued
    case paused
    case snoozed
}
