import AVFoundation
import SwiftData
import UIKit
import XCTest

@testable import Saury

/// 一个假会话：帧从数组里一张一张拿出来，拿光了就当没拍到。
///
/// 放在文件最外层是有原因的 —— 嵌套在 `@MainActor` 测试类里会继承那份隔离，
/// 就没法再满足 `ScanSessionControlling` 那些非隔离的要求了。
private final class FakeScanSession: ScanSessionControlling {
    var onStatus: ((ScanSessionStatus) -> Void) = { _ in }
    var onBarcode: ((String?) -> Void) = { _ in }
    var previewLayer: AVCaptureVideoPreviewLayer? { nil }

    private(set) var startCount = 0
    private(set) var stopCount = 0
    var frames: [UIImage] = []

    func start() {
        startCount += 1
        onStatus(.running)
    }

    func stop() { stopCount += 1 }

    func captureFrame() async -> UIImage? { frames.isEmpty ? nil : frames.removeFirst() }
}

/// 连续扫描那台状态机（方案 §20、§76）。
///
/// 这里最要紧的一条是 §76：会话开一次、用到底，不许每扫一件重建一次。模拟器上没有
/// 摄像头，所以拿一个假会话把「开了几次、什么时候关」变成能断言的数字。
@MainActor
final class ContinuousScanTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    private let expiry = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 12))!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Schema(versionedSchema: SaurySchemaV3.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = container.mainContext
    }

    // MARK: - 帮助

    private func frame() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { renderer in
            UIColor.systemRed.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
    }

    private func scan() -> ExpiryOCRService.Scan {
        ExpiryOCRService.Scan(
            image: frame(),
            page: OCRPage(lines: []),
            result: ExpiryOCRResult(entries: [
                ExpiryOCRCandidate(field: .name, value: .text("纯牛奶 1L"), confidence: 0.9),
                ExpiryOCRCandidate(field: .expiryDate, value: .date(expiry, alternatives: []), confidence: 0.9),
            ])
        )
    }

    private func confirmation() -> ExpiryOCRConfirmation {
        ExpiryOCRConfirmation(result: scan().result, openedToday: false, image: nil)
    }

    /// 只验状态机：存盘那一步另有 `ScanHistoryTests` 管，这里换一个必定成功的假存储。
    private func coordinator(
        _ session: FakeScanSession,
        recognize: @escaping @MainActor (UIImage) async throws -> ExpiryOCRService.Scan
    ) -> ContinuousScanCoordinator {
        ContinuousScanCoordinator(
            session: session,
            recognize: recognize,
            store: { _ in .init(name: "纯牛奶 1L", expiryDate: self.expiry, quantity: 1, merged: false) }
        )
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("等不到状态变化")
    }

    // MARK: - §76 会话只开一次

    func testSessionOpensOnceAndIsNotRebuiltBetweenItems() async throws {
        let session = FakeScanSession()
        session.frames = [frame(), frame(), frame()]
        let scanner = coordinator(session) { _ in self.scan() }
        XCTAssertEqual(session.startCount, 1, "建好就开一次")

        for _ in 0..<3 {
            scanner.captureAndRecognize()
            try await waitUntil { scanner.phase == .reviewing }
            scanner.confirm(confirmation())
        }

        XCTAssertEqual(scanner.savedCount, 3)
        XCTAssertEqual(session.startCount, 1, "扫三件不该再开一次会话（方案 §76）")
        XCTAssertEqual(session.stopCount, 0)
        scanner.finish()
        XCTAssertEqual(session.stopCount, 1, "退出时才关")
    }

    func testCameraStatusAndLiveBarcodeComeBackThroughTheCoordinator() async throws {
        let session = FakeScanSession()
        let scanner = coordinator(session) { _ in self.scan() }
        try await waitUntil { scanner.cameraStatus == .running }

        session.onBarcode("6901234567890")
        try await waitUntil { scanner.liveBarcode == "6901234567890" }
        session.onBarcode(nil)
        try await waitUntil { scanner.liveBarcode == nil }
    }

    // MARK: - 取景 → 识别 → 确认 → 回取景

    func testCaptureOpensTheReviewSheetAndConfirmReturnsToTheViewfinder() async throws {
        let session = FakeScanSession()
        session.frames = [frame()]
        let scanner = coordinator(session) { _ in self.scan() }

        scanner.captureAndRecognize()
        try await waitUntil { scanner.phase == .reviewing }
        XCTAssertNotNil(scanner.scan)
        XCTAssertTrue(session.frames.isEmpty, "那一帧被用掉了")

        scanner.confirm(confirmation())
        XCTAssertEqual(scanner.phase, .ready, "存完直接回到取景，不停下来问要不要继续（方案 §20）")
        XCTAssertNil(scanner.scan)
        XCTAssertEqual(scanner.savedCount, 1)
    }

    func testCancelingTheReviewLeavesNothingRecorded() async throws {
        let session = FakeScanSession()
        session.frames = [frame()]
        let scanner = coordinator(session) { _ in self.scan() }
        scanner.captureAndRecognize()
        try await waitUntil { scanner.phase == .reviewing }

        scanner.cancelReview()
        XCTAssertEqual(scanner.phase, .ready)
        XCTAssertEqual(scanner.savedCount, 0)
    }

    func testNothingInTheViewfinderGoesBackToReadyWithAHint() async throws {
        let session = FakeScanSession()
        let scanner = coordinator(session) { _ in self.scan() }

        scanner.captureAndRecognize()
        try await waitUntil { scanner.phase == .ready }
        XCTAssertNotNil(scanner.notice)
        XCTAssertEqual(scanner.savedCount, 0)
    }

    func testRecognitionFailureGoesBackToReadyInsteadOfStuckRecognizing() async throws {
        let session = FakeScanSession()
        session.frames = [frame()]
        let scanner = coordinator(session) { _ in throw ExpiryOCRService.OCRError.noText }

        scanner.captureAndRecognize()
        try await waitUntil { scanner.phase == .ready }
        XCTAssertEqual(scanner.notice, ExpiryOCRService.OCRError.noText.errorDescription)
        XCTAssertNil(scanner.scan)
    }

    func testSecondShutterPressWhileRecognizingIsIgnored() async throws {
        let session = FakeScanSession()
        session.frames = [frame(), frame()]
        let scanner = coordinator(session) { _ in
            try await Task.sleep(for: .milliseconds(50))
            return self.scan()
        }

        scanner.captureAndRecognize()
        scanner.captureAndRecognize()
        try await waitUntil { scanner.phase == .reviewing }
        XCTAssertEqual(session.frames.count, 1, "识别期间再按快门不该又吃掉一帧")
    }

    // MARK: - 接真存储走一遍

    func testConfirmingThroughTheRealStoreWritesItemAndPictureRecord() async throws {
        let session = FakeScanSession()
        session.frames = [frame()]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SauryImages-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContinuousScanStore(context: context, images: ImageStore(root: directory))
        let scanner = ContinuousScanCoordinator(
            session: session,
            recognize: { _ in self.scan() },
            store: { try store.save($0) }
        )

        scanner.captureAndRecognize()
        try await waitUntil { scanner.phase == .reviewing }
        let result = try XCTUnwrap(scanner.scan?.result)
        scanner.confirm(ExpiryOCRConfirmation(result: result, openedToday: false, image: frame()))

        XCTAssertEqual(try context.fetch(FetchDescriptor<ExpiryItem>()).count, 1)
        XCTAssertEqual(scanner.saved.first?.name, "纯牛奶 1L")
        let events = try context.fetch(FetchDescriptor<ExpiryEvent>())
        XCTAssertEqual(events.count, 1, "连续扫描存下的每一件都要在活动记录里留一条")
        XCTAssertNotNil(events.first?.imageIdentifier)
    }
}
