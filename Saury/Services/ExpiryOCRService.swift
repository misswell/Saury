import Foundation
import UIKit
import Vision

/// 一张包装照片 → 到期信息（方案 §21、§27）。
///
/// 文字和条码在同一趟本机识别里读出来：不上传图片，也不依赖网络商品库。
/// 「哪段文字是到期日」不在这里判断，那是 `ExpiryOCRParser` 的职责 —— 只有它能被单测稳定覆盖（方案 §91）。
struct ExpiryOCRService {
    /// 一次扫描的素材：识别结果 + 用到的图 + 原始行。确认界面要在原图上框出位置。
    struct Scan: Identifiable {
        let id = UUID()
        let image: UIImage
        let page: OCRPage
        let result: ExpiryOCRResult
    }

    enum OCRError: LocalizedError {
        case invalidImage
        case noText

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "无法读取这张图片，换一张更清晰的试试。"
            case .noText: return "没有识别到可用的文字。把包装正面擦干净、避开反光再拍一次。"
            }
        }
    }

    func scan(image: UIImage) async throws -> Scan {
        guard let cgImage = image.cgImage else { throw OCRError.invalidImage }
        let observations = try await perform(cgImage: cgImage)
        let page = OCRPage(lines: observations.text.enumerated().map { index, observation in
            OCRLine(vision: observation, index: index)
        })
        guard !page.isEmpty else { throw OCRError.noText }

        var result = ExpiryOCRParser.parse(page: page)
        if let barcode = Self.barcodeCandidate(from: observations.barcode) {
            result = result.setting(barcode)
        }
        return Scan(image: image, page: page, result: result)
    }

    func recognize(image: UIImage) async throws -> ExpiryOCRResult {
        try await scan(image: image).result
    }

    private struct Observations {
        let text: [VNRecognizedTextObservation]
        let barcode: [VNBarcodeObservation]
    }

    private func perform(cgImage: CGImage) async throws -> Observations {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Observations, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let text = VNRecognizeTextRequest()
                text.recognitionLanguages = ["zh-Hans", "en-US"]
                text.recognitionLevel = .accurate
                text.usesLanguageCorrection = true

                let barcodes = VNDetectBarcodesRequest()
                // 方案 §27：EAN-13 / EAN-8 / UPC / QR。Vision 把北美 UPC-A 报成 EAN-13，
                // 所以这里没有单独的 upca。
                barcodes.symbologies = [.ean13, .ean8, .upce, .qr]

                do {
                    try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([text, barcodes])
                    continuation.resume(returning: Observations(
                        text: text.results ?? [],
                        barcode: barcodes.results ?? []
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 一张包装上常有好几个码（背面、快递单、反光产生的伪码）。取占画面最大的那个。
    private static func barcodeCandidate(from observations: [VNBarcodeObservation]) -> ExpiryOCRCandidate? {
        guard let best = observations.filter({ ($0.payloadStringValue ?? "").count >= 4 })
            .max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }),
              let payload = best.payloadStringValue, !payload.isEmpty else { return nil }
        let box = best.boundingBox
        return ExpiryOCRCandidate(
            field: .barcode,
            value: .text(payload),
            // 条码读得出来就基本不会错，但它可能是快递单上的码，所以留一点余量。
            confidence: min(0.9, Double(best.confidence) * 0.9),
            boundingBox: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height),
            reasons: ["码制：\(best.symbology.rawValue)"],
            sources: [.barcodeSymbol]
        )
    }
}

/// 确认界面点「用这些结果」之后交出去的东西（方案 §25）。
///
/// 它跟着 `ExpiryOCRResult` 一起走，但放在 Services 这一层：原图也在这里交出去
/// （方案 §34），而领域层不许碰 UIKit —— 解析器要能被单测稳定覆盖（方案 §91）。
struct ExpiryOCRConfirmation: Identifiable {
    let id = UUID()
    var result: ExpiryOCRResult
    /// 「今天开封」这个勾选（方案 §24）。
    var openedToday: Bool
    /// 这次识别用的那张原图。有图就存进 `ImageStore`，活动记录里要把它摆出来。
    var image: UIImage?
}

extension OCRLine {
    /// 从 Vision 的观察结果转一行；多候选文字取第一条（置信度最高）。
    init(vision observation: VNRecognizedTextObservation, index: Int) {
        let top = observation.topCandidates(1).first
        let box = observation.boundingBox
        self.init(
            top?.string ?? "",
            confidence: Double(top?.confidence ?? 0),
            boundingBox: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height),
            index: index
        )
    }
}
