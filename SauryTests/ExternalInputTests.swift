import UIKit
import XCTest

@testable import Saury

/// 外部输入的收件队列和分享中转（方案 §57、§58）。
///
/// 这里读写的是真的 App Group 域，所以每条测试都要把原来的值放回去。
@MainActor
final class ExternalInputTests: XCTestCase {
    private let suiteName = ExternalInputStore.suiteName
    private let queueKey = ExternalInputStore.key
    private let legacyKey = "qijian.externalItemDraft"
    private var previousQueue: Data?
    private var previousLegacy: Data?

    override func setUpWithError() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        previousQueue = defaults.data(forKey: queueKey)
        previousLegacy = defaults.data(forKey: legacyKey)
        defaults.removeObject(forKey: queueKey)
        defaults.removeObject(forKey: legacyKey)
    }

    override func tearDown() {
        super.tearDown()
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        if let previousQueue { defaults.set(previousQueue, forKey: queueKey) } else { defaults.removeObject(forKey: queueKey) }
        if let previousLegacy { defaults.set(previousLegacy, forKey: legacyKey) } else { defaults.removeObject(forKey: legacyKey) }
    }

    // MARK: - 队列

    func testConsecutiveInputsStayInOrderInsteadOfOverwriting() {
        ExternalInputStore.store(.text("纯牛奶 1L 保质期到 2026.10"), source: "分享扩展")
        ExternalInputStore.store(.url("https://www.netflix.com/account"), source: "分享扩展")
        ExternalInputStore.store(.image("MILK.jpg"), source: "分享扩展")

        XCTAssertEqual(ExternalInputStore.queue().count, 3, "只有一个草稿位时后一条会把前一条顶掉（方案 §58）")

        guard case .text? = ExternalInputStore.consume()?.payload else { return XCTFail("第一条该是文字") }
        guard case .url? = ExternalInputStore.consume()?.payload else { return XCTFail("第二条该是链接") }
        guard case .image(let fileName)? = ExternalInputStore.consume()?.payload else { return XCTFail("第三条该是图片") }
        XCTAssertEqual(fileName, "MILK.jpg", "队列里只带文件名，图本身在暂存目录")
        XCTAssertNil(ExternalInputStore.consume(), "队列空了不该编出一条记录来")
    }

    /// 分享扩展是另一个 target，只能靠这份 JSON 传话：它手写出来的条目必须被这边认得。
    func testTheJSONTheShareExtensionWritesIsAQueueEntryTheAppCanRead() throws {
        let fileName = "6B7A8C9D-0000-0000-0000-000000000001.jpg"
        let entry: [String: Any] = [
            "id": UUID().uuidString,
            "createdAt": Date().timeIntervalSinceReferenceDate,
            "source": "分享扩展",
            "payload": ["kind": "image", "value": fileName]
        ]
        let data = try XCTUnwrap(try? JSONSerialization.data(withJSONObject: [entry]))
        UserDefaults(suiteName: suiteName)?.set(data, forKey: queueKey)

        guard case .image(let taken)? = ExternalInputStore.consume()?.payload else {
            return XCTFail("扩展写出来的条目应该被认成图片")
        }
        XCTAssertEqual(taken, fileName)
    }

    /// 反过来钉一次：主 App 编出去的形状就得是上面那份手写形状，不然两边各说各话。
    func testTheAppEncodesTheSameShapeTheExtensionHandWrites() throws {
        let draft = ExternalDraft(
            id: UUID(uuidString: "6B7A8C9D-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            source: "分享扩展",
            payload: .image("P.jpg")
        )
        let data = try XCTUnwrap(try? JSONEncoder().encode([draft]))
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let payload = try XCTUnwrap(entries.first?["payload"] as? [String: Any])

        XCTAssertEqual(payload["kind"] as? String, "image")
        XCTAssertEqual(payload["value"] as? String, "P.jpg")
        XCTAssertEqual(entries.first?["source"] as? String, "分享扩展")
        XCTAssertEqual(entries.first?["id"] as? String, "6B7A8C9D-0000-0000-0000-000000000001")
        XCTAssertEqual(entries.first?["createdAt"] as? Double, 800_000_000)
    }

    func testFieldDraftsSurviveTheQueueRoundTrip() throws {
        let draft = ExternalItemDraft(name: "纯牛奶 1L", expiryDate: Date(timeIntervalSinceReferenceDate: 800_000_000))
        ExternalInputStore.store(.fields(draft), source: "快捷指令")

        let consumed = try XCTUnwrap(ExternalInputStore.consume())
        guard case .fields(let stored) = consumed.payload else { return XCTFail("字段草稿不该变成别的类型") }
        XCTAssertEqual(stored.name, "纯牛奶 1L")
        XCTAssertEqual(consumed.source, "快捷指令")
    }

    /// 老格式的那一个草稿位不能因为升级就凭空消失。
    func testASingleDraftFromTheOldFormatJoinsTheQueue() throws {
        let draft = ExternalItemDraft(name: "纯牛奶 1L", expiryDate: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let data = try XCTUnwrap(try? JSONEncoder().encode(draft))
        UserDefaults(suiteName: suiteName)?.set(data, forKey: legacyKey)

        let consumed = try XCTUnwrap(ExternalInputStore.consume())
        guard case .fields(let fields) = consumed.payload else { return XCTFail("旧格式该落成字段草稿") }
        XCTAssertEqual(fields.name, "纯牛奶 1L")
        XCTAssertEqual(fields.expiryDate, Date(timeIntervalSinceReferenceDate: 800_000_000))
        XCTAssertEqual(consumed.source, "外部输入")
        XCTAssertNil(ExternalInputStore.consume(), "消费过就不该再出现一次")
    }

    func testAnEmptyQueueConsumesNothingAndTouchesNothing() {
        XCTAssertNil(ExternalInputStore.consume())
        XCTAssertTrue(ExternalInputStore.queue().isEmpty)
    }

    // MARK: - 暂存图片

    func testInboxHandsThePhotoOverAndTakesItsFileBack() throws {
        let inbox = SharedInbox(directory: try temporaryInboxDirectory())
        let fileName = try XCTUnwrap(inbox.store(swatch()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(inbox.directory).appendingPathComponent(fileName).path))

        XCTAssertNotNil(inbox.takeImage(fileName), "主 App 要能拿到那张图去识别")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: try XCTUnwrap(inbox.directory).appendingPathComponent(fileName).path),
            "递出去之后不能把文件留在共享目录里（方案 §57）"
        )
        XCTAssertNil(inbox.takeImage(fileName), "同一张图取第二次不该再有")
    }

    func testInboxWithoutASharedContainerReportsItselfUnavailable() throws {
        let inbox = SharedInbox(directory: nil)
        XCTAssertFalse(inbox.isAvailable)
        XCTAssertNil(inbox.store(swatch()))
        XCTAssertNil(inbox.takeImage("anything.jpg"))
    }

    // MARK: - 帮助

    private func temporaryInboxDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SauryInbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// 测试用的小图：内容不重要，重要的是它编得出文件。
    private func swatch() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120)).image { renderer in
            UIColor.systemRed.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
        }
    }
}
