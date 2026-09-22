import CoreGraphics
import Foundation

/// 一个识别出来的值。四种类型收在一起，确认界面才能用同一套列表渲染
/// 而不用给每个字段写一份分支。
enum ExpiryOCRValue: Hashable {
    case text(String)
    case date(Date, alternatives: [Date])
    case duration(ShelfLife)
    case amount(OCRAmount)

    var displayText: String {
        switch self {
        case .text(let value): return value
        case .date(let date, _): return QJFormatters.yearDate.string(from: date)
        case .duration(let life): return life.title
        case .amount(let amount): return amount.text
        }
    }

    var textValue: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    var dateValue: Date? {
        if case .date(let value, _) = self { return value }
        return nil
    }

    var durationValue: ShelfLife? {
        if case .duration(let value) = self { return value }
        return nil
    }

    var amountValue: OCRAmount? {
        if case .amount(let value) = self { return value }
        return nil
    }

    /// 同一处文字的第二种读法，界面上给一键换过来。
    var alternatives: [ExpiryOCRValue] {
        switch self {
        case .date(_, let dates): return dates.map { .date($0, alternatives: []) }
        default: return []
        }
    }
}

/// 一个字段的一条识别结果（方案 §25）。`value` 可改：确认界面的全部意义就是让人把它掰对。
struct ExpiryOCRCandidate: Identifiable, Hashable {
    let id: UUID
    let field: ExpiryOCRField
    var value: ExpiryOCRValue
    var confidence: Double
    var boundingBox: CGRect?
    var reasons: [String]
    var sources: Set<ExpirySource>

    init(
        id: UUID = UUID(),
        field: ExpiryOCRField,
        value: ExpiryOCRValue,
        confidence: Double,
        boundingBox: CGRect? = nil,
        reasons: [String] = [],
        sources: Set<ExpirySource> = [.optical]
    ) {
        self.id = id
        self.field = field
        self.value = value
        self.confidence = min(max(confidence, 0), 1)
        self.boundingBox = boundingBox
        self.reasons = reasons
        self.sources = sources
    }

    var confidenceText: String { "\(Int((confidence * 100).rounded()))%" }

    var needsConfirmation: Bool { confidence < ExpiryOCRThresholds.confirmation }

    var alternatives: [ExpiryOCRValue] { value.alternatives }

    /// 一行说明为什么信或不信：来源 + 格式 + 警语。
    var explanation: String {
        var parts = sources.sorted { $0.rawValue < $1.rawValue }.map(\.explanation)
        parts.append(contentsOf: reasons)
        return parts.joined(separator: " · ")
    }

    mutating func markConfirmed(with newValue: ExpiryOCRValue) {
        self.value = newValue
        confidence = 1
        sources.insert(.manual)
    }
}

/// 一次扫描的完整结论（方案 §25）。
struct ExpiryOCRResult: Hashable {
    var entries: [ExpiryOCRCandidate]
    /// 界面上要交代给用户的推理，比如「到期日由生产日期 + 保质期推算」。
    var notes: [String]

    init(entries: [ExpiryOCRCandidate] = [], notes: [String] = []) {
        // 低到不如不填的结果直接丢掉：宁可让人手输，也不要把 500ml 认成日期。
        self.entries = entries
            .filter { $0.confidence >= ExpiryOCRThresholds.discard }
            .sorted { $0.field < $1.field }
        self.notes = notes
    }

    static let empty = ExpiryOCRResult()

    var isEmpty: Bool { entries.isEmpty }

    func candidate(for field: ExpiryOCRField) -> ExpiryOCRCandidate? {
        entries.first { $0.field == field }
    }

    func date(for field: ExpiryOCRField) -> Date? { candidate(for: field)?.value.dateValue }
    func text(for field: ExpiryOCRField) -> String? { candidate(for: field)?.value.textValue }
    func duration(for field: ExpiryOCRField) -> ShelfLife? { candidate(for: field)?.value.durationValue }
    func amount(for field: ExpiryOCRField) -> OCRAmount? { candidate(for: field)?.value.amountValue }

    var needsConfirmationCount: Int { entries.filter(\.needsConfirmation).count }

    var needsConfirmation: Bool { needsConfirmationCount > 0 }

    /// 用户在确认界面上改过的字段。
    var manuallyConfirmedFields: Set<ExpiryOCRField> {
        Set(entries.filter { $0.sources.contains(.manual) }.map(\.field))
    }

    /// 替换或插入一个字段的结果。一个字段只留一个值，其余的都是候选。
    func setting(_ candidate: ExpiryOCRCandidate) -> ExpiryOCRResult {
        var copy = self
        if let index = copy.entries.firstIndex(where: { $0.field == candidate.field }) {
            copy.entries[index] = candidate
        } else {
            copy.entries.append(candidate)
        }
        copy.entries.sort { $0.field < $1.field }
        return copy
    }

    /// 原图上要框出来的位置（方案 §26）。
    var boxes: [(field: ExpiryOCRField, boundingBox: CGRect)] {
        entries.compactMap { candidate in
            candidate.boundingBox.map { (candidate.field, $0) }
        }
    }
}
