import Foundation

/// 金额 = 存储最小单位 + 币种。格式化、解析、换算都从这一处走，
/// 列表、统计、小票用的是同一套数字。
///
/// 存储刻度全币种统一为「主单位 × 100」：`minorUnits == 金额 × 100`。
/// 日元 1200 存成 120000，人民币 12.34 存成 1234。这样旧库里的一列数字
/// 不需要重新解释，也不会因为币种小数位不同而同一列两种含义。
/// 币种小数位（CLDR）只决定「允许输入几位、展示几位」，不参与存储刻度。
/// 已知限制：巴林第纳尔、科威特第纳尔这类 3 位小数币种在 ×100 刻度下
/// 存不下第 3 位，输入时直接拒绝而不是悄悄截断。
struct Money: Equatable, Hashable, Codable {
    var minorUnits: Int
    var currencyCode: String

    init(minorUnits: Int, currencyCode: String) {
        self.minorUnits = minorUnits
        self.currencyCode = currencyCode
    }

    /// 展示与图表用的浮点值（存储刻度 / 100）。
    var majorValue: Double { Double(minorUnits) / 100 }

    /// 精确的主单位值。金额相加走 Decimal，不走 Double。
    var majorAmount: Decimal { Decimal(minorUnits) / 100 }

    /// 本币种展示用的小数位数。
    var fractionDigits: Int { CurrencyCatalog.decimals(for: currencyCode) }

    /// ¥134.14 / $20.00 / ₩1200。小数位随币种走，日元不会出现「1200.00」。
    var formatted: String {
        Self.format(minorUnits: minorUnits, currencyCode: currencyCode)
    }

    /// 大数字场景（总览的巨额总数）：¥2,425.64 一样带千分位。
    var formattedGrouped: String {
        Self.format(minorUnits: minorUnits, currencyCode: currencyCode, grouped: true)
    }

    /// 只有数字没有符号：输入框回填、CSV 导出用。
    var amountText: String {
        Self.numberText(minorUnits: minorUnits, currencyCode: currencyCode)
    }

    static func format(minorUnits: Int, currencyCode: String, grouped: Bool = false) -> String {
        let symbol = CurrencyCatalog.symbol(for: currencyCode)
        let digits = CurrencyCatalog.decimals(for: currencyCode)
        let display = displayUnits(abs(minorUnits), digits: digits)
        let divisor = pow10(digits)
        let majorText = numberText(display / divisor, grouping: grouped)
        let sign = minorUnits < 0 ? "-" : ""
        guard digits > 0 else { return "\(sign)\(symbol)\(majorText)" }
        let fraction = display % divisor
        return "\(sign)\(symbol)\(majorText).\(String(format: "%0\(digits)d", fraction))"
    }

    static func numberText(minorUnits: Int, currencyCode: String) -> String {
        let digits = CurrencyCatalog.decimals(for: currencyCode)
        let display = displayUnits(abs(minorUnits), digits: digits)
        let negative = minorUnits < 0
        let magnitude = numberText(display / pow10(digits), grouping: false)
        guard digits > 0 else { return (negative ? "-" : "") + magnitude }
        let fraction = display % pow10(digits)
        return (negative ? "-" : "") + "\(magnitude).\(String(format: "%0\(digits)d", fraction))"
    }

    private static func numberText(_ major: Int, grouping: Bool) -> String {
        guard grouping, major >= 1000 else { return String(major) }
        var text = String(major)
        var grouped = ""
        while text.count > 3 {
            let cut = text.index(text.endIndex, offsetBy: -3)
            grouped = "," + text[cut...] + grouped
            text = String(text[..<cut])
        }
        return text + grouped
    }

    /// 存储刻度（1/100）换算到展示刻度（1/10^digits），半进位。
    /// 3 位小数币种做不到真精度，那里直接乘回去补 0，靠输入端拒绝第 3 位。
    private static func displayUnits(_ stored: Int, digits: Int) -> Int {
        if digits == 2 { return stored }
        if digits < 2 {
            let step = pow10(2 - digits)
            return (stored + step / 2) / step
        }
        return stored * pow10(digits - 2)
    }

    /// 均摊一份：整数半进位，不经过 Double。
    /// N 份相加与总额最多差 1 个最小单位（¥10.00 三人分摊 = ¥3.33 × 3 = ¥9.99），
    /// 差额留在账单侧，不假装能整除。
    static func evenShare(totalMinorUnits: Int, headcount: Int) -> Int {
        scaled(totalMinorUnits, by: 1, over: max(headcount, 1))
    }

