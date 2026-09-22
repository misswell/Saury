import Foundation
import SwiftData

struct RenewalExport: Codable {
    let exportedAt: Date
    let items: [RenewalExportItem]
    let decisions: [RenewalExportDecision]
}

struct RenewalExportItem: Codable {
    let id: UUID
    let name: String
    let amountMinorUnits: Int
    let currencyCode: String
    let nextRenewalDate: Date
    let cycle: String
    let intervalMonths: Int
    let category: String
    let status: String
    let isAutoRenewing: Bool
    let cancelByDate: Date?
    let reminderOffsets: [Int]
    let managementURLString: String
    let notes: String

    init(_ item: RenewalItem) {
        id = item.id
        name = item.name
        amountMinorUnits = item.amountMinorUnits
        currencyCode = item.currencyCode
        nextRenewalDate = item.nextRenewalDate
        cycle = item.cycle.rawValue
        intervalMonths = item.intervalMonths
        category = item.category.rawValue
        status = item.status.rawValue
        isAutoRenewing = item.isAutoRenewing
        cancelByDate = item.cancelByDate
        reminderOffsets = item.reminderOffsets
        managementURLString = item.managementURLString
        notes = item.notes
    }
}

struct RenewalExportDecision: Codable {
    let renewalItemID: UUID
    let itemName: String
    let action: String
    let amountMinorUnits: Int
    let currencyCode: String
    let happenedAt: Date

    init(_ decision: DecisionRecord) {
        renewalItemID = decision.renewalItemID
        itemName = decision.itemName
        action = decision.action.rawValue
        amountMinorUnits = decision.amountMinorUnits
        currencyCode = decision.currencyCode
        happenedAt = decision.happenedAt
    }
}

enum DataExportService {
    struct ImportSummary {
        let importedItems: Int
        let importedDecisions: Int

        var message: String {
            String(format: "已导入 %d 个订阅和 %d 条历史记录。", importedItems, importedDecisions)
        }
    }

    static func makeExport(items: [RenewalItem], decisions: [DecisionRecord]) -> RenewalExport {
        RenewalExport(exportedAt: Date(), items: items.map(RenewalExportItem.init), decisions: decisions.map(RenewalExportDecision.init))
    }

    static func jsonText(items: [RenewalItem], decisions: [DecisionRecord]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(makeExport(items: items, decisions: decisions)),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// Imports a JSON backup into the local SwiftData store. Existing subscriptions
    /// are updated by UUID so a backup can safely be restored more than once.
    @MainActor
    static func importJSON(_ data: Data, into modelContext: ModelContext) throws -> ImportSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(RenewalExport.self, from: data)

        let existingItems = try modelContext.fetch(FetchDescriptor<RenewalItem>())
        var itemsByID = Dictionary(uniqueKeysWithValues: existingItems.map { ($0.id, $0) })
        var importedItems = 0

        for exported in export.items {
            let cycle = RenewalCycle(rawValue: exported.cycle) ?? .monthly
            let category = RenewalCategory(rawValue: exported.category) ?? .other
            let status = RenewalStatus(rawValue: exported.status) ?? .active

            if let item = itemsByID[exported.id] {
                item.name = exported.name
                item.amountMinorUnits = max(exported.amountMinorUnits, 0)
                item.currencyCode = exported.currencyCode.isEmpty ? "CNY" : exported.currencyCode
                item.nextRenewalDate = exported.nextRenewalDate
                item.anchorDay = Calendar.current.component(.day, from: exported.nextRenewalDate)
                item.cycle = cycle
                item.intervalMonths = max(exported.intervalMonths, 1)
                item.category = category
                item.status = status
                item.isAutoRenewing = exported.isAutoRenewing
                item.cancelByDate = exported.cancelByDate
                item.reminderOffsets = exported.reminderOffsets.isEmpty ? cycle.defaultReminderOffsets : exported.reminderOffsets
                item.managementURLString = exported.managementURLString
                item.notes = exported.notes
                item.markUpdated()
            } else {
                let item = RenewalItem(
                    id: exported.id,
                    name: exported.name,
                    amountMinorUnits: exported.amountMinorUnits,
                    currencyCode: exported.currencyCode,
                    nextRenewalDate: exported.nextRenewalDate,
                    cycle: cycle,
                    intervalMonths: exported.intervalMonths,
                    category: category,
                    status: status,
                    isAutoRenewing: exported.isAutoRenewing,
                    cancelByDate: exported.cancelByDate,
                    reminderOffsets: exported.reminderOffsets,
                    managementURLString: exported.managementURLString,
                    notes: exported.notes
                )
                modelContext.insert(item)
                itemsByID[exported.id] = item
            }
            importedItems += 1
        }

        var importedDecisions = 0
        for exported in export.decisions {
            let action = DecisionAction(rawValue: exported.action) ?? .snoozed
            modelContext.insert(DecisionRecord(
                renewalItemID: exported.renewalItemID,
                itemName: exported.itemName,
                action: action,
                amountMinorUnits: max(exported.amountMinorUnits, 0),
                currencyCode: exported.currencyCode,
                happenedAt: exported.happenedAt
            ))
            importedDecisions += 1
        }

        try modelContext.save()
        return ImportSummary(importedItems: importedItems, importedDecisions: importedDecisions)
    }
}
