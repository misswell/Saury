import Foundation
import SwiftData

/// 用户对一条物品做过什么（方案 §38）。事件是流水账，不覆盖：
/// 「这次丢掉了什么」和「上次续了多少钱」都要能回看。
enum ExpiryEventType: String, Codable, CaseIterable, Identifiable {
    case created
    case edited
    case consumed
    case discarded
    case renewed
    case cancelled
    case snoozed
    case archived
    case restored

    var id: String { rawValue }

    var title: String {
        switch self {
        case .created: return "已添加"
        case .edited: return "已修改"
        case .consumed: return "已用完"
        case .discarded: return "已丢弃"
        case .renewed: return "已续期"
        case .cancelled: return "已取消"
        case .snoozed: return "稍后再提醒"
        case .archived: return "已归档"
        case .restored: return "已恢复"
        }
    }

    var symbolName: String {
        switch self {
        case .created: return "plus.circle.fill"
        case .edited: return "pencil.circle.fill"
        case .consumed: return "checkmark.circle.fill"
        case .discarded: return "trash.fill"
        case .renewed: return "arrow.clockwise"
        case .cancelled: return "xmark.circle.fill"
        case .snoozed: return "clock.fill"
        case .archived: return "archivebox.fill"
        case .restored: return "arrow.uturn.backward.circle.fill"
        }
    }

    /// 处理结果会改变跟踪状态的动作，用绿色强调；其余保持中性。
    var isResolution: Bool {
        switch self {
        case .consumed, .discarded, .renewed, .cancelled: return true
        default: return false
        }
    }
}

@Model
final class ExpiryEvent {
    @Attribute(.unique) var id: UUID
    var itemID: UUID
    var itemName: String
    var eventTypeRawValue: String
    var quantity: Double?
    var priceMinorUnits: Int?
    var currencyCode: String?
    var expiryDate: Date?
    var happenedAt: Date
    /// 这一次扫描留下的原图文件名（方案 §34）。只有扫出来的记录有；
    /// 物品之后被改、被删都不影响它 —— 历史记录的主体就是这张原图。
    var imageIdentifier: String?

    init(
        id: UUID = UUID(),
        itemID: UUID,
        itemName: String,
        eventType: ExpiryEventType,
        quantity: Double? = nil,
        priceMinorUnits: Int? = nil,
        currencyCode: String? = nil,
        expiryDate: Date? = nil,
        happenedAt: Date = Date(),
        imageIdentifier: String? = nil
    ) {
        self.id = id
        self.itemID = itemID
        self.itemName = itemName
        self.eventTypeRawValue = eventType.rawValue
        self.quantity = quantity
        self.priceMinorUnits = priceMinorUnits
        self.currencyCode = currencyCode
        self.expiryDate = expiryDate
        self.happenedAt = happenedAt
        self.imageIdentifier = imageIdentifier
    }

    var eventType: ExpiryEventType {
        ExpiryEventType(rawValue: eventTypeRawValue) ?? .edited
    }
}

extension ExpiryEvent {
    /// 从物品快照记录一条事件：名字、金额、数量在物品之后被改也不影响历史。
    /// `imageIdentifier` 只有扫描留下的记录才有（方案 §34）。
    convenience init(
        eventType: ExpiryEventType,
        for item: ExpiryItem,
        happenedAt: Date = Date(),
        imageIdentifier: String? = nil
    ) {
        self.init(
            itemID: item.id,
            itemName: item.name,
            eventType: eventType,
            quantity: item.quantity,
            priceMinorUnits: item.priceMinorUnits,
            currencyCode: item.currencyCode ?? QJPreferences.defaultCurrencyCode,
            expiryDate: item.expiryDate,
            happenedAt: happenedAt,
            imageIdentifier: imageIdentifier
        )
    }
}

/// 用户当下能做出的处理（方案 §35）。动作只有一处定义：
/// 详情页、通知按钮和快捷指令必须给出同一个结果，否则同一次「续期」
/// 会留下两套不同的数据。
enum ExpiryAction: String, Codable, CaseIterable, Identifiable {
    case consumed
    case discarded
    case renewed
    case cancelled
    case snoozed
    case archived

    var id: String { rawValue }

    var eventType: ExpiryEventType {
        switch self {
        case .consumed: return .consumed
        case .discarded: return .discarded
        case .renewed: return .renewed
        case .cancelled: return .cancelled
        case .snoozed: return .snoozed
        case .archived: return .archived
        }
    }

    /// nil 表示物品仍然在跟踪中（稍后再提醒不改状态）。
    var resultingState: ExpiryState? {
        switch self {
        case .consumed: return .consumed
        case .discarded: return .discarded
        case .renewed: return .renewed
        case .cancelled: return .cancelled
        case .archived: return .archived
        case .snoozed: return nil
        }
    }

    var title: String {
        switch self {
        case .consumed: return "已用完"
        case .discarded: return "已丢弃"
        case .renewed: return "已续期"
        case .cancelled: return "已取消"
        case .snoozed: return "明天再提醒"
        case .archived: return "归档"
        }
    }

    /// 同一个动作在不同分类下是不同的一句话（方案 §35）。一盒牛奶不该看到
    /// 「已续期」，一本护照不该看到「已用完」。
    func title(forCategory category: ExpiryCategory) -> String {
        switch self {
        case .consumed:
            switch category {
            case .food: return "吃完"
            case .medicine, .supplement, .pet: return "用完"
            default: return title
            }
        case .discarded:
            return category.isConsumable ? "丢弃" : title
        case .renewed:
            switch category {
            case .subscription: return "已续订"
            case .medicine: return "替换新品"
            default: return title
            }
        case .cancelled, .snoozed, .archived:
            return title
        }
    }

    func title(for item: ExpiryItem) -> String {
        title(forCategory: item.category)
    }

    var symbolName: String { eventType.symbolName }

    /// 会不会把到期日推到下一个周期。
    var advancesExpiryDate: Bool { self == .renewed }

    /// 只列出真正能执行的动作（方案 §35）：没有周期的物品算不出「下一次」，
    /// 消耗品问「还继续吗」也没有意义。
    static func available(for item: ExpiryItem) -> [ExpiryAction] {
        ExpiryActionGroup(for: item).actions + [.snoozed, .archived]
    }
}

/// 处理动作的分组（方案 §39）：通知上的按钮必须和 App 里完全一致，
/// 而 UNNotificationCategory 只能提前按「这一类物品」注册，所以先把
/// 动作集合归成有限几种，让通知和界面共用同一份定义。
enum ExpiryActionGroup: String, CaseIterable, Identifiable {
    case consumable
    case recurring
    case renewable

    var id: String { rawValue }

    init(for item: ExpiryItem) {
        if item.recurrence.isRecurring {
            self = .recurring
        } else if item.category.needsRenewal {
            self = .renewable
        } else {
            self = .consumable
        }
    }

    /// 能一步把这件事处理掉的动作，按主操作在前排列。
    var actions: [ExpiryAction] {
        switch self {
        case .consumable: return [.consumed, .discarded]
        case .recurring: return [.renewed, .cancelled]
        case .renewable: return [.renewed]
        }
    }
}
