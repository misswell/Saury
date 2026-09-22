import Foundation

/// 「30 天」「12 个月」「一年」这类时长（方案 §23、§24）。
///
/// 单位保留原始月份/年份，因为「生产日期 + 12 个月」要用日历加法算；
/// 存进 `ExpiryItem.shelfLifeDays` 时才折算成近似天数 —— 那是给用户看的参考值，
/// 真正决定紧急度的是确认过的到期日。
struct ShelfLife: Hashable {
    enum Unit: String, CaseIterable, Hashable {
        case day
        case week
        case month
        case year

        var title: String {
            switch self {
            case .day: return "天"
            case .week: return "周"
            case .month: return "个月"
            case .year: return "年"
            }
        }

        var approxDays: Int {
            switch self {
            case .day: return 1
            case .week: return 7
            case .month: return 30
            case .year: return 365
            }
        }
    }

    let amount: Int
    let unit: Unit

    init(amount: Int, unit: Unit) {
        self.amount = amount
        self.unit = unit
    }

    var title: String { "\(amount)\(unit.title)" }

    var approxDays: Int { amount * unit.approxDays }

    /// 从参考日往后推这段保质期。月份按日历走，2026-09-01 + 12 个月是 2027-09-01，
    /// 不是 2027-08-31。
    func date(after reference: Date, calendar: Calendar = ExpiryEngine.calendar) -> Date? {
        switch unit {
        case .day: return calendar.date(byAdding: .day, value: amount, to: reference)
        case .week: return calendar.date(byAdding: .weekOfYear, value: amount, to: reference)
        case .month: return calendar.date(byAdding: .month, value: amount, to: reference)
        case .year: return calendar.date(byAdding: .year, value: amount, to: reference)
        }
    }
}

/// 金额：分 + 币种。包装上常见的是「￥29.90」这类带符号的价格。
struct OCRAmount: Hashable {
    var minorUnits: Int
    var currencyCode: String

    var text: String { QJMoney.text(minorUnits, currencyCode: currencyCode) }
}

/// 中文数字。包装上「保质期一年」「开封后陆个月内」都会写汉字，只认阿拉伯数字会漏。
enum ChineseNumeral {
    /// 认 1…99，够覆盖「七天」「三十天」「九十九天」；更大的数量级不值得为识别去兜圈。
    static func value(_ text: Substring) -> Int? {
        let digits: [Character: Int] = [
            "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
        ]
        let characters = Array(text)
        if characters.isEmpty { return nil }
        if characters == ["十"] { return 10 }
        if let first = characters.first, first == "十", characters.count == 2, let tail = digits[characters[1]] {
            return 10 + tail
        }
        if characters.count == 1 { return digits[characters[0]] }
        if characters.count == 3, characters[1] == "十", let head = digits[characters[0]], let tail = digits[characters[2]] {
            return head * 10 + tail
        }
        if characters.count == 2, let head = digits[characters[0]], characters[1] == "十" {
            return head * 10
        }
        return nil
    }
}
