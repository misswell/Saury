import Foundation
import SwiftData

/// 扫过一次的商品信息（方案 §28）。同一个条码第二次出现时，名称、分类、位置、单位
/// 都从这儿来，用户只需要再填有效期和数量。完全本机，不查任何网络商品库。
@Model
final class ProductTemplate {
    @Attribute(.unique) var barcode: String
    var name: String
    var brand: String?
    var categoryRawValue: String
    var location: String?
    var unit: String
    var defaultReminderOffsetsData: Data
    var createdAt: Date
    var updatedAt: Date

    init(
        barcode: String,
        name: String,
        brand: String? = nil,
        category: ExpiryCategory = .other,
        location: String? = nil,
        unit: String = "件",
        reminderOffsets: [Int]? = nil,
        createdAt: Date = Date()
    ) {
        self.barcode = barcode
        self.name = name
        self.brand = brand
        self.categoryRawValue = category.rawValue
        self.location = location
        self.unit = unit
        self.defaultReminderOffsetsData = (try? JSONEncoder().encode(
            reminderOffsets ?? ReminderPolicy.defaultOffsets(for: category)
        )) ?? Data()
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    var category: ExpiryCategory {
        get { ExpiryCategory(rawValue: categoryRawValue) ?? .other }
        set { categoryRawValue = newValue.rawValue }
    }

    var reminderOffsets: [Int] {
        get { (try? JSONDecoder().decode([Int].self, from: defaultReminderOffsetsData)) ?? ReminderPolicy.defaultOffsets(for: category) }
        set { defaultReminderOffsetsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}

extension ProductTemplate {
    /// 模板跟着最后一次正确的输入走。
    func refresh(name: String, brand: String?, category: ExpiryCategory, location: String?, unit: String, reminderOffsets: [Int]) {
        self.name = name
        self.brand = brand
        self.category = category
        self.location = location
        self.unit = unit
        self.reminderOffsets = reminderOffsets
        updatedAt = Date()
    }

    /// 条码里的空格是扫码枪和 OCR 带的，不是编码的一部分。
    static func normalized(_ barcode: String?) -> String? {
        guard let barcode else { return nil }
        let trimmed = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 模板表的三件事：按条码找、把刚保存的商品记下来、以及给表单当默认值。
enum ProductTemplateStore {
    static func template(forBarcode barcode: String?, in context: ModelContext) -> ProductTemplate? {
        guard let barcode = ProductTemplate.normalized(barcode) else { return nil }
        let descriptor = FetchDescriptor<ProductTemplate>(predicate: #Predicate { $0.barcode == barcode })
        return try? context.fetch(descriptor).first
    }

    /// 每次保存商品都顺手更新。没有条码就没有稳定的身份，不建模板（方案 §28）。
    @discardableResult
    static func remember(
        barcode: String?,
        name: String,
        brand: String?,
        category: ExpiryCategory,
        location: String?,
        unit: String,
        reminderOffsets: [Int],
        in context: ModelContext
    ) -> ProductTemplate? {
        guard let barcode = ProductTemplate.normalized(barcode) else { return nil }
        if let existing = template(forBarcode: barcode, in: context) {
            existing.refresh(name: name, brand: brand, category: category,
                             location: location, unit: unit, reminderOffsets: reminderOffsets)
            return existing
        }
        let made = ProductTemplate(barcode: barcode, name: name, brand: brand, category: category,
                                   location: location, unit: unit, reminderOffsets: reminderOffsets)
        context.insert(made)
        return made
    }

    @discardableResult
    static func remember(_ item: ExpiryItem, in context: ModelContext) -> ProductTemplate? {
        remember(barcode: item.barcode, name: item.name, brand: item.brand, category: item.category,
                 location: item.location, unit: item.unit, reminderOffsets: item.reminderOffsets, in: context)
    }
}
