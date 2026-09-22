import CoreGraphics
import Foundation

/// 关键字和日期的相对位置（方案 §26 的「关键字距离」）。
enum KeywordProximity: Hashable {
    /// 同一行里隔了 `characters` 个字符；`before` 表示关键字在日期前面（中文包装几乎都是这样）。
    case sameLine(characters: Int, before: Bool)
    /// 相邻行，`lines` 是行号差。
    case nearbyLine(lines: Int, before: Bool)
    case none

    var strengthFactor: Double {
        switch self {
        case .sameLine(let characters, let before):
            let decay = max(0, 1 - Double(min(characters, 30)) / 30 * 0.35)
            return before ? decay : decay * 0.8
        case .nearbyLine(let lines, let before):
            let decay = max(0.2, 1 - Double(min(lines, 3)) * 0.3)
            return before ? decay : decay * 0.75
        case .none:
            return 0
        }
    }
}

/// 方案 §26 的四项区域评分。四项相加就是候选的置信度，
/// 所以「500ml」这种没有日期形状的文字根本进不了候选列表。
struct RegionScore: Hashable {
    /// 关键字距离，最多 0.40。
    let keyword: Double
    /// 日期格式强度，最多 0.30。
    let format: Double
    /// 引擎的文字置信度，最多 0.20。
    let recognition: Double
    /// 文字位置与字号，最多 0.10。
    let position: Double

    static let keywordWeight = 0.40
    static let formatWeight = 0.30
    static let recognitionWeight = 0.20
    static let positionWeight = 0.10

    var total: Double { min(keyword + format + recognition + position, 1) }

    init(keyword: Double = 0, format: Double = 0, recognition: Double = 0, position: Double = 0) {
        self.keyword = keyword
        self.format = format
        self.recognition = recognition
        self.position = position
    }
}

enum RegionScoring {
    /// 关键字越近、本身越明确，加分越多。
    static func keywordScore(_ proximity: KeywordProximity, strength: Double) -> Double {
        RegionScore.keywordWeight * max(0, min(strength, 1)) * proximity.strengthFactor
    }

    static func formatScore(_ format: ExpiryDateFormat) -> Double {
        RegionScore.formatWeight * format.strength
    }

    static func recognitionScore(_ confidence: Double) -> Double {
        RegionScore.recognitionWeight * max(0, min(confidence, 1))
    }

    /// 识别率低于 0.6 时按比例压低整个区域的分数。这四项相加只能说明「这块文字像日期」，
    /// 说明不了看没看对：把 1 看成 7 的时候关键字、格式、位置全都满分，日期却是错的。
    static func confidence(for score: RegionScore, line: OCRLine) -> Double {
        let recognition = max(0, min(line.confidence, 1))
        return score.total * (recognition >= 0.6 ? 1 : recognition / 0.6)
    }

    /// 日期通常印在包装中段的小字里：贴着顶边的是品名，贴着底边的往往是厂商和法规文字。
    /// 字号特别大的行同理，那是品牌展示，不是喷码。
    static func datePositionScore(line: OCRLine) -> Double {
        let band = max(0, 1 - abs(line.verticalCenter - 0.5) * 1.6)
        let sizePenalty = line.boundingBox.height > 0.09 ? 0.5 : 1
        return RegionScore.positionWeight * band * sizePenalty
    }

    /// 名称要反过来：大字、靠上，才是包装正面那块。
    static func namePositionScore(line: OCRLine, tallestHeight: Double) -> Double {
        let band = max(0, 1 - abs(line.verticalCenter - 0.3) * 1.4)
        let relative = tallestHeight > 0 ? min(1, line.boundingBox.height / max(tallestHeight, 0.001)) : 0.5
        return RegionScore.positionWeight * (band * 0.5 + relative * 0.5)
    }

    static func dateScore(
        format: ExpiryDateFormat,
        proximity: KeywordProximity,
        keywordStrength: Double,
        line: OCRLine
    ) -> RegionScore {
        RegionScore(
            keyword: keywordScore(proximity, strength: keywordStrength),
            format: formatScore(format),
            recognition: recognitionScore(line.confidence),
            position: datePositionScore(line: line)
        )
    }
}
