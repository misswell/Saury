import Foundation

/// 金额 = 最小单位 + 币种。格式化、换算都从这一处走，
/// 列表、统计、小票用的是同一套数字。
struct Money: Equatable, Hashable, Codable {
    var minorUnits: Int
    var currencyCode: String

    init(minorUnits: Int, currencyCode: String) {
        self.minorUnits = minorUnits
        self.currencyCode = currencyCode
    }

    init(majorUnits: Double, currencyCode: String) {
        self.minorUnits = Int((majorUnits * 100).rounded())
        self.currencyCode = currencyCode
    }

    var majorValue: Double { Double(minorUnits) / 100 }

    /// ¥134.14 / $20.00 / £9.99。零钱后两位总保留，好看也齐整。
    var formatted: String {
        Self.format(minorUnits: minorUnits, currencyCode: currencyCode)
    }

    /// 大数字场景（总览的巨额总数）：¥2,425.64 一样带千分位。
    var formattedGrouped: String {
        Self.format(minorUnits: minorUnits, currencyCode: currencyCode, grouped: true)
    }

    static func format(minorUnits: Int, currencyCode: String, grouped: Bool = false) -> String {
        let symbol = CurrencyCatalog.symbol(for: currencyCode)
        let negative = minorUnits < 0
        let cents = abs(minorUnits)
        let major = cents / 100
        let fraction = cents % 100
        var majorText: String
        if grouped, major >= 1000 {
            majorText = String(major)
            var groupedText = ""
            while majorText.count > 3 {
                let cutIndex = majorText.index(majorText.endIndex, offsetBy: -3)
                groupedText = "," + majorText[cutIndex...] + groupedText
                majorText = String(majorText[..<cutIndex])
            }
            majorText = majorText + groupedText
        } else {
            majorText = String(major)
        }
        let sign = negative ? "-" : ""
        return "\(sign)\(symbol)\(majorText).\(String(format: "%02d", fraction))"
    }

    /// 换算到目标币种。没有汇率时按 1:1 兜底，宁可数字不动也不显示 0。
    func converting(to targetCode: String, rates: [String: Double]) -> Money {
        guard currencyCode != targetCode else { return self }
        let fromRate = rates[currencyCode] ?? 1
        let toRate = rates[targetCode] ?? 1
        guard fromRate > 0 else { return self }
        let converted = Double(minorUnits) * toRate / fromRate
        return Money(minorUnits: Int(converted.rounded()), currencyCode: targetCode)
    }

    static func zero(_ code: String) -> Money { Money(minorUnits: 0, currencyCode: code) }

    static func + (lhs: Money, rhs: Money) -> Money {
        Money(minorUnits: lhs.minorUnits + rhs.minorUnits, currencyCode: lhs.currencyCode)
    }
}

/// 币种目录：代码、符号、中文名。选择器里的顺序就按这份表排。
enum CurrencyCatalog {
    struct Entry: Identifiable, Hashable {
        let code: String
        let symbol: String
        let name: String

        var id: String { code }
        var listTitle: String { "\(code) · \(name)" }
    }

    static let all: [Entry] = [
        Entry(code: "CNY", symbol: "¥", name: "人民币"),
        Entry(code: "USD", symbol: "$", name: "美元"),
        Entry(code: "EUR", symbol: "€", name: "欧元"),
        Entry(code: "GBP", symbol: "£", name: "英镑"),
        Entry(code: "JPY", symbol: "¥", name: "日元"),
        Entry(code: "KRW", symbol: "₩", name: "韩元"),
        Entry(code: "HKD", symbol: "HK$", name: "港币"),
        Entry(code: "TWD", symbol: "NT$", name: "新台币"),
        Entry(code: "AUD", symbol: "A$", name: "澳元"),
        Entry(code: "NZD", symbol: "NZ$", name: "新西兰元"),
        Entry(code: "CAD", symbol: "C$", name: "加元"),
        Entry(code: "CHF", symbol: "CHF", name: "瑞士法郎"),
        Entry(code: "SGD", symbol: "S$", name: "新加坡元"),
        Entry(code: "THB", symbol: "฿", name: "泰铢"),
        Entry(code: "MYR", symbol: "RM", name: "马来西亚林吉特"),
        Entry(code: "VND", symbol: "₫", name: "越南盾"),
        Entry(code: "PHP", symbol: "₱", name: "菲律宾比索"),
        Entry(code: "IDR", symbol: "Rp", name: "印尼盾"),
        Entry(code: "INR", symbol: "₹", name: "印度卢比"),
        Entry(code: "RUB", symbol: "₽", name: "俄罗斯卢布"),
        Entry(code: "TRY", symbol: "₺", name: "土耳其里拉"),
        Entry(code: "BRL", symbol: "R$", name: "巴西雷亚尔"),
        Entry(code: "MXN", symbol: "Mex$", name: "墨西哥比索"),
        Entry(code: "ARS", symbol: "AR$", name: "阿根廷比索"),
        Entry(code: "CLP", symbol: "CLP$", name: "智利比索"),
        Entry(code: "COP", symbol: "COL$", name: "哥伦比亚比索"),
        Entry(code: "AED", symbol: "د.إ", name: "阿联酋迪拉姆"),
        Entry(code: "SAR", symbol: "﷼", name: "沙特里亚尔"),
        Entry(code: "QAR", symbol: "QR", name: "卡塔尔里亚尔"),
        Entry(code: "ILS", symbol: "₪", name: "以色列新谢克尔"),
        Entry(code: "EGP", symbol: "E£", name: "埃及镑"),
        Entry(code: "ZAR", symbol: "R", name: "南非兰特"),
        Entry(code: "NGN", symbol: "₦", name: "尼日利亚奈拉"),
        Entry(code: "SEK", symbol: "kr", name: "瑞典克朗"),
        Entry(code: "NOK", symbol: "kr", name: "挪威克朗"),
        Entry(code: "DKK", symbol: "kr", name: "丹麦克朗"),
        Entry(code: "PLN", symbol: "zł", name: "波兰兹罗提"),
        Entry(code: "CZK", symbol: "Kč", name: "捷克克朗"),
        Entry(code: "HUF", symbol: "Ft", name: "匈牙利福林"),
        Entry(code: "RON", symbol: "lei", name: "罗马尼亚列伊"),
        Entry(code: "UAH", symbol: "₴", name: "乌克兰格里夫纳"),
        Entry(code: "BDT", symbol: "Tk", name: "孟加拉塔卡"),
        Entry(code: "PKR", symbol: "Rs", name: "巴基斯坦卢比"),
        Entry(code: "BOB", symbol: "Bs", name: "玻利维亚诺"),
        Entry(code: "UYU", symbol: "$U", name: "乌拉圭比索"),
    ]

    static func entry(for code: String) -> Entry? {
        all.first { $0.code == code }
    }

    static func symbol(for code: String) -> String {
        entry(for: code)?.symbol ?? code
    }

    static func name(for code: String) -> String {
        entry(for: code)?.name ?? code
    }
}
