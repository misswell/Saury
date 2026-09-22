import CoreGraphics
import Foundation

/// 包装文字 → 到期信息（方案 §21–§26）。
///
/// 这是扫描功能里唯一能稳定测的一层：Vision 在同一张图上都会给出不一样的行，
/// 但「一串文字应该怎么变成到期日期」必须有唯一答案（方案 §91）。
enum ExpiryOCRParser {
    private struct LineReading {
        let line: OCRLine
        let keywords: [DateKeywordOccurrence]
        let dates: [ExpiryDateReading]

        var text: String { line.text }
        var strongestKeyword: DateKeyword? { keywords.map(\.keyword).max { $0.strength < $1.strength } }
    }

    private struct KeywordMatch {
        let keyword: DateKeyword?
        let proximity: KeywordProximity
        let score: Double

        var role: ExpiryDateRole? { keyword?.role }
    }

    // MARK: - 入口

    static func parse(
        page: OCRPage,
        now: Date = Date(),
        calendar: Calendar = ExpiryEngine.calendar
    ) -> ExpiryOCRResult {
        let readings = page.lines.map { line in
            LineReading(
                line: line,
                keywords: DateKeywordVocabulary.matches(in: line.text),
                dates: ExpiryDatePattern.readings(in: line.text, now: now, calendar: calendar)
            )
        }

        var notes: [String] = []
        var entries = dateEntries(in: readings, notes: &notes, now: now, calendar: calendar)
        entries += durationEntries(in: readings)
        entries += labelEntries(in: readings)
        if let name = nameEntry(in: readings) { entries.append(name) }
        if let amount = amountEntry(in: readings) { entries.append(amount) }
        entries += derivedEntries(from: entries, notes: &notes, calendar: calendar)

        if entries.contains(where: \.needsConfirmation) {
            notes.append("标了「需要确认」的字段置信度低于 \(Int(ExpiryOCRThresholds.confirmation * 100))%，点一下就能改。")
        }
        return ExpiryOCRResult(entries: entries, notes: notes)
    }

    // MARK: - 日期（方案 §22、§26）

    private static func dateEntries(
        in readings: [LineReading],
        notes: inout [String],
        now: Date,
        calendar: Calendar
    ) -> [ExpiryOCRCandidate] {
        var best: [ExpiryOCRField: ExpiryOCRCandidate] = [:]
        var rejected = 0

        for reading in readings {
            for date in reading.dates {
                let match = nearestKeyword(to: date.range, in: readings, lineIndex: reading.line.index)
                var field = match.role?.field ?? .expiryDate
                var reasons = date.reasons
                if field != .manufactureDate, field != .expiryDate {
                    // 日期类字段只认这两个：「保质期 2026-10-12」说的是到期那天。
                    reasons.append(field == .shelfLife
                                   ? "「保质期」后面是日期，按有效日期处理"
                                   : "这个日期归到有效日期")
                    field = .expiryDate
                }
                if match.keyword == nil, field == .expiryDate {
                    reasons.append("这段日期附近没有关键字，先按有效日期处理")
                }
                if field == .expiryDate,
                   calendar.startOfDay(for: date.date) < calendar.startOfDay(for: now) {
                    reasons.append("识别到的有效期已经过去了，请确认")
                }
                let score = RegionScore(
                    keyword: match.score,
                    format: RegionScoring.formatScore(date.format),
                    recognition: RegionScoring.recognitionScore(reading.line.confidence),
                    position: RegionScoring.datePositionScore(line: reading.line)
                )
                let entry = ExpiryOCRCandidate(
                    field: field,
                    value: .date(date.date, alternatives: date.alternatives),
                    confidence: max(0, RegionScoring.confidence(for: score, line: reading.line) - date.format.reviewPenalty),
                    boundingBox: reading.line.boundingBox,
                    reasons: reasons
                )
                if let existing = best[field] {
                    rejected += 1
                    if existing.confidence >= entry.confidence { continue }
                }
                best[field] = entry
            }
        }

        if rejected > 0 {
            notes.append("另有 \(rejected) 处日期没采用；如果认错了，直接在下面改。")
        }
        return best.values.sorted { $0.field < $1.field }
    }

