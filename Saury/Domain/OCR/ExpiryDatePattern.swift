import Foundation

/// 日期写法。`strength` 就是方案 §26 里「日期格式」这一项的分：
/// `2026-10-12` 几乎不可能读错，`05/09/2026` 连是几月都不一定。
enum ExpiryDateFormat: String, CaseIterable {
    case chineseYMD
    case isoYMD
    case compactYMD
    case monthName
    case dayMonthYear
    case monthDayYear
    case ambiguousDayMonth
    case yearMonth
    case monthYear

    var strength: Double {
        switch self {
        case .chineseYMD: return 1
        case .isoYMD: return 0.96
        case .compactYMD: return 0.88
        case .monthName: return 0.9
        case .dayMonthYear, .monthDayYear: return 0.78
        case .ambiguousDayMonth: return 0.42
        case .yearMonth, .monthYear: return 0.5
        }
    }

    /// 光看格式就能说清这段文字为什么可信（或不可信）。
    var explanation: String {
        switch self {
        case .chineseYMD: return "中文年月日"
        case .isoYMD: return "年在最前，不会歧义"
        case .compactYMD: return "无分隔的八位数字"
        case .monthName: return "带英文月份名"
        case .dayMonthYear: return "日/月/年"
        case .monthDayYear: return "月/日/年"
        case .ambiguousDayMonth: return "日和月都可能小于 12"
        case .yearMonth, .monthYear: return "只到月份"
        }
    }

    /// `05/09/2026` 连是几月都要猜，`2026-11` 连是几号都要猜。
    /// 这类读法从总分里扣这么多：它们的格式强度不超过 0.5，所以扣完一定落在确认线以下，
    /// 但彼此之间还排得出高低（关键字强的仍然比弱的可信）。
    var reviewPenalty: Double {
        switch self {
        case .ambiguousDayMonth, .yearMonth, .monthYear: return 0.15
        default: return 0
        }
    }
}

/// 一段文字里认出的一种日期解释。
struct ExpiryDateReading: Hashable {
    let date: Date
    let format: ExpiryDateFormat
    /// 同一段文字的另一种读法，比如 `05/09/2026` 也可能是 9 月 5 日。
    let alternatives: [Date]
    let reasons: [String]
    /// 命中的原文范围，用来量它离关键字有多远。
    let range: Range<String.Index>
}

/// 包装日期文本 → `Date`（方案 §22）。纯函数：不认识关键字，也不判断这个日期是谁。
enum ExpiryDatePattern {
    /// 合理区间：再早是印刷错误或别的数字，再晚没有包装会写这么远。
    static let plausibleYearsBeforeNow = 20
    static let plausibleYearsAfterNow = 25

    private struct Rule {
        let format: ExpiryDateFormat
        let pattern: String
        let dayGroup: Int
        let monthGroup: Int
        let yearGroup: Int
    }

    /// 顺序重要：先匹配信息量最大的写法，命中的字符不再参与后面的规则，
    /// 否则 `2026-09-22` 会被「只到月份」那条再认领一次。
    private static let rules: [Rule] = [
        Rule(format: .chineseYMD, pattern: #"(20[0-9]{2})\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日?"#,
             dayGroup: 3, monthGroup: 2, yearGroup: 1),
        Rule(format: .isoYMD, pattern: #"(?<!\d)(20[0-9]{2})\s*[/.\-]\s*(\d{1,2})\s*[/.\-]\s*(\d{1,2})(?!\d)"#,
             dayGroup: 3, monthGroup: 2, yearGroup: 1),
        Rule(format: .compactYMD, pattern: #"(?<!\d)(20[0-9]{2})(\d{2})(\d{2})(?!\d)"#,
             dayGroup: 3, monthGroup: 2, yearGroup: 1),
        Rule(format: .monthName, pattern: #"(?<![A-Za-z])([A-Za-z]{3,9})\.?,?\s+(\d{1,2})(?:st|nd|rd|th)?\.?,?\s*(20[0-9]{2})(?![0-9A-Za-z])"#,
             dayGroup: 2, monthGroup: 1, yearGroup: 3),
        Rule(format: .monthName, pattern: #"(?<!\d)(\d{1,2})(?:st|nd|rd|th)?\.?\s+([A-Za-z]{3,9})\.?,?\s*(20[0-9]{2})(?![0-9A-Za-z])"#,
             dayGroup: 1, monthGroup: 2, yearGroup: 3),
        Rule(format: .dayMonthYear, pattern: #"(?<![\d/.\-])(\d{1,2})\s*[/.\-]\s*(\d{1,2})\s*[/.\-]\s*(20[0-9]{2})(?![\d])"#,
             dayGroup: 1, monthGroup: 2, yearGroup: 3),
        Rule(format: .yearMonth, pattern: #"(?<!\d)(20[0-9]{2})\s*[/.\-年]\s*(\d{1,2})\s*月?(?![\d.])"#,
             dayGroup: 0, monthGroup: 2, yearGroup: 1),
        Rule(format: .monthYear, pattern: #"(?<![\d/.\-])(\d{1,2})\s*[/.\-]\s*(20[0-9]{2})(?![\d])"#,
             dayGroup: 0, monthGroup: 1, yearGroup: 2)
    ]

    private static let monthNames: [String: Int] = {
        let full = ["january", "february", "march", "april", "may", "june", "july",
                    "august", "september", "october", "november", "december"]
        var map: [String: Int] = [:]
        for (index, name) in full.enumerated() {
            map[name] = index + 1
            map[String(name.prefix(3))] = index + 1
        }
        return map
    }()

