import PhotosUI
import SwiftUI

/// 一次性扫描的两种起手式（方案 §19）。
///
/// 方案里的「扫描条码」要等 §27 的商品库（查到码就知道叫什么）才有独立意义，
/// 现在放一行只会和「扫包装」长得一样，所以先不放。连续扫描也不在这里 ——
/// 那条流程确认即入库，不进表单。
enum ScanRequest: Identifiable, Equatable {
    case package
    case library
    /// 分享扩展递过来的那张图（方案 §57）：不弹相机也不弹相册，直接进识别。
    case sharedImage(fileName: String)

    var id: String {
        switch self {
        case .package: return "package"
        case .library: return "library"
        case .sharedImage(let fileName): return "shared:\(fileName)"
        }
    }

    var title: String {
        switch self {
        case .package: return "扫包装上的日期"
        case .library: return "从相册识别"
        case .sharedImage: return "识别分享过来的照片"
        }
    }
}

extension View {
    /// 挂上就有「拍照 / 选照片 → 本机 OCR → 逐项确认」这一整套（方案 §19、§25）。
    /// 宿主只要把 `request` 置成一个值，确认完在 `onConfirm` 里收下结果。
    func scanFlow(request: Binding<ScanRequest?>, onConfirm: @escaping (ScanReviewView.Confirmation) -> Void) -> some View {
        modifier(ScanFlowModifier(request: request, onConfirm: onConfirm))
    }
}

struct ScanFlowModifier: ViewModifier {
    @Binding var request: ScanRequest?
    let onConfirm: (ScanReviewView.Confirmation) -> Void

    @State private var showingCamera = false
    @State private var showingLibrary = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var scan: ExpiryOCRService.Scan?
    @State private var isWorking = false
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, pending in
                guard let pending else { return }
                request = nil
                start(pending)
            }
            .fullScreenCover(isPresented: $showingCamera) { camera }
            .sheet(isPresented: $showingLibrary) { library }
            .sheet(item: $scan) { scan in
                ScanReviewView(scan: scan) { onConfirm($0) }
            }
            .alert("没有认出来", isPresented: failureBinding) {
                Button("好的", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
            .overlay(alignment: .center) {
                if isWorking {
                    Label("正在识别…", systemImage: "text.viewfinder")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(.regularMaterial, in: Capsule())
                }
            }
    }

    // MARK: - 起手

    private func start(_ request: ScanRequest) {
        switch request {
        case .sharedImage(let fileName):
            Task { await recognizeShared(fileName) }
        // 模拟器没有相机，拍照入口落到相册那条路，流程才测得下去。
        case .package where CameraPicker.isAvailable:
            showingCamera = true
        case .package, .library:
            showingLibrary = true
        }
    }

    /// 图是分享扩展落在 App Group 里的，取出来这一步就把它删掉（方案 §57）。
    private func recognizeShared(_ fileName: String) async {
        guard let image = SharedInbox.shared.takeImage(fileName) else {
            failure = "分享过来的那张图没取到。"
            return
        }
        await recognize(image)
    }

    private var camera: some View {
        CameraPicker(
            onCapture: { image in
                showingCamera = false
                Task { await recognize(image) }
            },
            onCancel: { showingCamera = false }
        )
        .ignoresSafeArea()
    }

    /// 系统相册选择器没法用代码弹出来，只能借一层 sheet 里的大按钮。
    private var library: some View {
        VStack(spacing: 14) {
            Text("挑一张包装照片").font(.headline)
            Text("照片只在这台设备上识别，不会上传。").font(.caption).foregroundStyle(QJTheme.subtle)
            PhotosPicker(selection: $selectedPhoto, matching: .images, preferredItemEncoding: .automatic) {
                Label("选择照片", systemImage: "photo.on.rectangle")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(QJTheme.accent)
        }
        .padding(24)
        .presentationDetents([.height(210)])
        .presentationDragIndicator(.visible)
        .onChange(of: selectedPhoto) { _, photo in
            guard let photo else { return }
            showingLibrary = false
            Task { await load(photo) }
        }
    }

    // MARK: - 识别

    private func load(_ photo: PhotosPickerItem) async {
        selectedPhoto = nil
        guard let data = try? await photo.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            failure = ExpiryOCRService.OCRError.invalidImage.errorDescription
            return
        }
        await recognize(image)
    }

    private func recognize(_ image: UIImage) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await ExpiryOCRService().scan(image: image)
            guard !Task.isCancelled else { return }
            scan = result
        } catch {
            failure = error.localizedDescription
        }
    }

    private var failureBinding: Binding<Bool> {
        Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
    }
}
