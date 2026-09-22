import AVFoundation
import CoreImage
import UIKit

/// 真正的摄像头会话（方案 §20、§27、§75、§76、§81）。
///
/// 配置一次就一直开着：预览 + 条码实时识别（metadata）+ 视频帧（拿去做 OCR）。
/// 连续扫描期间不重建会话，权限也等到第一次 `start()` 才申请。
/// 状态和条码只往外推回调，自己不持有可观察状态 —— 观察的人是协调者，
/// 界面上只该有一个数据来源（方案 §76）。
final class CameraSession: NSObject, ScanSessionControlling {
    typealias Status = ScanSessionStatus

    var onStatus: ((Status) -> Void) = { _ in }
    var onBarcode: ((String?) -> Void) = { _ in }

    var previewLayer: AVCaptureVideoPreviewLayer? { layer }

    private let layer = AVCaptureVideoPreviewLayer()
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    private let queue = DispatchQueue(label: "com.guofeng.saury.camera", qos: .userInitiated)
    private let lock = NSLock()
    private var waiters: [Waiter] = []
    private var configured = false

    /// 识别用的边长上限。48MP 原图直接喂给 Vision 只会更慢，不会更准（方案 §75）。
    private static let recognitionMaxEdge: CGFloat = 1600

    override init() {
        super.init()
        layer.videoGravity = .resizeAspectFill
        session.sessionPreset = .hd1920x1080
    }

    // MARK: - ScanSessionControlling

    func start() {
        queue.async { self.requestAccessAndRun() }
    }

    func stop() {
        queue.async {
            guard self.configured else { return }
            self.session.stopRunning()
            self.configured = false
            self.publish(.idle)
            self.failAllWaiters()
        }
    }

    /// 下一帧。三秒内没等到就算没拍到，不能让调用方一直挂着。
    func captureFrame() async -> UIImage? {
        await withCheckedContinuation { continuation in
            let waiter = Waiter(continuation)
            lock.lock()
            waiters.append(waiter)
            lock.unlock()
            queue.asyncAfter(deadline: .now() + 3) { self.expire(waiter) }
        }
    }

    // MARK: - 会话搭建

    private func requestAccessAndRun() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            attachInputsAndRun()
        case .notDetermined:
            // 授权回调不在自己的队列上：跳回来，配置永远只在这条队列上做。
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.queue.async { self.attachInputsAndRun() }
                } else {
                    self.publish(.denied)
                }
            }
        default:
            publish(.denied)
        }
    }

    private func attachInputsAndRun() {
        lock.lock()
        if configured {
            lock.unlock()
            return
        }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            lock.unlock()
            publish(.denied)
            return
        }
        configured = true
        lock.unlock()

        session.beginConfiguration()
        session.addInput(input)

        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: queue)
            let wanted: [AVMetadataObject.ObjectType] = [.ean13, .ean8, .upce, .qr]
            metadataOutput.metadataObjectTypes = metadataOutput.availableMetadataObjectTypes.filter { wanted.contains($0) }
        }
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        session.commitConfiguration()

        session.startRunning()
        publish(.running)
    }

    // MARK: - 往外推的东西

    /// 回调由协调者在主线程上收，所以这里保证主线程投递；
    /// 闭包本身在锁里读，避免和 `init` 的赋值抢。
    private func publish(_ status: Status) {
        lock.lock()
        let callback = onStatus
        lock.unlock()
        DispatchQueue.main.async { callback(status) }
    }

    private func publishBarcode(_ code: String?) {
        lock.lock()
        let callback = onBarcode
        lock.unlock()
        DispatchQueue.main.async { callback(code) }
    }

    /// 一次 `captureFrame()` 的等待者。`CheckedContinuation` 自己没法比较，
    /// 所以套一层壳，超时的和来帧的抢同一个壳，谁先锁到谁负责 resume。
    private final class Waiter {
        let continuation: CheckedContinuation<UIImage?, Never>
        var settled = false

        init(_ continuation: CheckedContinuation<UIImage?, Never>) {
            self.continuation = continuation
        }
    }

    private func deliver(_ image: UIImage) {
        lock.lock()
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            guard !waiter.settled else { continue }
            waiter.settled = true
            lock.unlock()
            waiter.continuation.resume(returning: image)
            return
        }
        lock.unlock()
    }

    private func expire(_ waiter: Waiter) {
        lock.lock()
        guard !waiter.settled else { lock.unlock(); return }
        waiter.settled = true
        waiters.removeAll { $0 === waiter }
        lock.unlock()
        waiter.continuation.resume(returning: nil)
    }

    private func failAllWaiters() {
        lock.lock()
        let pending = waiters.filter { !$0.settled }
        pending.forEach { $0.settled = true }
        waiters = []
        lock.unlock()
        pending.forEach { $0.continuation.resume(returning: nil) }
    }

    /// 视频帧是横的（传感器方向），预览是竖的：先转正，再缩到识别用的尺寸（方案 §75）。
    private static func prepared(_ buffer: CMSampleBuffer) -> UIImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        let extent = ciImage.extent
        guard let cgImage = context.createCGImage(ciImage, from: extent) else { return nil }
        // 后置摄像头在竖屏下顺时针转了 90°。
        let upright = UIImage(cgImage: cgImage, scale: 1, orientation: .right)
        let size = upright.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, recognitionMaxEdge / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            upright.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

extension CameraSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // 丢帧是常态（alwaysDiscardsLateVideoFrames），没人等帧时不用管。
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        lock.lock()
        let waiting = !waiters.isEmpty
        lock.unlock()
        guard waiting, let image = Self.prepared(sampleBuffer) else { return }
        deliver(image)
    }
}

extension CameraSession: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        publishBarcode(metadataObjects.compactMap { $0 as? AVMetadataMachineReadableCodeObject }.first?.stringValue)
    }
}
