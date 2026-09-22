import Foundation
import SwiftData

/// 一条「会过期的东西」（方案 §8）。除名称和有效期外全部可选：
/// 期见不是库存 ERP，扫描后只需确认两件事就能保存。
@Model
final class ExpiryItem {
    @Attribute(.unique) var id: UUID

    // 基础
    var name: String
    var brand: String?
    var categoryRawValue: String

    // 日期
    var expiryDate: Date
    var manufactureDate: Date?
    var purchaseDate: Date?
    var openedDate: Date?

    // 保质期
    var shelfLifeDays: Int?
    var afterOpeningDays: Int?

    // 商品
    var barcode: String?
    var batchNumber: String?

    // 数量
    var quantity: Double
    var unit: String

    // 位置
    var location: String?

    // 金额
    var priceMinorUnits: Int?
    var currencyCode: String?

    // 重复
    var recurrenceRawValue: String
    var recurrenceInterval: Int?
    /// 推进周期时用的锚点日。它只在创建和手动改期时跟随到期日，续费不覆盖：
    /// 1 月 31 日的月付被钳到 2 月 28 日之后，下一次仍要回到 31 日。
    var anchorDay: Int

    // 操作截止日
    var actionDeadline: Date?

    // URL
    var sourceURL: String?

    // 图片
    var imageIdentifier: String?

    // 提醒
    var reminderOffsetsData: Data

    // 用户状态
    var stateRawValue: String

    var notes: String

    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        brand: String? = nil,
        category: ExpiryCategory = .other,
        expiryDate: Date,
        manufactureDate: Date? = nil,
        purchaseDate: Date? = nil,
        openedDate: Date? = nil,
        shelfLifeDays: Int? = nil,
        afterOpeningDays: Int? = nil,
        barcode: String? = nil,
        batchNumber: String? = nil,
        quantity: Double = 1,
        unit: String = "件",
        location: String? = nil,
        priceMinorUnits: Int? = nil,
        currencyCode: String? = nil,
        recurrence: ExpiryRecurrence = .none,
        recurrenceInterval: Int? = nil,
        anchorDay: Int? = nil,
        actionDeadline: Date? = nil,
        sourceURL: String? = nil,
        imageIdentifier: String? = nil,
        reminderOffsets: [Int]? = nil,
        state: ExpiryState = .active,
        notes: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.brand = brand
        self.categoryRawValue = category.rawValue
        self.expiryDate = expiryDate
        self.manufactureDate = manufactureDate
        self.purchaseDate = purchaseDate
        self.openedDate = openedDate
        self.shelfLifeDays = shelfLifeDays
        self.afterOpeningDays = afterOpeningDays
        self.barcode = barcode
        self.batchNumber = batchNumber
        self.quantity = quantity
        self.unit = unit
        self.location = location
        self.priceMinorUnits = priceMinorUnits.map { max($0, 0) }
        self.currencyCode = currencyCode
        self.recurrenceRawValue = recurrence.rawValue
        self.recurrenceInterval = recurrenceInterval
        self.anchorDay = anchorDay ?? ExpiryEngine.calendar.component(.day, from: expiryDate) ?? 1
        self.actionDeadline = actionDeadline
        self.sourceURL = sourceURL
        self.imageIdentifier = imageIdentifier
        self.stateRawValue = state.rawValue
        self.notes = notes
        self.reminderOffsetsData = (try? JSONEncoder().encode(
            reminderOffsets ?? ReminderPolicy.defaultOffsets(for: category)
        )) ?? Data()
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    var category: ExpiryCategory {
        get { ExpiryCategory(rawValue: categoryRawValue) ?? .other }
        set { categoryRawValue = newValue.rawValue; updatedAt = Date() }
    }

    var state: ExpiryState {
        get { ExpiryState(rawValue: stateRawValue) ?? .active }
        set { stateRawValue = newValue.rawValue; updatedAt = Date() }
    }

    var recurrence: ExpiryRecurrence {
        get { ExpiryRecurrence(rawValue: recurrenceRawValue) ?? .none }
        set { recurrenceRawValue = newValue.rawValue; updatedAt = Date() }
    }

    var reminderOffsets: [Int] {
        get { (try? JSONDecoder().decode([Int].self, from: reminderOffsetsData)) ?? ReminderPolicy.defaultOffsets(for: category) }
        set { reminderOffsetsData = (try? JSONEncoder().encode(newValue)) ?? Data(); updatedAt = Date() }
    }

    /// 推进到下一次到期时使用的间隔月数：自定义周期存的是用户填的月数。
    var recurrenceMonths: Int? {
        switch recurrence {
        case .custom: return max(recurrenceInterval ?? 1, 1)
        default: return recurrence.intervalMonths
        }
    }

    var isActive: Bool { state.isTracked }

    var hasPrice: Bool { priceMinorUnits != nil }

    /// 同一件商品的分组键（方案 §30）。有条码按条码，没条码退回名称：
    /// 第一阶段不建 Product/Batch 两张表，UI 靠这个键把批次挨在一起。
    var productKey: String {
        ProductIdentity.key(barcode: barcode, name: name)
    }

    func markUpdated() { updatedAt = Date() }
}

extension ExpiryItem {
    /// 首次启动的示例数据。刻意覆盖每个紧急度档位，以及同一件商品的多个批次，
    /// 这样新机器上打开首页就能看到分组和位置长什么样。
    static func previewItems(referenceDate: Date = Date()) -> [ExpiryItem] {
        let calendar = ExpiryEngine.calendar
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: referenceDate) ?? referenceDate }
        let milkBarcode = "6901234567890"
        return [
            ExpiryItem(name: "酸奶", category: .food, expiryDate: day(-2), quantity: 3, unit: "杯", location: "冰箱"),
            ExpiryItem(name: "感冒灵", category: .medicine, expiryDate: day(0), quantity: 1, unit: "盒", location: "药箱"),
            ExpiryItem(name: "面包", category: .food, expiryDate: day(1), quantity: 1, unit: "袋", location: "厨房"),
            ExpiryItem(name: "纯牛奶 1L", brand: "蒙牛", category: .food, expiryDate: day(3), barcode: milkBarcode, batchNumber: "A20260901", quantity: 2, unit: "盒", location: "冰箱"),
            ExpiryItem(name: "纯牛奶 1L", brand: "蒙牛", category: .food, expiryDate: day(11), barcode: milkBarcode, batchNumber: "A20260910", quantity: 4, unit: "盒", location: "冰箱"),
            ExpiryItem(name: "面霜", category: .skincare, expiryDate: day(6), openedDate: day(-40), afterOpeningDays: 90, quantity: 1, unit: "罐", location: "浴室"),
            ExpiryItem(name: "云储存 200GB", category: .subscription, expiryDate: day(13), priceMinorUnits: 2100, currencyCode: "CNY", recurrence: .monthly),
            ExpiryItem(name: "音乐会员", category: .subscription, expiryDate: day(28), priceMinorUnits: 1500, currencyCode: "CNY", recurrence: .monthly),
            ExpiryItem(name: "布洛芬", category: .medicine, expiryDate: day(280), quantity: 1, unit: "盒", location: "药箱"),
            ExpiryItem(name: "护照", category: .document, expiryDate: day(120), location: "书房")
        ]
    }
}