    /// 关键字离日期越近越可信；同一行里紧跟在日期前面的关键字最强（方案 §26）。
    private static func nearestKeyword(
        to date: Range<String.Index>,
        in readings: [LineReading],
        lineIndex: Int
    ) -> KeywordMatch {
        var best = KeywordMatch(keyword: nil, proximity: .none, score: 0)
        for candidate in readings {
            for occurrence in candidate.keywords {
                guard let proximity = proximity(between: occurrence, and: date, in: candidate, dateLine: lineIndex) else { continue }
                let score = RegionScoring.keywordScore(proximity, strength: occurrence.keyword.strength)
                if score > best.score {
                    best = KeywordMatch(keyword: occurrence.keyword, proximity: proximity, score: score)
                }
            }
        }
        return best
    }

    /// 只有同一行的两个范围才做字符级比较 —— 跨行的 `String.Index` 不属于同一个字符串，
    /// 比出来的数字没有意义，所以跨行只比行号。
    private static func proximity(
        between occurrence: DateKeywordOccurrence,
        and date: Range<String.Index>,
        in candidate: LineReading,
        dateLine: Int
    ) -> KeywordProximity? {
        if candidate.line.index == dateLine {
            let text = candidate.text
            if occurrence.range.upperBound <= date.lowerBound {
                return .sameLine(characters: text.distance(from: occurrence.range.upperBound, to: date.lowerBound), before: true)
            }
            if occurrence.range.lowerBound >= date.upperBound {
                // 日期印在关键字前面（`2026.10.12 到期`）少见一些，扣分。
                return .sameLine(characters: text.distance(from: date.upperBound, to: occurrence.range.lowerBound) + 2, before: false)
            }
            return nil
        }
        let lines = abs(candidate.line.index - dateLine)
        guard lines <= 2 else { return nil }
        return .nearbyLine(lines: lines, before: candidate.line.index < dateLine)
    }

    // MARK: - 保质期与开封期（方案 §23、§24）

    private static func durationEntries(in readings: [LineReading]) -> [ExpiryOCRCandidate] {
        var best: [ExpiryOCRField: ExpiryOCRCandidate] = [:]
        for reading in readings {
            for hit in durationHits(for: reading) {
                let score = RegionScore(
                    keyword: hit.keywordScore,
                    format: RegionScore.formatWeight * hit.formatStrength,
                    recognition: RegionScoring.recognitionScore(reading.line.confidence),
                    position: RegionScoring.datePositionScore(line: reading.line)
                )
                let entry = ExpiryOCRCandidate(
                    field: hit.field,
                    value: .duration(hit.life),
                    confidence: RegionScoring.confidence(for: score, line: reading.line),
                    boundingBox: reading.line.boundingBox,
                    reasons: hit.reasons,
                    sources: hit.sources
                )
                if let existing = best[hit.field], existing.confidence >= entry.confidence { continue }
                best[hit.field] = entry
            }
        }
        return best.values.sorted { $0.field < $1.field }
    }

    private struct DurationHit {
        let field: ExpiryOCRField
        let life: ShelfLife
        let formatStrength: Double
        let keywordScore: Double
        let reasons: [String]
        let sources: Set<ExpirySource>
    }

    private static func durationHits(for reading: LineReading) -> [DurationHit] {
        let text = reading.text
        let onSameLine = RegionScoring.keywordScore(.sameLine(characters: 0, before: true), strength: 1)

        switch reading.strongestKeyword?.role {
        case .shelfLife:
            if let life = ShelfLifePattern.parse(text) {
                return [DurationHit(field: .shelfLife, life: life, formatStrength: 0.95,
                                    keywordScore: onSameLine, reasons: ["保质期与时段在同一行"], sources: [.optical])]
            }
        case .afterOpening:
            if let life = ShelfLifePattern.parse(text) ?? ShelfLifePattern.parsePeriodAfterOpening(text) {
                return [DurationHit(field: .afterOpening, life: life, formatStrength: 0.9,
                                    keywordScore: onSameLine, reasons: ["开封后有效期"], sources: [.optical])]
            }
        default:
            break
        }

        // 方案 §24：开盖图标只剩一个「6M」印在角落时，没有关键字可靠，只能靠形状。
        guard reading.keywords.isEmpty, reading.dates.isEmpty,
              let life = ShelfLifePattern.parsePeriodAfterOpening(text) else { return [] }
        return [DurationHit(field: .afterOpening, life: life, formatStrength: 0.5,
                            keywordScore: RegionScore.keywordWeight * 0.12,
                            reasons: ["只认到「\(life.title)」这个符号，没读到开盖说明"],
                            sources: [.optical, .heuristic])]
    }