    /// 找出所有像日期的片段，按它们在原文里出现的顺序返回。
    static func readings(in text: String, now: Date = Date(), calendar: Calendar = ExpiryEngine.calendar) -> [ExpiryDateReading] {
        var found: [(Range<String.Index>, ExpiryDateReading)] = []
        var claimed: [Range<String.Index>] = []

        for rule in rules {
            guard let expression = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            let span = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in expression.matches(in: text, range: span) {
                guard let whole = Range(match.range, in: text),
                      !claimed.contains(where: { $0.overlaps(whole) }) else { continue }
                guard let reading = interpret(match, with: rule, in: text, now: now, calendar: calendar) else { continue }
                claimed.append(reading.range)
                found.append((reading.range, reading))
            }
        }
        return found.sorted { $0.0.lowerBound < $1.0.lowerBound }.map(\.1)
    }

    private static func interpret(
        _ match: NSTextCheckingResult,
        with rule: Rule,
        in text: String,
        now: Date,
        calendar: Calendar
    ) -> ExpiryDateReading? {
        func number(_ index: Int) -> Int? {
            guard index > 0, index < match.numberOfRanges else { return nil }
            let nsRange = match.range(at: index)
            guard nsRange.location != NSNotFound, let range = Range(nsRange, in: text) else { return nil }
            return Int(text[range].trimmingCharacters(in: .whitespaces))
        }
        func namedMonth(_ index: Int) -> Int? {
            guard index > 0, index < match.numberOfRanges else { return nil }
            let nsRange = match.range(at: index)
            guard nsRange.location != NSNotFound, let range = Range(nsRange, in: text) else { return nil }
            return monthNames[text[range].lowercased()]
        }

        guard let year = number(rule.yearGroup) else { return nil }
        var month: Int?
        var day: Int?
        var format = rule.format
        var alternatives: [Date] = []
        var reasons: [String] = []

        switch rule.format {
        case .monthName:
            month = namedMonth(rule.monthGroup)
            day = number(rule.dayGroup)
        case .dayMonthYear:
            // 这一段两个数字都 ≤ 31，谁在前要看数值本身（方案 §22 的歧义段）。
            guard let first = number(rule.dayGroup), let second = number(rule.monthGroup),
                  let resolved = resolve(dayMonth: first, monthDay: second, year: year, calendar: calendar) else { return nil }
            format = resolved.format
            month = resolved.month
            day = resolved.day
            alternatives = resolved.alternatives
            reasons.append(contentsOf: resolved.reasons)
        case .yearMonth, .monthYear:
            month = number(rule.monthGroup)
            reasons.append("只识别到月份，按该月最后一天计算")
        case .chineseYMD, .isoYMD, .compactYMD:
            month = number(rule.monthGroup)
            day = number(rule.dayGroup)
        case .monthDayYear, .ambiguousDayMonth:
            return nil
        }

        guard let month, month >= 1, month <= 12 else { return nil }
        guard let matchRange = Range(match.range, in: text) else { return nil }
        let resolvedDay = day ?? lastDay(ofMonth: month, year: year, calendar: calendar)
        guard let date = validDate(year: year, month: month, day: resolvedDay, calendar: calendar),
              isPlausible(date, now: now, calendar: calendar) else { return nil }

        return ExpiryDateReading(
            date: date,
            format: format,
            alternatives: alternatives.filter { !calendar.isDate($0, inSameDayAs: date) },
            reasons: reasons,
            range: matchRange
        )
    }

    private struct Resolution {
        let day: Int
        let month: Int
        let format: ExpiryDateFormat
        let alternatives: [Date]
        let reasons: [String]
    }

    /// `22/09/2026` 和 `09/22/2026` 都能定死；`05/09/2026` 两边都说得通，
    /// 于是按「日在前」给主读法，另一种留给确认界面让人一键换（方案 §25）。
    private static func resolve(
        dayMonth first: Int,
        monthDay second: Int,
        year: Int,
        calendar: Calendar
    ) -> Resolution? {
        let asDayFirst = validDate(year: year, month: second, day: first, calendar: calendar)
        let asMonthFirst = validDate(year: year, month: first, day: second, calendar: calendar)

        if first > 12, asDayFirst != nil {
            return Resolution(day: first, month: second, format: .dayMonthYear, alternatives: [], reasons: [])
        }
        if second > 12, asMonthFirst != nil {
            return Resolution(day: second, month: first, format: .monthDayYear, alternatives: [], reasons: [])
        }
        guard let primary = asDayFirst else { return nil }
        var reasons = ["无法确定是 \(second) 月 \(first) 日还是 \(first) 月 \(second) 日"]
        var alternatives: [Date] = []
        if let alternative = asMonthFirst, !calendar.isDate(alternative, inSameDayAs: primary) {
            alternatives = [alternative]
            reasons.append("默认按「日/月」读")
        }
        return Resolution(day: first, month: second, format: .ambiguousDayMonth,
                          alternatives: alternatives, reasons: reasons)
    }

    static func lastDay(ofMonth month: Int, year: Int, calendar: Calendar = ExpiryEngine.calendar) -> Int {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        guard let anchor = components.date,
              let range = calendar.range(of: .day, in: .month, for: anchor) else { return 30 }
        return range.upperBound
    }

    /// 2 月 30 日这种「组件合法但日历上没有」的日期一律丢弃。
    static func validDate(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        guard day >= 1, day <= 31 else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return calendar.startOfDay(for: date)
    }

    private static func isPlausible(_ date: Date, now: Date, calendar: Calendar) -> Bool {
        let year = calendar.component(.year, from: date)
        let thisYear = calendar.component(.year, from: now)
        return year >= thisYear - plausibleYearsBeforeNow && year <= thisYear + plausibleYearsAfterNow
    }
}
