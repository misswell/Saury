import CoreGraphics
import Foundation

/// 一行文字识别结果（方案 §25、§26）。
///
/// 坐标系已经翻成「原点在左上角」的归一化矩形：Vision 给的是左下角原点，
/// 而确认界面要把框直接叠在原图上，那里用的是 SwiftUI 的方向。
struct OCRLine: Hashable {
    let text: String
    /// 0…1，来自引擎；没有引擎数据（测试、剪贴板）时给满分。
    let confidence: Double
    let boundingBox: CGRect
    /// 在整页里的行序，用于「关键字距离」和稳定的排序结果。
    let index: Int

    init(
        _ text: String,
        confidence: Double = 1,
        boundingBox: CGRect = .zero,
        index: Int = 0
    ) {
        self.text = text
        self.confidence = min(max(confidence, 0), 1)
        self.boundingBox = boundingBox
        self.index = index
    }

    /// 行中心在画面里的纵向位置：0 是顶，1 是底。
    var verticalCenter: Double { boundingBox.midY }

    var isPlaceholderBox: Bool { boundingBox == .zero }

    /// 字符偏移，用来量「关键字离日期有多远」。
    func offset(of position: String.Index) -> Int { text.distance(from: text.startIndex, to: position) }
}

/// 一整页（一张包装照片）的文字识别结果。
struct OCRPage: Hashable {
    let lines: [OCRLine]

    /// 行序由页面负责：调用方（包括测试）不必自带 index。
    /// 没给框的行按固定行高堆叠，这样「文字位置」这一项评分永远有据可查，
    /// 而不是靠一个恰好留在 (0,0) 的矩形。
    init(lines: [OCRLine]) {
        self.lines = lines.enumerated().map { offset, line in
            let placed = line.isPlaceholderBox
                ? CGRect(x: 0.05, y: 0.08 + Double(offset) * 0.07, width: 0.9, height: 0.05)
                : line.boundingBox
            return OCRLine(line.text, confidence: line.confidence, boundingBox: placed, index: offset)
        }
    }

    init(texts: [String]) {
        self.init(lines: texts.map { OCRLine($0) })
    }

    var isEmpty: Bool { lines.isEmpty }

    subscript(index: Int) -> OCRLine? { lines.indices.contains(index) ? lines[index] : nil }
}
