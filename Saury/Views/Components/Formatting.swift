import Foundation

enum QJFormatters {
    static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日"
        return formatter
    }()

    static let weekdayDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日 · EEEE"
        return formatter
    }()

    static let shortDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日 HH:mm"
        return formatter
    }()

    /// 扫描确认界面必须带年份：包装上「2027 年 3 月」和「今年 3 月」是两回事。
    static let yearDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy 年 M 月 d 日"
        return formatter
    }()
}

extension Date {
    var qjDateText: String { QJFormatters.date.string(from: self) }
    var qjWeekdayDateText: String { QJFormatters.weekdayDate.string(from: self) }
    var qjShortDateTimeText: String { QJFormatters.shortDateTime.string(from: self) }
}

enum QJMoney {
    /// 把「分」渲染成带币种的金额。用 Decimal 换算，避免 19.99 变成 19.98。
    static func text(_ minorUnits: Int, currencyCode: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.locale = locale(for: currencyCode)
        return formatter.string(from: NSDecimalNumber(decimal: Decimal(minorUnits) / 100)) ?? "\(currencyCode) 0.00"
    }

    /// 解析用户输入的元金额。按币种所在区域理解千分位和小数点，四舍五入到分。
    static func minorUnits(from text: String, currencyCode: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale(for: currencyCode)
        let yuan = formatter.number(from: trimmed)?.decimalValue ?? Decimal(string: trimmed) ?? 0
        let cents = NSDecimalNumber(decimal: yuan)
            .multiplying(by: NSDecimalNumber(value: 100))
            .rounding(accordingToBehavior: centsRounding)
        return Swift.max(Int(cents.int64Value), 0)
    }

    private static let centsRounding = NSDecimalNumberHandler(
        roundingMode: .plain,
        scale: 0,
        raiseOnExactness: false,
        raiseOnOverflow: false,
        raiseOnUnderflow: false,
        raiseOnDivideByZero: false
    )

    static func minorUnits(fromYuan yuan: Double) -> Int {
        max(Int((yuan * 100).rounded()), 0)
    }

    static func locale(for currencyCode: String) -> Locale {
        switch currencyCode {
        case "USD": return Locale(identifier: "en_US")
        case "HKD": return Locale(identifier: "zh_HK")
        default: return Locale(identifier: "zh_CN")
        }
    }

    /// 展示顺序：人民币、美元、港币，其余按字典序。
    static func rank(_ currencyCode: String) -> Int {
        switch currencyCode {
        case "CNY": return 0
        case "USD": return 1
        case "HKD": return 2
        default: return 3
        }
    }
}

/// 跨币种累加。不同币种的金额永远不互相相加，只在同一币种内求和。
struct QJSpendSummary {
    private(set) var totals: [String: Int] = [:]

    mutating func add(_ minorUnits: Int, currencyCode: String) {
        totals[currencyCode, default: 0] += minorUnits
    }

    /// 按每月均摊口径累加一条记录。没记价格的物品不参与均摊。
    mutating func addMonthlyEquivalent(of item: ExpiryItem) {
        guard item.hasPrice else { return }
        add(item.monthlyEquivalentMinorUnits, currencyCode: item.currencyCode ?? QJPreferences.defaultCurrencyCode)
    }

    mutating func add(_ other: QJSpendSummary) {
        for (code, value) in other.totals { add(value, currencyCode: code) }
    }

    var isEmpty: Bool { totals.values.allSatisfy { $0 == 0 } }

    func amount(in currencyCode: String) -> Int { totals[currencyCode] ?? 0 }

    /// 金额最大的币种，用于在同类之间比较占比。
    var primaryCurrency: String { totals.max { $0.value < $1.value }?.key ?? "CNY" }

    var text: String {
        let parts = totals
            .filter { $0.value != 0 }
            .sorted { (QJMoney.rank($0.key), $1.key) < (QJMoney.rank($1.key), $0.key) }
            .map { QJMoney.text($0.value, currencyCode: $0.key) }
        return parts.isEmpty ? QJMoney.text(0, currencyCode: "CNY") : parts.joined(separator: " · ")
    }
}

extension ExpiryItem {
    /// 数量写法：整数不带小数点，半瓶就显示 0.5。
    var quantityText: String {
        quantity == quantity.rounded() ? String(Int(quantity)) : String(format: "%.1f", quantity)
    }

    /// 列表副标题。只有会再发生的物品才写周期，一盒牛奶不该出现「不重复」。
    var subtitleText: String {
        recurrence.isRecurring ? "\(category.title) · \(recurrence.title)" : category.title
    }

    /// 列表副标题：分类打头，后面跟用户真正会用来找它的东西（方案 §33）。
    var contextText: String {
        var parts = [subtitleText]
        if let location, !location.isEmpty { parts.append(location) }
        if quantity != 1 || unit != "件" { parts.append("\(quantityText) \(unit)") }
        return parts.joined(separator: " · ")
    }

    /// 调用方应先用 `hasPrice` 判断；这里只在漏判时给出中性文案而不是「¥0.00」。
    var formattedPrice: String {
        guard let price = priceMinorUnits else { return "未记录" }
        return QJMoney.text(price, currencyCode: currencyCode ?? QJPreferences.defaultCurrencyCode)
    }

    /// 折算成「每月」金额，用于均摊口径。一次性物品按当月支出计。
    var monthlyEquivalentMinorUnits: Int {
        guard let price = priceMinorUnits else { return 0 }
        switch recurrence {
        case .none: return price
        case .weekly: return price * 4
        case .monthly: return price
        case .quarterly: return price / 3
        case .everySixMonths: return price / 6
        case .yearly: return price / 12
        case .custom: return price / max(recurrenceMonths ?? 1, 1)
        }
    }
}