    /// 按比例折算并保持半进位：`minorUnits × numerator / denominator`。
    /// 周折算到月（×52/12）、季度年折算到月（÷3、÷12）都走这里，
    /// 全项目只有一套舍入规则。
    static func scaled(_ minorUnits: Int, by numerator: Int, over denominator: Int) -> Int {
        guard denominator > 0 else { return minorUnits }
        return rounded(Decimal(minorUnits) * Decimal(numerator) / Decimal(denominator))
    }

    /// Decimal → 最小单位整数，半进位。
    private static func rounded(_ value: Decimal) -> Int {
        var source = value
        var result = Decimal()
        NSDecimalRound(&result, &source, 0, .plain)
        return Int(truncating: NSDecimalNumber(decimal: result))
    }

    /// 换算到目标币种。汇率表是「1 USD = n 目标币」，所以方向固定为
    /// 目标 = 原值 × rates[to] / rates[from]。没有汇率时按 1:1 兜底，
    /// 宁可数字不动也不显示 0。
    func converting(to targetCode: String, rates: [String: Double]) -> Money {
        guard currencyCode != targetCode else { return self }
        let fromRate = rates[currencyCode] ?? 1
        let toRate = rates[targetCode] ?? 1
        guard fromRate > 0 else { return self }
        return Money(minorUnits: Money.rounded(Decimal(minorUnits) * Decimal(toRate) / Decimal(fromRate)),
                     currencyCode: targetCode)
    }

    static func zero(_ code: String) -> Money { Money(minorUnits: 0, currencyCode: code) }

    static func + (lhs: Money, rhs: Money) -> Money {
        Money(minorUnits: lhs.minorUnits + rhs.minorUnits, currencyCode: lhs.currencyCode)
    }
}

private func pow10(_ exponent: Int) -> Int {
    var value = 1
    for _ in 0..<max(exponent, 0) { value *= 10 }
    return value
}

/// 金额输入解析。逐位拼整数位和小数位，不经过 Double，所以「12.34」存进去
/// 再拿出来永远是 12.34，不会漂成 12.339999999。
///
/// 分隔符怎么认：
/// * 两种符号都出现 → 靠后的是小数点，前面的是千分位。
/// * 只出现一种 → 它就是该语言的小数点时当小数点；否则看是不是规范千分位
///   （`1,234`、`1.234.567`），是就当千分位，不是就当小数点（`12,5` → 12.5）。
enum MoneyParsing {
    enum Failure: Error, Equatable {
        case empty
        case notANumber
        case negative
        case tooLarge
        case tooManyFractionDigits(allowed: Int)

        var message: String {
            switch self {
            case .empty: return "填个金额"
            case .notANumber: return "这里只能填数字"
            case .negative: return "金额不能是负数"
            case .tooLarge: return "金额太大了，按实际数字填"
            case .tooManyFractionDigits(let allowed):
                return allowed == 0 ? "这个币种没有小数位，填整数" : "最多 \(allowed) 位小数"
            }
        }
    }

    struct Separators {
        let decimal: Character
        let grouping: Character

        static let english = Separators(decimal: ".", grouping: ",")
        static let continental = Separators(decimal: ",", grouping: ".")

        static let current = Separators(
            decimal: NumberFormatter.localizedCurrency.decimalSeparator?.first ?? ".",
            grouping: NumberFormatter.localizedCurrency.groupingSeparator?.first ?? ","
        )
    }

    /// 小数位上限 = 币种精度；存储刻度只有 1/100，所以 3 位小数的币种压到 2 位并明说。
    static func allowedFractionDigits(for currencyCode: String) -> Int {
        min(CurrencyCatalog.decimals(for: currencyCode), 2)
    }

    static func parse(_ text: String,
                      currencyCode: String,
                      separators: Separators = .current) -> Result<Money, Failure> {
        switch split(text, currencyCode: currencyCode, separators: separators) {
        case .failure(let failure): return .failure(failure)
        case .success(let (integer, fraction)):
            let allowed = allowedFractionDigits(for: currencyCode)
            if fraction.count > allowed {
                return .failure(.tooManyFractionDigits(allowed: allowed))
            }
            guard let whole = Int(integer.isEmpty ? "0" : integer) else { return .failure(.tooLarge) }
            var minor = whole * 100
            if !fraction.isEmpty {
                let padded = fraction + String(repeating: "0", count: 2 - fraction.count)
                guard let hundredths = Int(padded) else { return .failure(.notANumber) }
                minor += hundredths
            }
            return .success(Money(minorUnits: minor, currencyCode: currencyCode))
        }
    }

