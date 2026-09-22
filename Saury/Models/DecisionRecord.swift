import Foundation
import SwiftData

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
        action: DecisionAction,
        amountMinorUnits: Int,
        currencyCode: String,
        happenedAt: Date = Date()
    ) {
        self.id = id
        self.renewalItemID = renewalItemID
        self.itemName = itemName
        self.actionRawValue = action.rawValue
        self.amountMinorUnits = amountMinorUnits
        self.currencyCode = currencyCode
        self.happenedAt = happenedAt
    }

    var action: DecisionAction { DecisionAction(rawValue: actionRawValue) ?? .snoozed }
}
