import XCTest
import UIKit
@testable import Saury

/// 外部入口 → 添加表单那一段（任务书 §10.5）。
///
/// 这一层以前唯一被验过的部分是「队列能存下一条」，而用户真正抱怨的那三件事都没人问：
/// 分享的图片去哪了（答案是 `case .image: continue`，一声不吭扔掉）、
/// 链接说「记在来源里」但订阅压根没有来源字段、
/// 快捷指令带进来的老「到期物品」草稿把价格和保质期一起灌进了订阅表单。
/// 这三条都在这里问，因为它们都不需要 UI 就能问清楚。
final class ExternalIntakeTests: XCTestCase {
    private func draft(_ payload: ExternalPayload, source: String = "分享扩展") -> ExternalDraft {
        ExternalDraft(id: UUID(), createdAt: Date(), source: source, payload: payload)
    }

    // MARK: - 文字

    /// 名字取「第一行有内容的那一行」：分享出来的文字经常顶着一个空行开头，
    /// 照字面只读第一行会把这种正常内容判成「没有能用的」。
    func testTextNamesTheSubscriptionAfterItsFirstLineWithContent() throws {
        let prefill = try ExternalIntake.prefill(for: draft(.text("\n\n  净云会员\n￥298/年")))

        XCTAssertEqual(prefill.name, "净云会员")
    }

    /// 用户给的文字不能读一行就丢掉剩下的：其余各行进备注。
    func testTextKeepsTheRemainingLinesInTheNote() throws {
        let prefill = try ExternalIntake.prefill(for: draft(.text("净云会员\n年付 298\n到期 2027-01-01")))

        XCTAssertEqual(prefill.note, "年付 298\n到期 2027-01-01")
    }

    func testSingleLineTextLeavesTheNoteEmpty() throws {
        let prefill = try ExternalIntake.prefill(for: draft(.text("净云会员")))

        XCTAssertEqual(prefill.name, "净云会员")
        XCTAssertNil(prefill.note)
    }

    /// 一句能用的文字都没有：必须抛，不能弹一张全空的表单当成功。
    func testTextWithNothingUsableIsRefusedNotSilentlyAccepted() {
        XCTAssertThrowsError(try ExternalIntake.prefill(for: draft(.text("   \n\n  ")))) { error in
            let problem = error as? ExternalIntake.Problem
            XCTAssertEqual(problem, .nothingUsable(source: "分享扩展"))
        }
    }

    // MARK: - 链接

    /// 名字取域名，整条链接落在备注 —— 订阅这一层没有独立的来源字段，
    /// 说「记在来源里」而哪儿都不写就是 §10.5 讲的静默丢弃。
    func testUrlNamesTheSubscriptionAfterItsHostAndKeepsTheLink() throws {
        let prefill = try ExternalIntake.prefill(for: draft(.url("https://netflix.com/account")))

        XCTAssertEqual(prefill.name, "netflix.com")
        XCTAssertEqual(prefill.note, "https://netflix.com/account")
    }

    func testUrlDropsTheWwwPrefixFromTheName() throws {
        XCTAssertEqual(try ExternalIntake.prefill(for: draft(.url("https://www.iCloud.com/x"))).name,
                       "icloud.com")
    }

    /// 分享扩展有时递回来一个不像 URL 的字符串。不能因为它解不开就把整条丢掉：
    /// 原文当名字带进去，用户改一个字就能存。
    func testUrlThatDoesNotParseFallsBackToTheRawString() throws {
        let prefill = try ExternalIntake.prefill(for: draft(.url("不是个链接")))

        XCTAssertEqual(prefill.name, "不是个链接")
        XCTAssertEqual(prefill.note, "不是个链接")
    }

    /// 有 scheme 没 host（`file:///x`、`mailto:`）：名字退回原文，别留一个空名字。
    func testUrlWithoutAHostStillProducesAName() throws {
        let prefill = try ExternalIntake.prefill(for: draft(.url("mailto:someone@example.com")))

        XCTAssertFalse(prefill.name.isEmpty)
    }

    // MARK: - 快捷指令字段（老「到期物品」草稿）

