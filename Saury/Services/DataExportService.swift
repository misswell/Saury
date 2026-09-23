import CryptoKit
import Foundation
import SwiftData

//
//  本机 JSON 备份（方案 §59 Backup V2、§60 幂等恢复）。
//
//  要同时接住三代文件：
//  V2 —— `schemaVersion` + items / events / templates / locations；
//  改造中途 —— 只写了 `version`，且没有模板和位置；
//  订阅时代（TestFlight build 2、3 导出的就是这种）—— items 是续费字段，历史在 `decisions` 里。
//  三代都按 UUID 认身份：已存在就更新，不存在才插入，同一个文件导入两次数据量不变。
//

struct SauryExport: Codable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let exportedAt: Date
    let items: [ExportedExpiryItem]
    let events: [ExportedExpiryEvent]
    let templates: [ExportedProductTemplate]
    let locations: [String]

    init(
        exportedAt: Date,
        items: [ExportedExpiryItem],
        events: [ExportedExpiryEvent],
        templates: [ExportedProductTemplate] = [],
        locations: [String] = []
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.exportedAt = exportedAt
        self.items = items
        self.events = events
        self.templates = templates
        self.locations = locations
    }

    private enum Wire: CodingKey {
        case schemaVersion, version, exportedAt, items, events, templates, locations
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: Wire.self)
        // 改造中途那份写的是 `version`：键换了名字，内容其实一样，不该要求用户重新导出。
        schemaVersion = try box.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? box.decodeIfPresent(Int.self, forKey: .version)
            ?? Self.currentSchemaVersion
        exportedAt = try box.decode(Date.self, forKey: .exportedAt)
        items = try box.decodeIfPresent([ExportedExpiryItem].self, forKey: .items) ?? []
        events = try box.decodeIfPresent([ExportedExpiryEvent].self, forKey: .events) ?? []
        templates = try box.decodeIfPresent([ExportedProductTemplate].self, forKey: .templates) ?? []
        locations = try box.decodeIfPresent([String].self, forKey: .locations) ?? []
    }
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

/// 商品模板（方案 §28）。身份是条码本身 —— 库里那一列就是 `@Attribute(.unique)`，
/// 再补一个 UUID 只会多出一个可以对不上的键。
struct ExportedProductTemplate: Codable {
    let barcode: String
    let name: String
    let brand: String?
    let category: String
    let location: String?
    let unit: String
    let reminderOffsets: [Int]

    init(_ template: ProductTemplate) {
        barcode = template.barcode
        name = template.name
        brand = template.brand
        category = template.category.rawValue
        location = template.location
        unit = template.unit
        reminderOffsets = template.reminderOffsets
    }
}

// MARK: - 订阅时代那份备份的字段

private struct LegacyRenewalBackup: Decodable {
    let exportedAt: Date
    let items: [Item]
    let decisions: [Decision]

    struct Item: Decodable {
        let id: UUID
        let name: String
        let amountMinorUnits: Int
        let currencyCode: String
        let nextRenewalDate: Date
        let cycle: String
        let intervalMonths: Int
        let status: String
        let isAutoRenewing: Bool
        let cancelByDate: Date?
        let reminderOffsets: [Int]
        let managementURLString: String
        let notes: String
    }

    /// 当年的导出没带 `id`，所以历史记录的身份只能由内容算出来。
    struct Decision: Decodable {
        let renewalItemID: UUID
        let itemName: String
        let action: String
        let amountMinorUnits: Int
        let currencyCode: String
        let happenedAt: Date
    }
}

enum DataExportService {
    struct ImportSummary {
        let importedItems: Int
        let importedEvents: Int
        let skippedEvents: Int
        let importedTemplates: Int
        let addedLocations: Int

        var message: String {
            var parts = [String(format: "已导入 %d 条物品", importedItems),
                         String(format: "%d 条记录", importedEvents)]
            if importedTemplates > 0 { parts.append(String(format: "%d 个商品模板", importedTemplates)) }
            if addedLocations > 0 { parts.append(String(format: "新增 %d 个位置", addedLocations)) }
            var text = parts.joined(separator: "、") + "。"
            if skippedEvents > 0 { text += "重复的记录已经跳过。" }
            return text
        }
    }

