import AVFoundation
import SwiftUI
import SwiftData
import UIKit

/// 连续扫描（方案 §20）。整块界面只做一件事：拍一件、确认一件、存一件，
/// 然后自动回到取景 —— 摄像头会话全程不重建（方案 §76）。
struct ContinuousScanView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var coordinator: ContinuousScanCoordinator

    init(context: ModelContext) {
        // `wrappedValue` 是 autoclosure：会话和协调者要等到这一份状态真正建立时才造出来。
        // 写成 `let camera = CameraSession()` 再传进去就不算了 —— 视图每一帧都会重跑
        // `init`，那样一次连续扫描能开出十几个摄像头会话（方案 §76）。
        _coordinator = StateObject(wrappedValue: ContinuousScanCoordinator(
            session: CameraSession(),
            recognize: { image in try await ExpiryOCRService().scan(image: image) },
            store: { confirmation in try ContinuousScanStore(context: context).save(confirmation) }
        ))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch coordinator.cameraStatus {
            case .running:
                if let layer = coordinator.previewLayer {
                    PreviewLayerView(layer: layer).ignoresSafeArea()
                }
                controls
            case .denied:
                unavailable
            case .idle:
                ProgressView("正在打开摄像头…").tint(.white)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: reviewingBinding) {
            if let scan = coordinator.scan {
                ScanReviewView(scan: scan) { coordinator.confirm($0) }
                    .interactiveDismissDisabled()
            }
        }
        .alert("提示", isPresented: noticeBinding) {
            Button("好的", role: .cancel) { coordinator.clearNotice() }
        } message: {
            Text(coordinator.notice ?? "")
        }
        .onDisappear { coordinator.finish() }
    }

    // MARK: - 取景与快门

    private var controls: some View {
        VStack(spacing: 0) {
            header
            Spacer()
            recent
            shutter
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            Button("完成") { close() }
                .buttonStyle(.plain)
                .font(.body.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text("已录入 \(coordinator.savedCount) 件")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                if let barcode = coordinator.liveBarcode {
                    Text("条码 \(barcode)")
                        .font(.caption.monospaced())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, QJMetric.screen)
        .padding(.top, 8)
    }

    private var shutter: some View {
        VStack(spacing: 12) {
            Text("对准包装上的日期，擦掉反光")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.8))
            Button { coordinator.captureAndRecognize() } label: {
                ZStack {
                    Circle().fill(.white.opacity(0.25))
                    Circle().fill(.white).frame(width: 62, height: 62)
                    if coordinator.phase == .recognizing {
                        ProgressView()
                    } else {
                        Image(systemName: "text.viewfinder").font(.title3).foregroundStyle(.black)
                    }
                }
            }
            .frame(width: 78, height: 78)
            .disabled(coordinator.phase != .ready)
        }
        .padding(.bottom, 20)
    }

    /// 刚录进去的那几件：连续扫描时人需要知道「这件到底存没存」。
    private var recent: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(coordinator.saved.prefix(3).indices, id: \.self) { index in
                let entry = coordinator.saved[index]
                HStack(spacing: 6) {
                    Text(entry.name).font(.footnote.weight(.medium))
                    Text(entry.merged ? "并到已有批次" : QJFormatters.yearDate.string(from: entry.expiryDate))
                        .font(.caption)
                        .opacity(0.8)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .padding(.bottom, 18)
    }

    private var unavailable: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.missing")
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.7))
            Text("这台设备用不了摄像头")
                .font(.headline)
                .foregroundStyle(.white)
            Text("拍照识别需要摄像头权限；模拟器上没有摄像头，可以改用「从相册识别」。")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 30)
            Button("打开系统设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.bordered)
            .tint(.white)
            Button("关闭") { close() }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private func close() {
        coordinator.finish()
        dismiss()
    }

    private var reviewingBinding: Binding<Bool> {
        Binding(
            get: { coordinator.phase == .reviewing },
            set: { if !$0 { coordinator.cancelReview() } }
        )
    }

    private var noticeBinding: Binding<Bool> {
        Binding(get: { coordinator.notice != nil }, set: { if !$0 { coordinator.clearNotice() } })
    }
}

/// 把 AVCaptureVideoPreviewLayer 塞进 SwiftUI。图层由会话持有，这里只负责贴上和摆好。
private struct PreviewLayerView: UIViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.layer.addSublayer(layer)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.onLayout = { uiView.layer.sublayers?.first?.frame = uiView.bounds }
    }
}

private final class PreviewUIView: UIView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}