    /// 只认名字。价格、到期日、周期、分类一套都不能变成订阅的默认值（§10.5）。
    func testLegacyFieldDraftContributesOnlyItsName() throws {
        let legacy = ExternalItemDraft(
            name: "牛奶",
            priceMinorUnits: 1990,
            currencyCode: "USD",
            expiryDate: Date(timeIntervalSince1970: 1_700_000_000),
            recurrence: .yearly,
            category: .food,
            sourceURL: nil
        )

        let prefill = try ExternalIntake.prefill(for: draft(.fields(legacy), source: "快捷指令"))

        XCTAssertEqual(prefill.name, "牛奶")
        XCTAssertNil(prefill.note)
        XCTAssertNil(prefill.iconImageFile)
    }

    /// 老草稿里的链接是有信息量的，落在备注里；但它不该顶替名字。
    func testLegacyFieldDraftKeepsItsSourceLinkInTheNote() throws {
        let legacy = ExternalItemDraft(name: "净云", sourceURL: "https://jingyun.example/a")

        XCTAssertEqual(try ExternalIntake.prefill(for: draft(.fields(legacy))).note,
                       "https://jingyun.example/a")
    }

    func testLegacyFieldDraftWithoutANameIsRefused() {
        let legacy = ExternalItemDraft(name: "   ", priceMinorUnits: 1990)
        XCTAssertThrowsError(try ExternalIntake.prefill(for: draft(.fields(legacy), source: "快捷指令"))) { error in
            XCTAssertEqual(error as? ExternalIntake.Problem, .nothingUsable(source: "快捷指令"))
        }
    }

    // MARK: - 图片

    /// 图片这一支唯一该碰外部世界的地方是「把文件搬进图标库」，
    /// 搬完的名字就是表单的图标。这一条以前压根不存在。
    func testImageHandsItsFileNameToThePromoterAndUsesTheResultAsTheIcon() throws {
        var seen: [String] = []
        let prefill = try ExternalIntake.prefill(
            for: draft(.image("abc.jpg")),
            promoting: { seen.append($0); return "moved.png" }
        )

        XCTAssertEqual(seen, ["abc.jpg"])
        XCTAssertEqual(prefill.iconImageFile, "moved.png")
        XCTAssertTrue(prefill.name.isEmpty, "一张图说不出订阅名字，不能替用户编一个")
    }

    /// 搬不动就抛出去。返回 nil / 空字符串让表单当「没有图标」，
    /// 那就是把失败说成成功。
    func testImagePromotionFailureIsNotSwallowed() {
        XCTAssertThrowsError(try ExternalIntake.prefill(
            for: draft(.image("abc.jpg")),
            promoting: { _ in throw SharedImageIngest.Problem.undecodable("abc.jpg") }
        )) { error in
            XCTAssertEqual(error as? SharedImageIngest.Problem, .undecodable("abc.jpg"))
        }
    }

    /// 其他几种不该去动图标库：每次消费都建一张孤儿图，孤儿回收就白做了。
    func testNonImageKindsNeverTouchTheImageStore() throws {
        var touched = 0
        let promote: (String) throws -> String = { _ in touched += 1; return "x.png" }

        _ = try ExternalIntake.prefill(for: draft(.text("净云")), promoting: promote)
        _ = try ExternalIntake.prefill(for: draft(.url("https://a.com")), promoting: promote)
        _ = try ExternalIntake.prefill(for: draft(.fields(ExternalItemDraft(name: "牛奶"))), promoting: promote)

        XCTAssertEqual(touched, 0)
    }
}

