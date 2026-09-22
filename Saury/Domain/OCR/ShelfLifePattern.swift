import Foundation

/// 「保质期 30 天」「12 个月」「一年」「开盖后 6M」这类时长的读法（方案 §23、§24）。
enum ShelfLifePattern {
    /// 数字（阿拉伯或中文）+ 单位。整段里取第一个匹配。
    static func parse(_ text: String) -> ShelfLife? {
        if text.contains("半年") { return ShelfLife(amount: 6, unit: .month) }
        let pattern = #"(\d{1,4}|[一二两三四五六七八九十]{1,3})\s*(个月|月|星期|周|年|天|日|years?|yrs?|months?|mos?|weeks?|wks?|days?|d)(?![A-Za-z])"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let span = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: span),
              match.numberOfRanges >= 3,
              let amountRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text) else { return nil }
        guard let amount = amount(String(text[amountRange])),
              let unit = unit(String(text[unitRange])) else { return nil }
        guard amount > 0, amount <= 100_000 else { return nil }
        return ShelfLife(amount: amount, unit: unit)
    }

    /// 开盖图标旁的 PAO 符号：`6M`、`12 M`、`24M`。只认大写 M，
    /// 否则 `500ml`、`12mg` 这类规格会被当成十二个月。
    static func parsePeriodAfterOpening(_ text: String) -> ShelfLife? {
        let pattern = #"(?<![\dA-Za-z])(\d{1,2})\s*M(?![A-Za-z0-9])"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let span = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: span),
              let amountRange = Range(match.range(at: 1), in: text),
              let amount = Int(text[amountRange]) else { return nil }
        guard amount > 0 else { return nil }
        return ShelfLife(amount: amount, unit: .month)
    }

    private static func amount(_ text: String) -> Int? {
        if let digits = Int(text) { return digits }
        return ChineseNumeral.value(text[text.startIndex...])
    }

    private static func unit(_ text: String) -> ShelfLife.Unit? {
        let key = text.lowercased()
        switch key {
        case "天", "日", "day", "days", "d": return .day
        case "周", "个星期", "星期", "week", "weeks", "wk", "wks", "w": return .week
        case "个月", "月", "month", "months", "mo", "mos", "m": return .month
        case "年", "year", "years", "yr", "yrs", "y": return .year
        default: return nil
        }
    }
}