    enum BackupError: LocalizedError {
        case notAnObject
        case unreadable

        var errorDescription: String? {
            switch self {
            case .notAnObject: return "这个文件不是一份 JSON 备份。"
            case .unreadable: return "读不出内容：这不是期见导出的备份，或者文件已经损坏。"
            }
        }
    }

    static func jsonText(
        items: [ExpiryItem],
        events: [ExpiryEvent],
        templates: [ProductTemplate] = [],
        locations: [String] = LocationCatalog.all
    ) -> String {
        let export = SauryExport(
            exportedAt: Date(),
            items: items.map(ExportedExpiryItem.init),
            events: events.map(ExportedExpiryEvent.init),
            templates: templates.map(ExportedProductTemplate.init),
            locations: locations
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(export), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    @MainActor
    static func importJSON(_ data: Data, into modelContext: ModelContext) throws -> ImportSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            // 先按键判断代次，再交给对应的结构：让解码器自己试错的话，
            // 订阅时代的文件会被报成「缺 items 之外的字段」，用户看到的是一串看不懂的话。
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let root = object as? [String: Any] else {
                throw BackupError.notAnObject
            }
            if root["decisions"] is [Any], root["events"] == nil {
                return try importLegacyRenewal(decoder.decode(LegacyRenewalBackup.self, from: data), into: modelContext)
            }
            return try importBackup(decoder.decode(SauryExport.self, from: data), into: modelContext)
        } catch let error where (error as? BackupError) != nil {
            throw error
        } catch {
            throw BackupError.unreadable
        }
    }

    // MARK: - V2 / 改造中途

