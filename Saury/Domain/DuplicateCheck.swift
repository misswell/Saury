import Foundation

/// 「这是同一件商品」的判定（方案 §30）。有条码按条码，没条码退回名称。
/// 首页的批次分组和保存前的重复提示必须用同一套规则，否则一边算出「2 批」、
/// 另一边说「不重复」。
enum ProductIdentity {
    static func key(barcode: String?, name: String) -> String {
        let code = barcode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !code.isEmpty { return "barcode:\(code)" }
        return "name:\(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }
}

/// 一次保存要拿去比对的东西。
struct ExpiryDuplicateCandidate: Hashable {
    let productKey: String
    let expiryDate: Date
    let batchNumber: String?
}

/// 保存前的重复检测（方案 §29）。
enum ExpiryDuplicateCheck {
    static func candidate(barcode: String?, name: String, expiryDate: Date, batchNumber: String?) -> ExpiryDuplicateCandidate {
        ExpiryDuplicateCandidate(
            productKey: ProductIdentity.key(barcode: barcode, name: name),
            expiryDate: expiryDate,
            batchNumber: batchNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func candidate(for item: ExpiryItem) -> ExpiryDuplicateCandidate {
        candidate(barcode: item.barcode, name: item.name, expiryDate: item.expiryDate, batchNumber: item.batchNumber)
    }

    /// 同一批：商品相同、到期日同一天、批次号相同（两边都没写批次号也算相同 ——
    /// 同一盒牛奶记两次不叫新增一批）。已经处理掉的那些不算，它们不再占提醒额度。
    static func match(
        _ candidate: ExpiryDuplicateCandidate,
        in items: [ExpiryItem],
        excluding id: UUID? = nil,
        calendar: Calendar = ExpiryEngine.calendar
    ) -> ExpiryItem? {
        items.first { item in
            guard item.id != id, item.state.isTracked else { return false }
            guard ProductIdentity.key(barcode: item.barcode, name: item.name) == candidate.productKey else { return false }
            guard calendar.isDate(item.expiryDate, inSameDayAs: candidate.expiryDate) else { return false }
            return normalized(item.batchNumber) == normalized(candidate.batchNumber)
        }
    }

    private static func normalized(_ batch: String?) -> String? {
        guard let batch else { return nil }
        let trimmed = batch.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }
}