    // MARK: - 品牌与批次

    private struct Label {
        let field: ExpiryOCRField
        let pattern: String

        func value(in text: String) -> String? {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            let span = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = expression.firstMatch(in: text, range: span), match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            let value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.count >= 2 ? value : nil
        }
    }

    private static let brandLabel = Label(field: .brand, pattern:
        #"(?:品牌|商标|制造商|生产商|生产企业|Manufacturer|Brand)\s*[:：]?\s*([A-Za-z\u4e00-\u9fff][A-Za-z0-9\u4e00-\u9fff &.,'\-]{1,30})"#)

    private static let batchLabel = Label(field: .batchNumber, pattern:
        #"(?:生产批号|批号|批次|Lot(?:\s*(?:No\.?|Number))?|BATCH(?:\s*(?:No\.?|Code))?|REF)\s*[:：]?\s*([A-Za-z0-9][A-Za-z0-9./\-]{2,24})"#)

    private static func labelEntries(in readings: [LineReading]) -> [ExpiryOCRCandidate] {
        var entries: [ExpiryOCRCandidate] = []
        for label in [brandLabel, batchLabel] {
            for reading in readings {
                guard let value = label.value(in: reading.text) else { continue }
                entries.append(ExpiryOCRCandidate(
                    field: label.field,
                    value: .text(value),
                    confidence: RegionScoring.confidence(for: RegionScore(
                        keyword: RegionScore.keywordWeight,
                        format: RegionScore.formatWeight * 0.8,
                        recognition: RegionScoring.recognitionScore(reading.line.confidence),
                        position: RegionScoring.datePositionScore(line: reading.line)
                    ), line: reading.line),
                    boundingBox: reading.line.boundingBox,
                    reasons: ["标签和内容在同一行"]
                ))
                break
            }
        }
        return entries
    }

    // MARK: - 名称

    /// 不是名称的东西：日期、规格、法规文字、纯数字条码。
    private static let legalMarkers = "有限公司|生产企业|生产商|委托方|经销商|进口商|地址|电话|许可证|执行标准|产品标准|条形码|净含量|规格|配料|营养成分|贮存|贮藏|注意事项|不良反应|禁忌|产地|厂名|卫生许可|批准文号|注册号"
    private static let specMarkers = #"\d+\s*(ml|mL|L|l|g|kg|mg|μg|iu|%|克|毫升|升|片|粒|支|袋|包|丸|喷|滴|抽|张)"#
    private static let codeOnly = #"^[0-9\s\-.,]+$"#

    private static func nameEntry(in readings: [LineReading]) -> ExpiryOCRCandidate? {
        let tallest = readings.map { $0.line.boundingBox.height }.max() ?? 0
        var best: ExpiryOCRCandidate?
        var bestConfidence = 0.0

        for reading in readings {
            let text = reading.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isPossibleName(text, reading: reading) else { continue }
            let hasLetters = text.range(of: "[A-Za-z\\u4e00-\\u9fff]{2,}", options: .regularExpression) != nil
            let hasDigits = text.contains { $0.isNumber }
            var reasons: [String] = []
            var confidence = 0.40
                + (hasLetters ? 0.15 : 0)
                + RegionScoring.recognitionScore(reading.line.confidence)
                + RegionScoring.namePositionScore(line: reading.line, tallestHeight: tallest)
            if hasDigits {
                confidence -= 0.12
                reasons.append("名称里带数字，可能是规格")
            }
            let entry = ExpiryOCRCandidate(
                field: .name,
                value: .text(text),
                confidence: confidence,
                boundingBox: reading.line.boundingBox,
                reasons: reasons,
                sources: [.heuristic, .optical]
            )
            if confidence > bestConfidence {
                best = entry
                bestConfidence = confidence
            }
        }
        return best
    }

    private static func isPossibleName(_ text: String, reading: LineReading) -> Bool {
        guard text.count >= 2, text.count <= 40 else { return false }
        guard reading.dates.isEmpty, reading.keywords.isEmpty else { return false }
        guard text.range(of: legalMarkers, options: .regularExpression) == nil else { return false }
        guard text.range(of: specMarkers, options: [.regularExpression, .caseInsensitive]) == nil else { return false }
        guard text.range(of: codeOnly, options: .regularExpression) == nil else { return false }
        guard !text.contains("://"), !text.contains("@") else { return false }
        return true
    }

    // MARK: - 金额

    private static func amountEntry(in readings: [LineReading]) -> ExpiryOCRCandidate? {
        for reading in readings {
            guard let amount = AmountPattern.parse(reading.text) else { continue }
            var reasons = amount.hasCurrencySymbol ? [] : ["没读到币种符号，按人民币记"]
            if reading.line.confidence < 0.6 { reasons.append("数字看得不清") }
            return ExpiryOCRCandidate(
                field: .amount,
                value: .amount(OCRAmount(minorUnits: amount.minorUnits, currencyCode: amount.currencyCode)),
                confidence: RegionScoring.confidence(for: RegionScore(
                    keyword: amount.hasCurrencySymbol ? 0.22 : 0.10,
                    format: RegionScore.formatWeight * 0.7,
                    recognition: RegionScoring.recognitionScore(reading.line.confidence),
                    position: RegionScoring.datePositionScore(line: reading.line)
                ), line: reading.line),
                boundingBox: reading.line.boundingBox,
                reasons: reasons
            )
        }
        return nil
    }

    // MARK: - 推算（方案 §23）

    private static func derivedEntries(
        from entries: [ExpiryOCRCandidate],
        notes: inout [String],
        calendar: Calendar
    ) -> [ExpiryOCRCandidate] {
        guard let manufacture = entries.first(where: { $0.field == .manufactureDate }),
              let manufactureDate = manufacture.value.dateValue,
              let lifeEntry = entries.first(where: { $0.field == .shelfLife }),
              let life = lifeEntry.value.durationValue,
              let date = life.date(after: manufactureDate, calendar: calendar) else { return [] }

        if let expiry = entries.first(where: { $0.field == .expiryDate }), let current = expiry.value.dateValue {
            if !calendar.isDate(current, inSameDayAs: date) {
                notes.append("按生产日期 + \(life.title) 还能算出 \(QJFormatters.yearDate.string(from: date))，两者不一致。")
            }
            return []
        }
        return [ExpiryOCRCandidate(
            field: .expiryDate,
            value: .date(date, alternatives: []),
            confidence: min(manufacture.confidence, lifeEntry.confidence) * 0.92,
            boundingBox: manufacture.boundingBox ?? lifeEntry.boundingBox,
            reasons: ["由生产日期 + \(life.title) 推算"],
            sources: [.derived]
        )]
    }
}

/// 价格：包装上的 `￥29.90`、`$ 12.00`。没有符号的小数也认，但会降低置信度。
enum AmountPattern {
    static func parse(_ text: String) -> (minorUnits: Int, currencyCode: String, hasCurrencySymbol: Bool)? {
        if let match = firstMatch(#"(?:¥|￥|RMB|CNY)\s*([0-9]+(?:[.,][0-9]{1,2})?)"#, in: text),
           let value = Double(match.replacingOccurrences(of: ",", with: ".")) {
            return (QJMoney.minorUnits(fromYuan: value), "CNY", true)
        }
        if text.contains("HK$"), let match = firstMatch(#"HK\$\s*([0-9]+(?:[.,][0-9]{1,2})?)"#, in: text),
           let value = Double(match.replacingOccurrences(of: ",", with: ".")) {
            return (QJMoney.minorUnits(fromYuan: value), "HKD", true)
        }
        if text.contains("$"), let match = firstMatch(#"\$\s*([0-9]+(?:[.,][0-9]{1,2})?)"#, in: text),
           let value = Double(match.replacingOccurrences(of: ",", with: ".")) {
            return (QJMoney.minorUnits(fromYuan: value), "USD", true)
        }
        // 没有币种符号时只认「两位小数收尾」的写法，并且两头都不能再挨着数字或点：
        // 否则 `2026.10.12` 里的 `2026.10` 会被当成一笔两千块钱。
        if let match = firstMatch(#"(?<![0-9.])[0-9]{1,4}[.,][0-9]{2}(?![0-9.])"#, in: text),
           let value = Double(match.replacingOccurrences(of: ",", with: ".")) {
            return (QJMoney.minorUnits(fromYuan: value), "CNY", false)
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let span = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: span) else { return nil }
        let group = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
        guard let range = Range(group, in: text) else { return nil }
        return String(text[range])
    }
}
