import Foundation

/// 一次扫描存下来的东西（方案 §20、§25、§34）。
///
/// 物品和它的事件在同一个地方建，两条录入路径（表单确认、连续扫描）才不会一条
/// 写历史一条不写。领域层碰不到 UIKit，所以这里只接图片文件名 —— 写盘由
/// `ImageStore` 在 Services 里做完。
extension ExpiryItem {
    /// 没认到到期日就返回 nil：一条没有日期的物品在期见里不成立。
    ///
    /// 返回的事件和物品共用同一个 `imageIdentifier`：一份文件两处引用。
    /// 所以撤销、删物品都不许去删图片文件 —— 历史还得靠它回放。
    static func scannedRecord(
        _ result: ExpiryOCRResult,
        imageIdentifier: String?,
        openedToday: Bool,
        template: ProductTemplate? = nil,
        quantity: Double = 1,
        now: Date = Date()
    ) -> (item: ExpiryItem, event: ExpiryEvent)? {
        guard let expiryDate = result.date(for: .expiryDate) else { return nil }
        let amount = result.amount(for: .amount)
        let item = ExpiryItem(
            name: text(result.text(for: .name)) ?? text(template?.name) ?? "扫到的物品",
            brand: text(result.text(for: .brand)) ?? text(template?.brand),
            category: template?.category ?? .other,
            expiryDate: expiryDate,
            manufactureDate: result.date(for: .manufactureDate),
            openedDate: openedToday ? now : nil,
            shelfLifeDays: result.duration(for: .shelfLife)?.approxDays,
            afterOpeningDays: result.duration(for: .afterOpening)?.approxDays,
            barcode: text(result.text(for: .barcode)) ?? text(template?.barcode),
            batchNumber: text(result.text(for: .batchNumber)),
            quantity: max(quantity, 1),
            unit: text(template?.unit) ?? "件",
            location: text(template?.location),
            priceMinorUnits: amount?.minorUnits,
            currencyCode: amount?.currencyCode,
            imageIdentifier: imageIdentifier,
            reminderOffsets: template?.reminderOffsets,
            notes: "",
            createdAt: now
        )
        return (item, ExpiryEvent(eventType: .created, for: item, happenedAt: now, imageIdentifier: imageIdentifier))
    }

    /// 同一批又扫到一次：只加数量，另留一条带原图的事件（方案 §29 连续模式）。
    /// 物品上那张图留着不覆盖，历史里的每一次扫描各自看得回来。
    func absorb(_ scanned: ExpiryItem, imageIdentifier: String?, now: Date = Date()) -> ExpiryEvent {
        quantity += scanned.quantity
        markUpdated()
        return ExpiryEvent(eventType: .edited, for: self, happenedAt: now, imageIdentifier: imageIdentifier)
    }

    /// 空字符串按「没认到」处理：OCR 给个空白不代表用户说了什么。
    private static func text(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
