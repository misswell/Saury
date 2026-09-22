import Foundation
import SwiftData

//
//  本机 JSON 备份。方案 §59/§60 会把它升级成正式的 Backup V2；
//  这里先把字段跟上新模型，并保证同一份备份重复导入不会产生成倍的历史记录。
//

struct SauryExport: Codable {
    static let currentVersion = 2

    let version: Int
    let exportedAt: Date
    let items: [ExportedExpiryItem]
    let events: [ExportedExpiryEvent]
}

struct ExportedExpiryItem: Codable {
    let id: UUID
    let name: String
    let brand: String?
    let category: String
    let expiryDate: Date
    let manufactureDate: Date?
    let purchaseDate: Date?
    let openedDate: Date?
    let shelfLifeDays: Int?
    let afterOpeningDays: Int?
    let barcode: String?
    let batchNumber: String?
    let quantity: Double
    let unit: String
    let location: String?
    let priceMinorUnits: Int?
    let currencyCode: String?
    let recurrence: String
    let recurrenceInterval: Int?
    let actionDeadline: Date?
    let sourceURL: String?
    /// 图片文件不在这份 JSON 里（方案 §34 它本来就存在库里之外），这里只带上文件名。
    /// 换设备恢复时文件可能不在，活动记录会说明「这张照片不在这台设备上了」。
    let imageIdentifier: String?
    let reminderOffsets: [Int]
    let state: String
    let notes: String
    let createdAt: Date
    let updatedAt: Date

    init(_ item: ExpiryItem) {
        id = item.id
        name = item.name
        brand = item.brand
        category = item.category.rawValue
        expiryDate = item.expiryDate
        manufactureDate = item.manufactureDate
        purchaseDate = item.purchaseDate
        openedDate = item.openedDate
        shelfLifeDays = item.shelfLifeDays
        afterOpeningDays = item.afterOpeningDays
        barcode = item.barcode
        batchNumber = item.batchNumber
        quantity = item.quantity
        unit = item.unit
        location = item.location
        priceMinorUnits = item.priceMinorUnits
        currencyCode = item.currencyCode
        recurrence = item.recurrence.rawValue
        recurrenceInterval = item.recurrenceInterval
        actionDeadline = item.actionDeadline
        sourceURL = item.sourceURL
        imageIdentifier = item.imageIdentifier
        reminderOffsets = item.reminderOffsets
        state = item.state.rawValue
        notes = item.notes
        createdAt = item.createdAt
        updatedAt = item.updatedAt
    }
}

struct ExportedExpiryEvent: Codable {
    let id: UUID
    let itemID: UUID
    let itemName: String
    let eventType: String
    let quantity: Double?
    let priceMinorUnits: Int?
    let currencyCode: String?
    let expiryDate: Date?
    let happenedAt: Date
    let imageIdentifier: String?

    init(_ event: ExpiryEvent) {
        id = event.id
        itemID = event.itemID
        itemName = event.itemName
        eventType = event.eventType.rawValue
        quantity = event.quantity
        priceMinorUnits = event.priceMinorUnits
        currencyCode = event.currencyCode
        expiryDate = event.expiryDate
        happenedAt = event.happenedAt
        imageIdentifier = event.imageIdentifier
    }
}

enum DataExportService {
    struct ImportSummary {
        let importedItems: Int
        let importedEvents: Int
        let skippedEvents: Int

        var message: String {
            if skippedEvents > 0 {
                return String(format: "已导入 %d 条物品和 %d 条记录，%d 条重复记录已跳过。", importedItems, importedEvents, skippedEvents)
            }
            return String(format: "已导入 %d 条物品和 %d 条记录。", importedItems, importedEvents)
        }
    }

