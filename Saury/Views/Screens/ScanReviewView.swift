import SwiftUI

/// 扫描确认界面（方案 §25、§26）。
///
/// 存在的理由只有一条：OCR 不许直接盖掉用户的数据。每一项都带着置信度和原图位置，
/// 低置信度的标「需要确认」，说不清的日月顺序给一键换，不想要的整条丢掉。
struct ScanReviewView: View {
    /// 确认后交给宿主的东西：结果本身 + 是否「今天开封」（方案 §24）。
    typealias Confirmation = ExpiryOCRConfirmation

    let scan: ExpiryOCRService.Scan
    let onConfirm: (Confirmation) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var result: ExpiryOCRResult
    @State private var focused: ExpiryOCRField?
    @State private var openedToday = false

    init(scan: ExpiryOCRService.Scan, onConfirm: @escaping (Confirmation) -> Void) {
        self.scan = scan
        self.onConfirm = onConfirm
        _result = State(initialValue: scan.result)
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: QJMetric.section) {
                    packageImage
                    candidates
                    if result.needsConfirmation { hint }
                    if let afterOpening = result.duration(for: .afterOpening) {
                        openingSection(afterOpening)
                    }
                    notes
                }
                .padding(.horizontal, QJMetric.screen)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
            .background(QJTheme.canvas)
            .navigationTitle("扫描结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("用这些结果") { onConfirm(Confirmation(result: result, openedToday: openedToday, image: scan.image)); dismiss() }
                        .fontWeight(.semibold)
                        .disabled(result.entries.isEmpty)
                }
            }
        }
    }

    // MARK: - 原图与框

    private var packageImage: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Image(uiImage: scan.image)
                    .resizable()
                    .scaledToFit()
            }
            .aspectRatio(imageAspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay(boxLayer)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityLabel("包装照片，上面标出了识别到的位置")

            Text("亮色的框是这段文字在包装上的位置。看不清就重拍，比在这里猜有用。")
                .font(.caption)
                .foregroundStyle(QJTheme.subtle)
        }
    }

    private var imageAspectRatio: CGFloat {
        let size = scan.image.size
        guard size.width > 0, size.height > 0 else { return 1 }
        return size.width / size.height
    }

    private var boxLayer: some View {
        GeometryReader { proxy in
            ForEach(result.entries.filter { $0.boundingBox != nil }, id: \.field) { candidate in
                if let box = candidate.boundingBox {
                    let focusedHere = focused == candidate.field
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(focusedHere ? QJTheme.accent : QJTheme.accent.opacity(0.45),
                                lineWidth: focusedHere ? 3 : 1.5)
                        .background(focusedHere ? QJTheme.accent.opacity(0.14) : Color.clear)
                        .frame(width: max(box.width * proxy.size.width, 18),
                               height: max(box.height * proxy.size.height, 10))
                        .position(x: box.midX * proxy.size.width, y: box.midY * proxy.size.height)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - 候选列表

    private var candidates: some View {
        VStack(alignment: .leading, spacing: QJMetric.row) {
            Text("识别到 \(result.entries.count) 项")
                .font(.headline.weight(.medium))
                .foregroundStyle(QJTheme.ink)
            ForEach(result.entries) { candidate in
                candidateRow(candidate)
            }
            if result.entries.isEmpty {
                Text("什么都不够可信，回去重拍一张，或者直接手动填。")
                    .font(.subheadline)
                    .foregroundStyle(QJTheme.subtle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(QJMetric.card)
                    .background(QJTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: QJMetric.card, style: .continuous))
            }
        }
    }

    private func candidateRow(_ candidate: ExpiryOCRCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(candidate.field.title)
                    .font(.caption)
                    .foregroundStyle(QJTheme.subtle)
                Spacer()
                Text(candidate.confidenceText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(candidate.needsConfirmation ? QJTheme.accent : QJTheme.calm)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(candidate.value.displayText)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(QJTheme.ink)
                    .multilineTextAlignment(.leading)
                Spacer()
                if candidate.needsConfirmation {
                    Text("需要确认")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(QJTheme.accentSoft)
                        .foregroundStyle(QJTheme.accent)
                        .clipShape(Capsule())
                }
            }
            if !candidate.reasons.isEmpty || !candidate.sources.isEmpty {
                Text(candidate.explanation)
                    .font(.caption2)
                    .foregroundStyle(QJTheme.subtle)
            }
            if !candidate.alternatives.isEmpty {
                HStack(spacing: 8) {
                    Text("或者").font(.caption2).foregroundStyle(QJTheme.subtle)
                    ForEach(candidate.alternatives, id: \.self) { alternative in
                        Button(alternative.displayText) { replace(candidate, with: alternative) }
                            .font(.caption.weight(.medium))
                            .buttonStyle(.bordered)
                            .tint(QJTheme.calm)
                    }
                }
            }
            Button("不要这一项") { result = dropping(candidate) }
                .font(.caption2)
                .foregroundStyle(QJTheme.subtle)
        }
        .padding(QJMetric.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QJTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: QJMetric.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: QJMetric.card, style: .continuous)
                .stroke(focused == candidate.field ? QJTheme.accent.opacity(0.5) : QJTheme.line,
                        lineWidth: focused == candidate.field ? 1.5 : 1)
        )
        .onTapGesture { focused = candidate.field }
        .animation(.snappy, value: focused)
    }

    private var hint: some View {
        Label {
            Text("带「需要确认」的项目置信度低于 \(Int(ExpiryOCRThresholds.confirmation * 100))%，别信它自动填进去的那个数。")
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .font(.caption)
        .foregroundStyle(QJTheme.accent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(QJTheme.accentSoft.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 今天开封（方案 §24）

    private func openingSection(_ life: ShelfLife) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("开封后 \(life.title)").font(.headline.weight(.medium)).foregroundStyle(QJTheme.ink)
            Toggle(isOn: $openedToday.animation(.snappy)) {
                Text("今天开封").font(.subheadline)
            }
            .tint(QJTheme.calm)
            if openedToday, let date = life.date(after: Date()) {
                Text("按今天算，\(QJFormatters.yearDate.string(from: date)) 就该用完。")
                    .font(.caption)
                    .foregroundStyle(QJTheme.subtle)
            } else {
                Text("现在不开封就先不管；哪天拆开，在详情页点「今天开封」。")
                    .font(.caption)
                    .foregroundStyle(QJTheme.subtle)
            }
        }
        .padding(QJMetric.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QJTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: QJMetric.card, style: .continuous))
    }

    private var notes: some View {
        Group {
            if !result.notes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(result.notes, id: \.self) { note in
                        Text("· \(note)").font(.caption).foregroundStyle(QJTheme.subtle)
                    }
                }
            }
        }
    }

    // MARK: - 修改

    private func replace(_ candidate: ExpiryOCRCandidate, with alternative: ExpiryOCRValue) {
        var edited = candidate
        edited.markConfirmed(with: alternative)
        result = result.setting(edited)
        focused = candidate.field
    }

    private func dropping(_ candidate: ExpiryOCRCandidate) -> ExpiryOCRResult {
        var copy = result
        copy.entries.removeAll { $0.id == candidate.id }
        if focused == candidate.field { focused = nil }
        return copy
    }
}
