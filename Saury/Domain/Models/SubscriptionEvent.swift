import Foundation
import SwiftData

/// 订阅身上的事件：扣费、调价、暂停、恢复、跳过、备注。
/// 时间轴页直接按时间倒序展示；「总花费」从已扣费事件里算。
enum SubscriptionEventType: String, CaseIterable, Codable {
    case charged
    case priceChanged
    case paused
    case resumed
    case skipped
    case inAppPurchase
    case note

    var title: String {
        switch self {
        case .charged: return "扣费"
        case .priceChanged: return "调价"
        case .paused: return "暂停"
        case .resumed: return "恢复"
        case .skipped: return "跳过一期"
        case .inAppPurchase: return "内购"
        case .note: return "备注"
        }
    }

    var symbol: String {
        switch self {
        case .charged: return "creditcard"
        case .priceChanged: return "arrow.up.arrow.down"
        case .paused: return "pause.circle"
        case .resumed: return "play.circle"
        case .skipped: return "forward.end"
        case .inAppPurchase: return "bag.badge.plus"
        case .note: return "note.text"
        }
    }
}

@Model
final class SubscriptionEvent {
    @Attribute(.unique) var id: UUID
    var subscriptionID: UUID
    var typeRawValue: String
    var amountMinorUnits: Int
    var currencyCode: String
    var note: String
    var happenedAt: Date

    init(
        id: UUID = UUID(),
        subscriptionID: UUID,
        type: SubscriptionEventType,
        amountMinorUnits: Int = 0,
        currencyCode: String = "",
        note: String = "",
        happenedAt: Date = Date()
    ) {
        self.id = id
        self.subscriptionID = subscriptionID
        self.typeRawValue = type.rawValue
        self.amountMinorUnits = amountMinorUnits
        self.currencyCode = currencyCode
        self.note = note
        self.happenedAt = happenedAt
    }

    var type: SubscriptionEventType {
        get { SubscriptionEventType(rawValue: typeRawValue) ?? .note }
        set { typeRawValue = newValue.rawValue }
    }

    var amount: Money? {
        guard amountMinorUnits != 0, !currencyCode.isEmpty else { return nil }
        return Money(minorUnits: amountMinorUnits, currencyCode: currencyCode)
    }
}