/// 暂存图片 → 图标库那一跳（§10.5「分享图片时不得静默丢弃」的另一半）。
///
/// 搬文件这件事必须在失败的时候说得出失败在哪：App Group 没配、扩展那次没写成功、
/// 文件被截断、磁盘写不进 —— 四种表现都一样「图标没设置上」，但用户能做的只有被告知。
final class SharedImageIngestTests: XCTestCase {
    private var sandbox: URL!
    private var pending: URL!
    private var store: IconImageStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("SauryIngest-\(UUID().uuidString)", isDirectory: true)
        pending = sandbox.appendingPathComponent("Pending", isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        store = IconImageStore(root: sandbox.appendingPathComponent("Icons", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
        try super.tearDownWithError()
    }

    /// 一张真图的字节。扩展那边落盘的是 JPEG，这里喂 PNG 就够：
    /// `promote` 认的是内容能不能解出图，不看文件名后缀。
    private func stage(_ fileName: String, data: Data) throws {
        try data.write(to: pending.appendingPathComponent(fileName))
    }

    private func pngData(_ edge: CGFloat = 40) -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: edge, height: edge)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
        }
        return image.pngData()!
    }

    /// 搬进来的那张图必须真的能当图标读出来，并且暂存文件不再留着 ——
    /// 队列那一条已经消费了，暂存目录里剩一张没人认领的图就是漏。
    func testPromoteMovesTheImageIntoTheIconLibraryAndClearsTheStagedFile() throws {
        try stage("card.jpg", data: pngData())

        let stored = try SharedImageIngest.promote("card.jpg", from: pending, store: store)

        XCTAssertFalse(stored.isEmpty)
        XCTAssertNotNil(store.image(for: stored), "图标库里读不出来，表单上就是一个空圈")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: pending.appendingPathComponent("card.jpg").path))
    }

    /// 文件名来自别处写下的 JSON，不能当可信路径：带分隔符的名字能把文件写出图标目录。
    func testPathLikeFileNamesAreRefused() {
        for name in ["../../default.store", "a/b.png", "a\\b.png", "", ".", ".."] {
            XCTAssertThrowsError(try SharedImageIngest.promote(name, from: pending, store: store), name) { error in
                XCTAssertEqual(error as? SharedImageIngest.Problem, .unsafeFileName(name), name)
            }
        }
    }

    /// 拒绝发生在读盘之前：这种名字即便文件不存在也不能被拿去探路径。
    func testUnsafeNameIsRefusedEvenWithoutAStagingDirectory() {
        XCTAssertThrowsError(try SharedImageIngest.promote("../x.png", from: nil, store: store)) { error in
            XCTAssertEqual(error as? SharedImageIngest.Problem, .unsafeFileName("../x.png"))
        }
    }

    /// App Group 没配上（真机上扩展和主 App 不在同一个组就是这个样子）。
    func testMissingStagingDirectorySaysSo() {
        XCTAssertThrowsError(try SharedImageIngest.promote("card.jpg", from: nil, store: store)) { error in
            XCTAssertEqual(error as? SharedImageIngest.Problem, .stagingUnavailable("card.jpg"))
        }
    }

    /// 队列里有条目、磁盘上没这个文件：扩展写完被系统清了，或者根本没写成功。
    func testAbsentStagedFileIsReportedAsUndecodable() {
        XCTAssertThrowsError(try SharedImageIngest.promote("gone.jpg", from: pending, store: store)) { error in
            XCTAssertEqual(error as? SharedImageIngest.Problem, .undecodable("gone.jpg"))
        }
    }

    /// 文件在，但解不出图（截断的 JPEG、或者被当图片传上来的文本）。
    func testNonImageBytesAreReportedAsUndecodable() throws {
        try stage("broken.jpg", data: Data("这不是图片".utf8))

        XCTAssertThrowsError(try SharedImageIngest.promote("broken.jpg", from: pending, store: store)) { error in
            XCTAssertEqual(error as? SharedImageIngest.Problem, .undecodable("broken.jpg"))
        }
    }

    /// 图能解出来、目录写不进（磁盘满、路径被普通文件占住）：这一种要说清楚是存不进去，
    /// 不能和「读不出来」用同一句话糊过去。
    func testStoreFailureIsReportedApartFromDecodingFailure() throws {
        try stage("card.jpg", data: pngData())
        let blocker = sandbox.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let unwritable = IconImageStore(root: blocker.appendingPathComponent("Icons", isDirectory: true))

        XCTAssertThrowsError(try SharedImageIngest.promote("card.jpg", from: pending, store: unwritable)) { error in
            XCTAssertEqual(error as? SharedImageIngest.Problem, .storeFailed("card.jpg"))
        }
        // 没搬成，暂存那张得还在 —— 用户还可以自己从相册再选一次。
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.appendingPathComponent("card.jpg").path))
    }

    /// 四种失败都得能念出一句人话：`WriteFeedbackCenter` 直接把 banner 交给
    /// `errorDescription`，返回 nil 的话用户看到的是「什么都没发生」。
    func testEveryFailureHasSomethingToSay() {
        for problem in [SharedImageIngest.Problem.unsafeFileName("a"),
                        .stagingUnavailable("a"), .undecodable("a"), .storeFailed("a")] {
            XCTAssertNotNil(problem.errorDescription)
            XCTAssertFalse(problem.errorDescription!.isEmpty)
        }
    }

    /// 大图进图标库要按图标库那条规矩缩到 512 以内，不能把分享的 4032×3024 原图直接存下。
    func testPromotedImageGoesThroughTheIconStoreResize() throws {
        try stage("big.jpg", data: pngData(1200))

        let stored = try SharedImageIngest.promote("big.jpg", from: pending, store: store)

        XCTAssertEqual(store.image(for: stored)?.size.width ?? 0, 512, accuracy: 1)
    }
}

