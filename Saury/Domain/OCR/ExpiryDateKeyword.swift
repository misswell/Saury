import Foundation

/// 关键字负责的角色（方案 §22）。「有效期至」和「保质期」都能出现在同一张包装上，
/// 但一个是日历日、一个是时长，混在一起就会把「保质期 12 个月」认成 2027 年 12 月。
enum ExpiryDateRole: String, CaseIterable, Hashable {
    case manufacture
    case expiry
    case shelfLife
    case afterOpening

    var field: ExpiryOCRField {
        switch self {
        case .manufacture: return .manufactureDate
        case .expiry: return .expiryDate
        case .shelfLife: return .shelfLife
        case .afterOpening: return .afterOpening
        }
    }

    var title: String {
        switch self {
        case .manufacture: return "生产日期"
        case .expiry: return "有效日期"
        case .shelfLife: return "保质期"
        case .afterOpening: return "开封后有效期"
        }
    }
}

/// 一个日期关键字。`strength` 表示它有多能钉死角色：
/// 「生产日期」几乎不会认错，光秃秃的「月」什么也没说。
struct DateKeyword: Hashable {
    let phrase: String
    let role: ExpiryDateRole
    let strength: Double

    /// 纯 ASCII 的关键字要按词匹配，否则 `example` 里能捞出 `EXP`。
    var isLatin: Bool { phrase.allSatisfy { $0.isASCII } }
}

/// 关键字在一行里出现的位置。
struct DateKeywordOccurrence: Hashable {
    let keyword: DateKeyword
    let range: Range<String.Index>
}

/// 方案 §22 的中英文关键字表。
enum DateKeywordVocabulary {
    static let all: [DateKeyword] = {
        var keywords: [DateKeyword] = []
        func add(_ phrases: [String], role: ExpiryDateRole, strength: Double) {
            phrases.forEach { keywords.append(DateKeyword(phrase: $0, role: role, strength: strength)) }
        }
        add(["生产日期", "制造日期", "出厂日期", "包装日期", "分装日期", "生产日"],
            role: .manufacture, strength: 1)
        add(["MFG", "MFD", "MANUFACTURED", "MANUFACTURING", "PRODUCED", "PRODUCTION DATE", "PROD DATE", "PACK DATE", "PACKED ON", "PACK DATE"],
            role: .manufacture, strength: 0.9)
        add(["有效期至", "有效日期", "有效期", "失效日期", "到期日期", "到期日", "限用日期", "限用期限",
             "使用期限", "保质期至", "赏味期限", "最佳食用期", "最佳赏味期", "此日期前食用", "此日期前最佳", "有效期到"],
            role: .expiry, strength: 1)
        add(["EXP DATE", "EXPIRY DATE", "EXPIRATION DATE", "EXPIRES", "EXPIRY", "EXP", "USE BY", "USE BEFORE",
             "BEST BEFORE END", "BEST BEFORE", "BEST BY", "BBE", "BB"],
            role: .expiry, strength: 0.9)
        add(["保质期", "保质期限", "保存期", "保存期限", "贮存期", "质量保证期", "SHELF LIFE"],
            role: .shelfLife, strength: 1)
        add(["开封后", "开盖后", "开启后", "打开后", "启封后", "开封后使用期限", "AFTER OPENING", "AFTER OPEN", "PAO"],
            role: .afterOpening, strength: 1)
        return keywords
    }()

    private static let longestFirst = all.sorted { $0.phrase.count > $1.phrase.count }

    /// 一行里出现的所有关键字，按出现位置排序；被更长的关键字包含的短匹配会丢掉
    /// （「有效期至」不该同时算中「有效期」和「效期」）。
    static func matches(in text: String) -> [DateKeywordOccurrence] {
        var found: [DateKeywordOccurrence] = []
        for keyword in longestFirst {
            guard let range = range(of: keyword, in: text) else { continue }
            if found.contains(where: { $0.range.contains(range.lowerBound) && $0.range.upperBound >= range.upperBound }) { continue }
            found.append(DateKeywordOccurrence(keyword: keyword, range: range))
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// 这行最强的关键字（用于「这行整体是什么角色」）。
    static func dominant(in text: String) -> DateKeywordOccurrence? {
        matches(in: text).max { $0.keyword.strength < $1.keyword.strength }
    }

    private static func range(of keyword: DateKeyword, in text: String) -> Range<String.Index>? {
        if keyword.isLatin {
            let escaped = NSRegularExpression.escapedPattern(for: keyword.phrase)
            let pattern = "(?<![A-Z0-9])\(escaped)(?![A-Z0-9])"
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            let span = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = expression.firstMatch(in: text, options: [], range: span),
                  let range = Range(match.range, in: text) else { return nil }
            return range
        }
        return text.range(of: keyword.phrase)
    }
}
