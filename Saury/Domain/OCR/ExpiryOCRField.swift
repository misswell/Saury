import CoreGraphics
import Foundation

/// 一次扫描要认出来的字段（方案 §21）。
enum ExpiryOCRField: String, CaseIterable, Identifiable, Comparable {
    case name
    case brand
    case expiryDate
    case manufactureDate
    case shelfLife
    case afterOpening
    case batchNumber
    case barcode
    case amount

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "名称"
        case .brand: return "品牌"
        case .expiryDate: return "有效日期"
        case .manufactureDate: return "生产日期"
        case .shelfLife: return "保质期"
        case .afterOpening: return "开封后有效期"
        case .batchNumber: return "批次号"
        case .barcode: return "条码"
        case .amount: return "金额"
        }
    }

    /// 确认界面里的固定顺序：先结论（什么时候过期），再依据（日期、期限），最后杂项。
    static let reviewOrder: [ExpiryOCRField] = [
        .name, .brand, .expiryDate, .manufactureDate, .shelfLife, .afterOpening, .batchNumber, .barcode, .amount
    ]

    static func < (lhs: ExpiryOCRField, rhs: ExpiryOCRField) -> Bool {
        let order = reviewOrder
        return (order.firstIndex(of: lhs) ?? order.count) < (order.firstIndex(of: rhs) ?? order.count)
    }
}

/// 一个字段是读来的、算来的、还是从条码符号认出来的（方案 §25、§23、§24）。
enum ExpirySource: String, Hashable {
    case optical        // 光学识别到的文字
    case barcodeSymbol  // 条码符号本身
    case derived        // 由别的字段推算
    case heuristic      // 启发式（挑名称、挑品牌）
    case manual         // 用户在确认界面上改过

    var explanation: String {
        switch self {
        case .optical: return "识别自包装文字"
        case .barcodeSymbol: return "识别自条码"
        case .derived: return "由生产日期和保质期推算"
        case .heuristic: return "按位置和字号推断"
        case .manual: return "手动确认"
        }
    }
}

/// 置信度低于这条线就要用户确认（方案 §25「低置信度：需要确认」）。
/// 0.75 的意义：一条既没有关键字、格式也不标准的日子必须问一句；
/// 而「有效期至 2026.10.12」这种同关键字 + ISO 格式能到 0.9 以上。
///
/// 方案 §25 写的是 `OCRCandidate<T>`。这里落地成 `ExpiryOCRCandidate`（值用枚举装），
/// 因为确认界面要在一张列表里同时渲染日期、时长、文字和金额 —— 泛型参数在界面上没法统一。
enum ExpiryOCRThresholds {
    static let confirmation = 0.75
    /// 再低就不如不填：宁可让人手输，也不要把 500ml 认成日期。
    static let discard = 0.28
}