    @MainActor
    private static func importBackup(_ export: SauryExport, into modelContext: ModelContext) throws -> ImportSummary {
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
                importedItems += 1
                continue
            }
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
            importedItems += 1
        }

        let summary = try importEvents(export.events, into: modelContext)
        let templates = try importTemplates(export.templates, into: modelContext)
        let locations = mergeLocations(export.locations)
        try modelContext.save()
        return ImportSummary(
            importedItems: importedItems,
            importedEvents: summary.imported,
            skippedEvents: summary.skipped,
            importedTemplates: templates,
            addedLocations: locations
        )
    }

    // MARK: - 订阅时代

    @MainActor
    private static func importLegacyRenewal(_ backup: LegacyRenewalBackup, into modelContext: ModelContext) throws -> ImportSummary {
        let existingItemIDs = Set(try modelContext.fetch(FetchDescriptor<ExpiryItem>()).map(\.id))
        var importedItems = 0
        var skippedEvents = 0
        for legacy in backup.items {
            // 旧字段和新字段语义不同（续费日 ≠ 保质期），只补没有的，不把本机更新过的记录盖回旧值。
            guard !existingItemIDs.contains(legacy.id) else { continue }
            modelContext.insert(ExpiryItem(migratedFrom: LegacyRenewalSnapshot(legacy, exportedAt: backup.exportedAt)))
            importedItems += 1
        }

        let existingEventIDs = Set(try modelContext.fetch(FetchDescriptor<ExpiryEvent>()).map(\.id))
        var importedEvents = 0
        for decision in backup.decisions {
            let id = surrogateEventID(for: decision)
            guard !existingEventIDs.contains(id) else { skippedEvents += 1; continue }
            modelContext.insert(ExpiryEvent(migratedFrom: LegacyDecisionSnapshot(
                id: id,
                renewalItemID: decision.renewalItemID,
                itemName: decision.itemName,
                actionRawValue: decision.action,
                amountMinorUnits: decision.amountMinorUnits,
                currencyCode: decision.currencyCode,
                happenedAt: decision.happenedAt
            )))
            importedEvents += 1
        }

        try modelContext.save()
        return ImportSummary(
            importedItems: importedItems,
            importedEvents: importedEvents,
            skippedEvents: skippedEvents,
            importedTemplates: 0,
            addedLocations: 0
        )
    }

    /// 老文件里的决定记录没有 id，内容相同就是同一条：拿内容算一个稳定 UUID，
    /// 同一个文件第二次导入时它已经存在，于是被跳过而不是又多出一条。
    private static func surrogateEventID(for decision: LegacyRenewalBackup.Decision) -> UUID {
        let key = [
            decision.renewalItemID.uuidString,
            decision.action,
            String(decision.happenedAt.timeIntervalSince1970),
            String(decision.amountMinorUnits)
        ].joined(separator: "|")
        let digest = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3],
                           digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11],
                           digest[12], digest[13], digest[14], digest[15]))
    }

    // MARK: - 共用的幂等片段

    @MainActor
    private static func importEvents(_ events: [ExportedExpiryEvent], into modelContext: ModelContext) throws -> (imported: Int, skipped: Int) {
        let existing = Set(try modelContext.fetch(FetchDescriptor<ExpiryEvent>()).map(\.id))
        var imported = 0
        var skipped = 0
        for exported in events {
            // 事件是发生过的事实，不带「改成别的值」这种语义：见过就跳过。
            guard !existing.contains(exported.id) else { skipped += 1; continue }
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
            imported += 1
        }
        return (imported, skipped)
    }

    @MainActor
    private static func importTemplates(_ templates: [ExportedProductTemplate], into modelContext: ModelContext) throws -> Int {
        let existing = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<ProductTemplate>()).map { ($0.barcode, $0) })
        var count = 0
        for exported in templates {
            guard let barcode = ProductTemplate.normalized(exported.barcode) else { continue }
            let category = ExpiryCategory(rawValue: exported.category) ?? .other
            if let template = existing[barcode] {
                template.refresh(name: exported.name, brand: exported.brand, category: category,
                                 location: exported.location, unit: exported.unit,
                                 reminderOffsets: exported.reminderOffsets)
            } else {
                modelContext.insert(ProductTemplate(
                    barcode: barcode,
                    name: exported.name,
                    brand: exported.brand,
                    category: category,
                    location: exported.location,
                    unit: exported.unit,
                    reminderOffsets: exported.reminderOffsets.isEmpty ? nil : exported.reminderOffsets
                ))
            }
            count += 1
        }
        return count
    }

    /// 位置清单只有一份：本机已有的顺序不动，备份里多出来的追加在后面。
    /// 于是同一个文件导入两次，清单长度不会变。
    private static func mergeLocations(_ locations: [String]) -> Int {
        let cleaned = locations.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return 0 }
        var seen = Set(LocationCatalog.all)
        let added = cleaned.filter { seen.insert($0).inserted }
        guard !added.isEmpty else { return 0 }
        LocationCatalog.replace(LocationCatalog.all + added)
        return added.count
    }
}

private extension LegacyRenewalSnapshot {
    /// 订阅时代的备份里没有 anchorDay / createdAt / updatedAt：
    /// 锚定日和旧库里一样按续费日算，时间戳退回导出那一刻。
    init(_ backup: LegacyRenewalBackup.Item, exportedAt: Date) {
        self.init(
            id: backup.id,
            name: backup.name,
            amountMinorUnits: backup.amountMinorUnits,
            currencyCode: backup.currencyCode,
            nextRenewalDate: backup.nextRenewalDate,
            cycleRawValue: backup.cycle,
            intervalMonths: backup.intervalMonths,
            anchorDay: ExpiryEngine.calendar.component(.day, from: backup.nextRenewalDate),
            statusRawValue: backup.status,
            isAutoRenewing: backup.isAutoRenewing,
            cancelByDate: backup.cancelByDate,
            reminderOffsets: backup.reminderOffsets,
            managementURLString: backup.managementURLString,
            notes: backup.notes,
            createdAt: exportedAt,
            updatedAt: exportedAt
        )
    }
}
