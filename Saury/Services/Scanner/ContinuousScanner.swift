import AVFoundation
import Foundation
import SwiftData
import UIKit

/// 摄像头会话走到了哪一步（方案 §81）。协议里不能套类型，所以放在外面。
enum ScanSessionStatus: Equatable {
    case idle
    case denied
    case running
}

/// 摄像头会话要做的那几件事（方案 §76）。
///
/// 抽成一个协议只有一个理由：连续扫描期间会话必须一直开着，而模拟器上没有摄像头，
/// 只有把「开了几次、什么时候关」变成可断言的东西，§76 才测得起来。
protocol ScanSessionControlling: AnyObject {
    /// 实时读到的条码（方案 §27）和会话状态都从这里往外推。
    var onStatus: ((ScanSessionStatus) -> Void) { get set }
    var onBarcode: ((String?) -> Void) { get set }

    var previewLayer: AVCaptureVideoPreviewLayer? { get }

    func start()
    func stop()
    /// 抓当前这一帧去做识别。
    func captureFrame() async -> UIImage?
}

/// 连续扫描里「存下这一件」的那一步（方案 §20、§28、§29、§34）。一次确认要连着做四件事：
/// 原图落盘、用条码查模板补默认值、判重（同一批就只加数量）、把这次的条码沉淀成新模板。
/// 四件事之外还要留下一条带图的事件 —— 活动记录的本质就是这些原图。
struct ContinuousScanStore {
    struct Saved: Equatable {
        let name: String
        let expiryDate: Date
        let quantity: Double
        /// true = 并进了已有批次，只动了数量；false = 新存了一条。
        let merged: Bool
    }

    enum StoreError: LocalizedError {
        case noExpiryDate

        var errorDescription: String? {
            switch self {
            case .noExpiryDate: return "没认到有效期，这一件先跳过。"
            }
        }
    }

    let context: ModelContext
    var images = ImageStore.shared

    @MainActor
    func save(_ confirmation: ExpiryOCRConfirmation, quantity: Double = 1, now: Date = Date()) throws -> Saved {
        let identifier = confirmation.image.flatMap { images.store($0) }
        let template = ProductTemplateStore.template(forBarcode: confirmation.result.text(for: .barcode), in: context)
        guard let built = ExpiryItem.scannedRecord(
            confirmation.result,
            imageIdentifier: identifier,
            openedToday: confirmation.openedToday,
            template: template,
            quantity: quantity,
            now: now
        ) else {
            // 这一件没存下去，图也不该留在盘上。
            images.delete(identifier)
            throw StoreError.noExpiryDate
        }

        let items = (try? context.fetch(FetchDescriptor<ExpiryItem>())) ?? []
        if let existing = ExpiryDuplicateCheck.match(ExpiryDuplicateCheck.candidate(for: built.item), in: items) {
            context.insert(existing.absorb(built.item, imageIdentifier: identifier, now: now))
            ProductTemplateStore.remember(existing, in: context)
            context.saveOrLog("连续扫描：并入已有批次")
            return Saved(name: existing.name, expiryDate: existing.expiryDate, quantity: existing.quantity, merged: true)
        }
        context.insert(built.item)
        context.insert(built.event)
        ProductTemplateStore.remember(built.item, in: context)
        context.saveOrLog("连续扫描：新增物品")
        return Saved(name: built.item.name, expiryDate: built.item.expiryDate, quantity: built.item.quantity, merged: false)
    }
}

/// 连续扫描的状态机（方案 §20）：取景 → 抓一帧 → 识别 → 确认 → 存 → 自动回到取景。
///
/// 禁止「扫一件退出一次再点开摄像头」：会话在 `init` 开、`finish()` 关，中间怎么循环都不碰它（§76）。
@MainActor
final class ContinuousScanCoordinator: ObservableObject {
    enum Phase: Equatable {
        case ready
        case recognizing
        case reviewing
    }

    @Published private(set) var phase: Phase = .ready
    @Published private(set) var scan: ExpiryOCRService.Scan?
    @Published private(set) var saved: [ContinuousScanStore.Saved] = []
    @Published private(set) var notice: String?
    @Published private(set) var cameraStatus: ScanSessionStatus = .idle
    @Published private(set) var liveBarcode: String?

    let session: ScanSessionControlling
    /// 两个闭包都是 @MainActor：识别本身在 `ExpiryOCRService` 内部跳去后台队列，
    /// 存盘要碰 SwiftData —— 两头都留在主线上，调用方才不必自己猜在哪跑。
    private let recognize: @MainActor (UIImage) async throws -> ExpiryOCRService.Scan
    private let store: @MainActor (ExpiryOCRConfirmation) throws -> ContinuousScanStore.Saved

    init(
        session: ScanSessionControlling,
        recognize: @escaping @MainActor (UIImage) async throws -> ExpiryOCRService.Scan,
        store: @escaping @MainActor (ExpiryOCRConfirmation) throws -> ContinuousScanStore.Saved
    ) {
        self.session = session
        self.recognize = recognize
        self.store = store
        session.onStatus = { [weak self] status in
            Task { @MainActor in self?.cameraStatus = status }
        }
        session.onBarcode = { [weak self] code in
            Task { @MainActor in self?.liveBarcode = code }
        }
        session.start()
    }

    var savedCount: Int { saved.count }

    var previewLayer: AVCaptureVideoPreviewLayer? { session.previewLayer }

    /// 快门：认一件。
    func captureAndRecognize() {
        guard phase == .ready else { return }
        phase = .recognizing
        Task { await recognizeNextFrame() }
    }

    func confirm(_ confirmation: ExpiryOCRConfirmation) {
        do {
            saved.insert(try store(confirmation), at: 0)
        } catch {
            notice = error.localizedDescription
        }
        // 存完直接回到取景（方案 §20），不停下来问「要不要继续」。
        scan = nil
        phase = .ready
    }

    func cancelReview() {
        scan = nil
        phase = .ready
    }

    func clearNotice() { notice = nil }

    func finish() {
        session.stop()
    }

    private func recognizeNextFrame() async {
        guard let frame = await session.captureFrame() else {
            notice = "没拍到东西，对准包装再来一次。"
            phase = .ready
            return
        }
        do {
            scan = try await recognize(frame)
            phase = .reviewing
        } catch {
            notice = error.localizedDescription
            phase = .ready
        }
    }
}