    static func jsonText(items: [ExpiryItem], events: [ExpiryEvent]) -> String {
        let export = SauryExport(version: SauryExport.currentVersion, exportedAt: Date(), items: items.map(ExportedExpiryItem.init), events: events.map(ExportedExpiryEvent.init))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(export), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// 按 id 幂等导入：同一份备份导入两次不会多出物品，也不会重复历史。
    @MainActor
    static func importJSON(_ data: Data, into modelContext: ModelContext) throws -> ImportSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(SauryExport.self, from: data)

        var itemsByID = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<ExpiryItem>()).map { ($0.id, $0) })
        var importedItems = 0
        for exported in export.items {
            let category = ExpiryCategory(rawValue: exported.category) ?? .other
            let recurrence = ExpiryRecurrence(rawValue: exported.recurrence) ?? .none
            let state = ExpiryState(rawValue: exported.state) ?? .active
            if let item = itemsByID[exported.id] {
                item.name = exported.name
                item.brand = exported.brand
                item.categoryRawValue = category.rawValue
                item.expiryDate = exported.expiryDate
                item.manufactureDate = exported.manufactureDate
                item.purchaseDate = exported.purchaseDate
                item.openedDate = exported.openedDate
                item.shelfLifeDays = exported.shelfLifeDays
                item.afterOpeningDays = exported.afterOpeningDays
                item.barcode = exported.barcode
                item.batchNumber = exported.batchNumber
                item.quantity = exported.quantity
                item.unit = exported.unit
                item.location = exported.location
                item.priceMinorUnits = exported.priceMinorUnits
                item.currencyCode = exported.currencyCode
                item.recurrenceRawValue = recurrence.rawValue
                item.recurrenceInterval = exported.recurrenceInterval
                item.actionDeadline = exported.actionDeadline
                item.sourceURL = exported.sourceURL
                // 老备份里没有这一列：按「没带图」处理，不能因此把本机已有的图抹掉。
                if let identifier = exported.imageIdentifier { item.imageIdentifier = identifier }
                item.reminderOffsets = exported.reminderOffsets
                item.stateRawValue = state.rawValue
                item.notes = exported.notes
                item.markUpdated()
            } else {
                let item = ExpiryItem(
                    id: exported.id,
                    name: exported.name,
                    brand: exported.brand,
                    category: category,
                    expiryDate: exported.expiryDate,
                    manufactureDate: exported.manufactureDate,
                    purchaseDate: exported.purchaseDate,
                    openedDate: exported.openedDate,
                    shelfLifeDays: exported.shelfLifeDays,
                    afterOpeningDays: exported.afterOpeningDays,
                    barcode: exported.barcode,
                    batchNumber: exported.batchNumber,
                    quantity: exported.quantity,
                    unit: exported.unit,
                    location: exported.location,
                    priceMinorUnits: exported.priceMinorUnits,
                    currencyCode: exported.currencyCode,
                    recurrence: recurrence,
                    recurrenceInterval: exported.recurrenceInterval,
                    actionDeadline: exported.actionDeadline,
                    sourceURL: exported.sourceURL,
                    imageIdentifier: exported.imageIdentifier,
                    reminderOffsets: exported.reminderOffsets,
                    state: state,
                    notes: exported.notes,
                    createdAt: exported.createdAt
                )
                item.updatedAt = exported.updatedAt
                modelContext.insert(item)
                itemsByID[exported.id] = item
            }
            importedItems += 1
        }

        let existingEventIDs = Set(try modelContext.fetch(FetchDescriptor<ExpiryEvent>()).map(\.id))
        var importedEvents = 0
        var skippedEvents = 0
        for exported in export.events {
            guard !existingEventIDs.contains(exported.id) else { skippedEvents += 1; continue }
            modelContext.insert(ExpiryEvent(
                id: exported.id,
                itemID: exported.itemID,
                itemName: exported.itemName,
                eventType: ExpiryEventType(rawValue: exported.eventType) ?? .edited,
                quantity: exported.quantity,
                priceMinorUnits: exported.priceMinorUnits,
                currencyCode: exported.currencyCode,
                expiryDate: exported.expiryDate,
                happenedAt: exported.happenedAt,
                imageIdentifier: exported.imageIdentifier
            ))
            importedEvents += 1
        }

        try modelContext.save()
        return ImportSummary(importedItems: importedItems, importedEvents: importedEvents, skippedEvents: skippedEvents)
    }
}