    /// 只做字段级判错：空串留给必填校验，这里不算格式错误。
    static func validate(_ text: String,
                         currencyCode: String,
                         separators: Separators = .current) -> Failure? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        switch parse(text, currencyCode: currencyCode, separators: separators) {
        case .success: return nil
        case .failure(let failure): return failure
        }
    }

    /// 返回（整数位、小数位），两段都是纯数字串。
    private static func split(_ text: String,
                              currencyCode: String,
                              separators: Separators) -> Result<(String, String), Failure> {
        let symbols = [CurrencyCatalog.symbol(for: currencyCode),
                       CurrencyCatalog.cldrSymbol(for: currencyCode),
                       "￥"].filter { !$0.isEmpty }
        var body = ""
        for character in text {
            if character.isWhitespace { continue }
            if symbols.contains(String(character)) { continue }
            body.append(character)
        }
        if body.isEmpty { return .failure(.empty) }
        if body.hasPrefix("-") || body.hasPrefix("−") { return .failure(.negative) }
        if body.hasPrefix("+") { body.removeFirst() }

        let comma: Character = ","
        let dot: Character = "."
        var decimalMarker: Character?
        if body.contains(comma), body.contains(dot) {
            decimalMarker = body.lastIndex(of: dot)! > body.lastIndex(of: comma)! ? dot : comma
        } else if body.contains(dot) {
            decimalMarker = resolvesAsDecimal(dot, in: body, separators: separators)
        } else if body.contains(comma) {
            decimalMarker = resolvesAsDecimal(comma, in: body, separators: separators)
        }

        var integerText = body
        var fractionText = ""
        if let marker = decimalMarker, let range = body.range(of: String(marker)) {
            integerText = String(body[..<range.lowerBound])
            fractionText = String(body[range.upperBound...])
            if fractionText.contains(String(marker)) { return .failure(.notANumber) }
        }
        let groupings: Set<Character>
        if let marker = decimalMarker {
            groupings = Set([comma, dot].filter { $0 != marker })
        } else {
            groupings = [comma, dot]
        }
        guard let integer = digits(integerText, removing: groupings),
              let fraction = digits(fractionText, removing: groupings) else {
            return .failure(.notANumber)
        }
        if integer.isEmpty && fraction.isEmpty { return .failure(.notANumber) }
        if integer.count > 15 { return .failure(.tooLarge) }
        return .success((integer, fraction))
    }

    /// 只出现一种符号时，它到底是不是小数点。
    private static func resolvesAsDecimal(_ marker: Character,
                                          in body: String,
                                          separators: Separators) -> Character? {
        if marker == separators.decimal { return marker }
        return isCanonicalGrouping(body, marker: marker) ? nil : marker
    }

    /// `1,234`、`1.234.567` 这种「1-3 位 + 若干组 3 位」才算规范千分位。
    private static func isCanonicalGrouping(_ body: String, marker: Character) -> Bool {
        let escaped = marker == "." ? "\\." : String(marker)
        return body.range(of: "^[0-9]{1,3}(\(escaped)[0-9]{3})+$",
                          options: .regularExpression) != nil
    }

    private static func digits(_ text: String, removing groupings: Set<Character>) -> String? {
        var result = ""
        for character in text {
            if groupings.contains(character) { continue }
            guard character.isASCII, character.isNumber else { return nil }
            result.append(character)
        }
        return result
    }
}

private extension NumberFormatter {
    /// 只为拿当前语言的小数点/千分位字符，不做数值格式化。
    static let localizedCurrency: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = .current
        return formatter
    }()
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

    /// CLDR 自己的符号（人民币显示成 CN¥、印尼盾写成 IDR）。
    /// 只用来在解析时把这份写法也认下来，展示仍用表里挑好的 `symbol`。
    static func cldrSymbol(for code: String) -> String {
        cldrSymbols[code] ?? ""
    }

    /// 币种小数位。数据来自 CLDR，跟系统钱包/银行口径一致：
    /// 日元韩元越南盾 0 位，人民币美元 2 位，巴林科威特第纳尔 3 位。
    /// 表里没有的币种按 2 位处理。
    static func decimals(for code: String) -> Int {
        fractionDigits[code] ?? 2
    }

    private static let fractionDigits: [String: Int] = {
        var table: [String: Int] = [:]
        for entry in all {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            // 币种小数位跟地区无关，挂到 en_US 上取 CLDR 的定值。
            formatter.locale = Locale(identifier: "en_US@currency=\(entry.code)")
            table[entry.code] = formatter.maximumFractionDigits
        }
        return table
    }()

    private static let cldrSymbols: [String: String] = {
        var table: [String: String] = [:]
        for entry in all {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.locale = Locale(identifier: "en_US@currency=\(entry.code)")
            table[entry.code] = formatter.currencySymbol ?? ""
        }
        return table
    }()
}
