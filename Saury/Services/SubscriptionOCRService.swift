import Foundation
import UIKit
import Vision

struct OCRSubscriptionDraft {
    var name: String?
    var amountMinorUnits: Int?
    var currencyCode: String = "CNY"
    var renewalDate: Date?
    var cycle: RenewalCycle?
}

enum SubscriptionOCRError: LocalizedError {
    case invalidImage
    case noText

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "无法读取这张截图。"
        case .noText: return "没有识别到可用的订阅文字，请换一张更清晰的截图。"
        }
    }
}

final class SubscriptionOCRService {
    func recognize(image: UIImage) async throws -> OCRSubscriptionDraft {
        guard let cgImage = image.cgImage else { throw SubscriptionOCRError.invalidImage }
        let observations = try await recognizeText(in: cgImage)
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !lines.isEmpty else { throw SubscriptionOCRError.noText }
        return parse(lines: lines)
    }

    private func recognizeText(in image: CGImage) async throws -> [VNRecognizedTextObservation] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: request.results as? [VNRecognizedTextObservation] ?? [])
            }
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func parse(lines: [String]) -> OCRSubscriptionDraft {
        var draft = OCRSubscriptionDraft()
        let joined = lines.joined(separator: " ")

        let amountPattern = #"(?:¥|￥|RMB|CNY|\$|HK\$)\s*([0-9]+(?:[.,][0-9]{1,2})?)"#
        if let match = firstMatch(pattern: amountPattern, in: joined), let value = Double(match.replacingOccurrences(of: ",", with: ".")) {
            draft.amountMinorUnits = Int(value * 100)
            if joined.contains("$") && !joined.contains("¥") && !joined.contains("￥") { draft.currencyCode = joined.contains("HK$") ? "HKD" : "USD" }
        } else if let plain = firstMatch(pattern: #"(?<![0-9])[0-9]+[.,][0-9]{1,2}(?![0-9])"#, in: joined), let value = Double(plain.replacingOccurrences(of: ",", with: ".")) {
            draft.amountMinorUnits = Int(value * 100)
        }

        let datePatterns = [
            #"(20[0-9]{2})[年./-]([0-9]{1,2})[月./-]([0-9]{1,2})"#,
            #"([0-9]{1,2})[月./-]([0-9]{1,2})[日]?"#
        ]
        for pattern in datePatterns {
            if let match = firstMatchGroups(pattern: pattern, in: joined) {
                let numbers = match.compactMap(Int.init)
                if numbers.count == 3 || numbers.count == 2 {
                    let hasYear = numbers.count == 3
                    let year = hasYear ? numbers[0] : Calendar.current.component(.year, from: Date())
                    let month = hasYear ? numbers[1] : numbers[0]
                    let day = hasYear ? numbers[2] : numbers[1]
                    draft.renewalDate = Calendar.current.date(from: DateComponents(year: year, month: month, day: day))
                    break
                }
            }
        }

        if joined.contains("年") || joined.localizedCaseInsensitiveContains("year") { draft.cycle = .yearly }
        if joined.contains("月") || joined.localizedCaseInsensitiveContains("month") { draft.cycle = .monthly }
        if joined.contains("试用") || joined.localizedCaseInsensitiveContains("trial") { draft.cycle = .freeTrial }
        draft.name = lines.first(where: { line in
            let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.count >= 2 && cleaned.count <= 36 && cleaned.range(of: #"[A-Za-z\u4e00-\u9fff]"#, options: .regularExpression) != nil && !cleaned.contains("到期") && !cleaned.contains("续费")
        })
        return draft
    }

    private func firstMatch(pattern: String, in string: String) -> String? {
        firstMatchGroups(pattern: pattern, in: string)?.first
    }

    private func firstMatchGroups(pattern: String, in string: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = expression.firstMatch(in: string, range: range) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            let matchRange = match.range(at: index)
            guard matchRange.location != NSNotFound, let range = Range(matchRange, in: string) else { return nil }
            return String(string[range])
        }
    }
}