/// 收件队列本身（§10.5「草稿队列按顺序消费，不重复、不丢失」）。
///
/// 这里测的是「队列」而不只是「一次投递」：一次只处理一条的实现，用户连分享三次
/// 就只剩最后一条，而且前两次连失败都不报。`storage` 换成独立 suite，
/// 免得跑一次单测就在真机上留一条待办。
@MainActor
final class ExternalInputQueueTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "SauryExternalInputQueueTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        ExternalInputStore.storage = defaults
    }

    override func tearDownWithError() throws {
        ExternalInputStore.storage = UserDefaults(suiteName: ExternalInputStore.suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    /// 只看种类，不做 `ExternalPayload` 的 Equatable（它带的老草稿类型不该为此改动）。
    private func kinds(of drafts: [ExternalDraft]) -> [String] {
        drafts.map { draft in
            switch draft.payload {
            case .text: return "text"
            case .url: return "url"
            case .image: return "image"
            case .fields: return "fields"
            }
        }
    }

    func testEmptyQueueHandsOutNothing() {
        XCTAssertNil(ExternalInputStore.consume())
        XCTAssertTrue(ExternalInputStore.queue().isEmpty)
    }

    /// 连分享三条：进来的顺序就是消费的顺序，一条不多一条不少，取完就停。
    func testArrivalsLeaveInTheSameOrderTheyCame() {
        ExternalInputStore.store(.text("第一条"), source: "分享扩展")
        ExternalInputStore.store(.url("https://a.com"), source: "分享扩展")
        ExternalInputStore.store(.image("x.jpg"), source: "分享扩展")

        XCTAssertEqual(kinds(of: ExternalInputStore.queue()), ["text", "url", "image"])

        var drained: [String] = []
        var names: [String] = []
        while let draft = ExternalInputStore.consume() {
            drained.append(contentsOf: kinds(of: [draft]))
            if case .text(let text) = draft.payload { names.append(text) }
        }

        XCTAssertEqual(drained, ["text", "url", "image"])
        XCTAssertEqual(names, ["第一条"])
        XCTAssertNil(ExternalInputStore.consume(), "取完就是取完，不能凭空再生一条")
        XCTAssertTrue(ExternalInputStore.queue().isEmpty)
    }

    /// 光是看一眼队列不算消费：不消费的话下一条永远不会来。
    func testReadingTheQueueLeavesItIntact() {
        ExternalInputStore.store(.text("甲"), source: "分享扩展")
        ExternalInputStore.store(.text("乙"), source: "分享扩展")

        _ = ExternalInputStore.queue()
        _ = ExternalInputStore.queue()

        XCTAssertEqual(ExternalInputStore.queue().count, 2)
        XCTAssertEqual(ExternalInputStore.consume()?.payloadText, "甲")
        XCTAssertEqual(ExternalInputStore.consume()?.payloadText, "乙")
    }

    /// 图片那一条在队列里也得原样出来：文件名一丢，那张图就找不回来了，
    /// 而用户在扩展那边明明按了「存进」。
    func testAnImageDraftKeepsItsFileNameThroughTheQueue() {
        ExternalInputStore.store(.image("E3F0B0D6.jpg"), source: "分享扩展")

        XCTAssertEqual(ExternalInputStore.consume()?.payloadImage, "E3F0B0D6.jpg")
    }

    /// 主 App 比扩展旧、认不出某个 `kind` 时：那一条留在队里，看得懂的照旧能消费。
    /// 整份一起解码的话，这一条会把整个队列判成解不开，用户后面分享的每一条都进不来。
    func testADraftTheAppCannotReadStaysBehindWithoutBlockingTheRest() throws {
        try seed([
            ["id": UUID().uuidString, "createdAt": 0, "source": "分享扩展",
             "payload": ["kind": "video", "value": "clip.mp4"]],
            ["id": UUID().uuidString, "createdAt": 0, "source": "分享扩展",
             "payload": ["kind": "text", "value": "净云会员"]]
        ])

        XCTAssertEqual(ExternalInputStore.unreadableCount(), 1)
        XCTAssertEqual(ExternalInputStore.consume()?.payloadText, "净云会员")
        XCTAssertTrue(ExternalInputStore.queue().isEmpty)
        XCTAssertEqual(ExternalInputStore.unreadableCount(), 1, "认不出那条不能就这么消失")
    }

    /// 认不出的那一条要活过一次「写」：往队列里加新东西时把它原样带回去。
    func testAnUnreadableDraftSurvivesANewArrival() throws {
        try seed([["id": UUID().uuidString, "createdAt": 0, "source": "分享扩展",
               "payload": ["kind": "video", "value": "clip.mp4"]]])

        ExternalInputStore.store(.text("净云会员"), source: "分享扩展")

        XCTAssertEqual(ExternalInputStore.unreadableCount(), 1)
        XCTAssertEqual(ExternalInputStore.queue().count, 1)
    }

    /// 整份不是数组（被别的东西写过这个 key）：不写回去，也就不把用户的队抹掉。
    func testAWholeQueueInWrongShapeIsLeftAlone() throws {
        defaults.set(try JSONSerialization.data(withJSONObject: ["不是": "数组"]),
                     forKey: ExternalInputStore.key)

        XCTAssertTrue(ExternalInputStore.queue().isEmpty)
        XCTAssertNil(ExternalInputStore.consume())

        let raw = defaults.data(forKey: ExternalInputStore.key)
        XCTAssertNotNil(raw, "解不开就重写一次，等于把不是自己写的东西抹了")
    }

    /// 老格式只有一个草稿位（`qijian.externalItemDraft`）：读出来当队列里最早的那一条，
    /// 但在它真的被处理掉之前不能消失 —— 「看一眼」就把用户的旧草稿抹掉就是丢失。
    func testLegacySingleSlotDraftIsOfferedAndNotLostByPeeking() throws {
        defaults.set(try JSONEncoder().encode(ExternalItemDraft(name: "牛奶", priceMinorUnits: 1990)),
                     forKey: "qijian.externalItemDraft")

        XCTAssertEqual(ExternalInputStore.queue().count, 1, "只看一眼不该把它消费掉")
        XCTAssertEqual(ExternalInputStore.queue().count, 1, "再看一眼还是不该")
        XCTAssertNotNil(defaults.data(forKey: "qijian.externalItemDraft"))

        let consumed = ExternalInputStore.consume()

        XCTAssertEqual(consumed?.payloadFieldsName, "牛奶")
        XCTAssertTrue(ExternalInputStore.queue().isEmpty)
        XCTAssertNil(defaults.data(forKey: "qijian.externalItemDraft"), "消费掉了就该换掉老那一格")
    }

    /// 老那一条比新分享进来的更早，所以它排在前头；两条都要在。
    func testLegacySlotJoinsTheQueueAheadOfNewerArrivals() throws {
        defaults.set(try JSONEncoder().encode(ExternalItemDraft(name: "旧的一条")),
                     forKey: "qijian.externalItemDraft")
        ExternalInputStore.store(.text("新的一条"), source: "分享扩展")

        XCTAssertEqual(ExternalInputStore.queue().count, 2)
        XCTAssertEqual(ExternalInputStore.consume()?.payloadFieldsName, "旧的一条")
        XCTAssertEqual(ExternalInputStore.consume()?.payloadText, "新的一条")
        XCTAssertNil(ExternalInputStore.consume())
    }

    /// 每一条都带着自己进来的时间和来源，页面才说得出「这条是哪次分享带进来的」。
    func testEachEntryCarriesItsSource() {
        ExternalInputStore.store(.text("净云"), source: "快捷指令")

        let draft = ExternalInputStore.queue().first

        XCTAssertEqual(draft?.source, "快捷指令")
        XCTAssertGreaterThan(draft?.createdAt ?? .distantPast, Date(timeIntervalSinceNow: -60))
    }

    private func seed(_ objects: [[String: Any]]) throws {
        defaults.set(try JSONSerialization.data(withJSONObject: objects),
                     forKey: ExternalInputStore.key)
    }
}

private extension ExternalDraft {
    var payloadText: String? {
        if case .text(let text) = payload { return text }
        return nil
    }

    var payloadImage: String? {
        if case .image(let fileName) = payload { return fileName }
        return nil
    }

    var payloadFieldsName: String? {
        if case .fields(let fields) = payload { return fields.name }
        return nil
    }
}
