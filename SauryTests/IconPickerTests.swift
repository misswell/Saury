import XCTest
import ImageIO
import SwiftUI
import UIKit
import PhotosUI
@testable import Saury

/// §7.2 图标选择那一整条链路的判断：什么时候算「没有图标」，什么时候算「没网」，
/// 一次查询该问到哪一步就停，旧结果什么时候不许盖新结果，写到盘上的文件谁负责收。
///
/// 网络走 `FakeTransport` 这个假件：`WebIconClient` / `AppStoreIconClient` 的判断
/// 一行都不改，只有「拿到字节」那一步换成记账。这样「404 和离线是两句话」
/// 「解析失败不算没搜到」这类规则才真的被测到。
///
/// 测不到的还是那几样：真站点的图标到底长什么样、4 MB 上限和 8 秒超时在真实
/// 连路上什么时候触发、相册选图的完整回图（`PhotosPickerItem` 造不出真条目）。
/// 它们在 `Docs/EON_QA.md` 里按「需真机/需联网验收」记，不在这里当作已过。
@MainActor
final class IconPickerTests: XCTestCase {
    private var tempRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots = []
        try super.tearDownWithError()
    }

    // MARK: - 脚手架

    private func makeStore() -> IconImageStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SauryIconTests.\(UUID().uuidString)", isDirectory: true)
        tempRoots.append(root)
        return IconImageStore(root: root)
    }

    private func makeModel(debounce: Duration = .seconds(2),
                           transport: FakeTransport,
                           store: IconImageStore? = nil) -> IconPickerModel {
        IconPickerModel(store: store ?? makeStore(), transport: transport, debounce: debounce)
    }

    /// 等一个异步动作真的发生，不是「睡一下再断言」。超时就明确失败。
    private func waitUntil(_ label: String, timeout: TimeInterval = 3,
                           _ happening: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !happening() {
            if Date() > deadline {
                XCTFail("等不到：\(label)")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func imageFailure(_ result: Result<UIImage, IconProblem>) -> IconProblem? {
        switch result {
        case .success: return nil
        case .failure(let problem): return problem
        }
    }

    private func searchFailure(_ result: Result<[AppStoreIconClient.AppResult], IconProblem>) -> IconProblem? {
        switch result {
        case .success: return nil
        case .failure(let problem): return problem
        }
    }

    // Result<Void, …> 比不了（Void 没有 Equatable），统一翻成「哪条不过」或 nil。
    private func verdictProblem(_ response: URLResponse) -> IconProblem? {
        switch HTTPIconTransport.verdict(of: response) {
        case .success: return nil
        case .failure(let problem): return problem
        }
    }

    private func queryItems(_ url: URL) -> [URLQueryItem] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    private func item(_ name: String, _ value: String) -> URLQueryItem {
        URLQueryItem(name: name, value: value)
    }

    private func http(_ code: Int, mime: String?) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let mime { headers["Content-Type"] = mime }
        return HTTPURLResponse(url: URL(string: "https://setapp.com/favicon.png")!,
                               statusCode: code, httpVersion: nil, headerFields: headers)!
    }

    // MARK: - 网址规范化（纯函数）

    func testHostExtractionKeepsOnlyTheHost() {
        XCTAssertEqual(WebIconClient.host(of: "  https://SETAPP.com/pricing?a=b  "), "setapp.com")
        XCTAssertEqual(WebIconClient.host(of: "icloud.com/"), "icloud.com")
        XCTAssertEqual(WebIconClient.host(of: "www.iCloud.com/#/mail"), "www.icloud.com")
        XCTAssertEqual(WebIconClient.host(of: "user@setapp.com:8443/x"), "setapp.com")
        XCTAssertEqual(WebIconClient.host(of: ""), "")
        XCTAssertEqual(WebIconClient.host(of: "   "), "")
        // 整串解析不动时不许退化成 "http"：那会变成一个谁都没填的主机。
        XCTAssertEqual(WebIconClient.host(of: "http://ex ample.com/"), "ex ample.com")
    }

    func testLooksLikeHostRejectsWhatShouldNeverGoOnline() {
        XCTAssertTrue(WebIconClient.looksLikeHost("setapp.com"))
        XCTAssertTrue(WebIconClient.looksLikeHost("a-b.c-d.org"))
        XCTAssertTrue(WebIconClient.looksLikeHost("under_score.cn"))
        XCTAssertFalse(WebIconClient.looksLikeHost("icloud"), "少了后缀要当场说清楚")
        XCTAssertFalse(WebIconClient.looksLikeHost("localhost"))
        XCTAssertFalse(WebIconClient.looksLikeHost(".com"))
        XCTAssertFalse(WebIconClient.looksLikeHost("com."))
        XCTAssertFalse(WebIconClient.looksLikeHost("a..com"))
        XCTAssertFalse(WebIconClient.looksLikeHost("-bad.com"))
        XCTAssertFalse(WebIconClient.looksLikeHost("bad-.com"))
        XCTAssertFalse(WebIconClient.looksLikeHost("ex ample.com"))
    }

    func testCandidatesGoFromSharpestToLastResort() {
        let urls = WebIconClient.candidates(forHost: "setapp.com")
        XCTAssertEqual(urls.count, 8)
        XCTAssertEqual(urls[0].absoluteString, "https://setapp.com/apple-touch-icon-180x180.png")
        XCTAssertEqual(Array(urls.map(\.path).prefix(5)),
                       ["/apple-touch-icon-180x180.png", "/apple-touch-icon-precomposed.png",
                        "/apple-touch-icon.png", "/favicon.png", "/favicon.ico"])
        XCTAssertEqual(urls[5].host, "www.google.com")
        XCTAssertEqual(queryItems(urls[5]), [item("domain", "setapp.com"), item("sz", "256")])
        XCTAssertEqual(queryItems(urls[7]), [item("domain", "setapp.com"), item("sz", "64")])
    }

    /// 兜底服务的 host 只能当值，不能当语法。直接字符串拼的话
    /// `a.com&evil=1` 会多带出一个查询参数，问的就不是这个站了。
    func testFallbackEncodesTheHostAsAValue() {
        let urls = WebIconClient.fallbackURLs(forHost: "a.com&evil=1")
        XCTAssertEqual(urls.count, 3)
        for (offset, url) in urls.enumerated() {
            XCTAssertEqual(queryItems(url), [item("domain", "a.com&evil=1"),
                                             item("sz", String([256, 128, 64][offset]))])
            XCTAssertEqual(queryItems(url).filter { $0.name == "evil" }.count, 0,
                           "多出来的参数说明没转义")
        }
    }

    // MARK: - 网址取图：问到哪一步该停

    func testWebIconTakesTheFirstUsablePathAndStops() async {
        let transport = FakeTransport()
        transport.responder = { url in
            url.path.contains("180x180") ? .success(pngData(180, 180)) : .failure(.noIcon)
        }
        let result = await WebIconClient(transport: transport).icon(for: "setapp.com")
        guard case .success(let image) = result else {
            return XCTFail("第一条路径就有图，不该往下走：\(result)")
        }
        XCTAssertEqual(max(image.size.width, image.size.height), 180, accuracy: 1)
        XCTAssertEqual(transport.hits.count, 1, "拿到了还接着问七次，就是白等")
    }

    func testTrackingPixelIsNotTreatedAsAnIcon() async {
        // 很多站对未知路径回一张 1×1 的灰点。八条都问完，最后说「这个站点没有现成的图标」。
        let transport = FakeTransport()
        transport.responder = { _ in .success(pngData(1, 1)) }
        let result = await WebIconClient(transport: transport).icon(for: "setapp.com")
        XCTAssertEqual(imageFailure(result), .noIcon)
        XCTAssertEqual(transport.hits.count, 8)
    }

    func testWebIconStopsAtTheFirstRealTransportProblem() async {
        for problem in [IconProblem.offline, .timedOut, .tooBig, .badResponse, .cancelled, .badHost] {
            let transport = FakeTransport()
            transport.responder = { _ in .failure(problem) }
            let result = await WebIconClient(transport: transport).icon(for: "setapp.com")
            XCTAssertEqual(imageFailure(result), problem, "\(problem) 要原话说出来，不能翻成没找到")
            XCTAssertEqual(transport.hits.count, 1, "\(problem) 不是「这条路径没图标」，接着问只是白等")
        }
    }

    func testWalkContinuesPastADeadPathButStopsAtAnOutage() async {
        let transport = FakeTransport()
        transport.responder = { url in
            url.path.contains("180x180") ? .failure(.noIcon) : .success(pngData(64, 64))
        }
        let result = await WebIconClient(transport: transport).icon(for: "setapp.com")
        guard case .success = result else { return XCTFail("第二条有图就该拿到：\(result)") }
        XCTAssertEqual(transport.hits.count, 2)
    }

    func testIncompleteHostNeverGoesOnline() async {
        let transport = FakeTransport()
        let result = await WebIconClient(transport: transport).icon(for: "icloud")
        XCTAssertEqual(imageFailure(result), .badHost)
        XCTAssertTrue(transport.hits.isEmpty, "明知问不到还发五条，是浪费不是重试")
    }

    func testBlankWebInputIsAnsweredWithoutNetworking() async {
        let transport = FakeTransport()
        let result = await WebIconClient(transport: transport).icon(for: "   ")
        XCTAssertEqual(imageFailure(result), .blank)
        XCTAssertTrue(transport.hits.isEmpty)
    }

    // MARK: - HTTP 那层的判断

    /// 传输层只管状态码。Content-Type 不参与判断 —— iTunes 给 JSON 却写着
    /// `text/javascript`，按类型放行会把这条正常结果挡成「不是图片」（`-saury-icon` 探针线上照出来的）。
    func testVerdictJudgesStatusNotContentType() {
        XCTAssertEqual(verdictProblem(http(404, mime: "text/html")), .noIcon)
        XCTAssertEqual(verdictProblem(http(500, mime: "image/png")), .badResponse)
        XCTAssertEqual(verdictProblem(http(200, mime: "text/html")), nil)
        XCTAssertNil(verdictProblem(http(200, mime: "text/javascript; charset=utf-8")))
        XCTAssertNil(verdictProblem(http(200, mime: "image/png")))
        XCTAssertNil(verdictProblem(http(200, mime: nil)))
    }

    /// 类型交给各自的解析器：HTML 喂给取图那条路，说出来的就是「不是图片」，
    /// 而不是靠传输层抢先猜。
    func testHTMLWhereAnIconWasExpectedIsStillRejected() async {
        let transport = FakeTransport()
        let html = Data("<html><body>rate limited</body></html>".utf8)
        transport.responder = { url in
            url.path.contains("180x180") ? .success(html) : .success(pngData(64, 64))
        }
        let result = await WebIconClient(transport: transport).icon(for: "setapp.com")
        guard case .success = result else { return XCTFail("第一张不是图，接着往下找：\(result)") }
        XCTAssertEqual(transport.hits.count, 2, "180x180 给的是网页，不该当成拿到图就收工")
    }

    func testURLErrorCodesFoldIntoWhatTheUserCanActOn() {
        XCTAssertEqual(HTTPIconTransport.problem(for: .cancelled), .cancelled)
        XCTAssertEqual(HTTPIconTransport.problem(for: .timedOut), .timedOut)
        XCTAssertEqual(HTTPIconTransport.problem(for: .badURL), .badHost)
        for code in [URLError.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
                     .networkConnectionLost, .dnsLookupFailed, .secureConnectionFailed, .dataNotAllowed] {
            XCTAssertEqual(HTTPIconTransport.problem(for: code), .offline, "\(code) 都归到看网络")
        }
    }

    func testEachProblemHasItsOwnSentence() {
        let problems: [IconProblem] = [.blank, .badHost, .offline, .timedOut, .cancelled,
                                        .tooBig, .notAnImage, .unreadableItem, .noIcon, .badResponse]
        let messages = problems.map(\.message)
        XCTAssertEqual(Set(messages).count, problems.count, "十种失败挤成几句话，等于没说")
        XCTAssertTrue(messages.allSatisfy { !$0.isEmpty })
        XCTAssertNotEqual(IconProblem.noIcon.message, IconProblem.offline.message,
                          "「这个站没有图标」和「连不上」是让用户做两件不同的事")
    }

    // MARK: - App Store 搜索

    func testAppStoreSearchParsesTrackIDNameAndArtwork() async {
        let transport = FakeTransport()
        transport.responder = { _ in .success(appJSON([(380, "爱奇艺", art(380))])) }
        let result = await AppStoreIconClient(transport: transport).search(term: "爱奇艺", storefront: "cn")
        guard case .success(let found) = result, let first = found.first else {
            return XCTFail("该解析出结果：\(result)")
        }
        XCTAssertEqual(first.id, 380)
        XCTAssertEqual(first.name, "爱奇艺")
        XCTAssertEqual(first.artworkURL?.absoluteString, art(380))
        let items = queryItems(transport.hits[0])
        XCTAssertTrue(items.contains { $0.name == "term" && $0.value == "爱奇艺" })
        XCTAssertTrue(items.contains { $0.name == "country" && $0.value == "cn" })
    }

    func testAppStoreFallsBackToThe100ArtworkURL() async {
        let transport = FakeTransport()
        transport.responder = { _ in
            .success(try! JSONSerialization.data(withJSONObject: [
                "resultCount": 1,
                "results": [["trackId": 400, "trackName": "Notion",
                             "artworkUrl100": "https://img.example/100x100bb.jpg"]]
            ]))
        }
        let result = await AppStoreIconClient(transport: transport).search(term: "notion", storefront: "us")
        guard case .success(let found) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(found.first?.artworkURL?.absoluteString, "https://img.example/512x512bb.jpg",
                       "只有 100 的字段时按 512 取，图标才不会糊")
    }

    /// 这一条是那处旧伤的正面反驳：读不懂曾经一路兜到空数组，
    /// 界面就指着一次解析失败说「输入名称后点搜索」。
    func testUnreadableSearchPayloadIsNotReportedAsNoResults() async {
        let transport = FakeTransport()
        transport.responder = { _ in .success(Data("<html><body>rate limited</body></html>".utf8)) }
        let result = await AppStoreIconClient(transport: transport).search(term: "netflix", storefront: "us")
        XCTAssertEqual(searchFailure(result), .badResponse)
        if case .success(let found) = result { XCTFail("空数组只能表示「真的搜了，0 条」：\(found)") }

        transport.responder = { _ in .success(Data("{\"resultCount\":0,\"results\":[]}".utf8)) }
        let empty = await AppStoreIconClient(transport: transport).search(term: "zzz", storefront: "us")
        XCTAssertEqual(searchFailure(empty), nil)
        if case .success(let found) = empty { XCTAssertTrue(found.isEmpty) }
    }

    func testAppStoreTransportFailureKeepsItsOwnIdentity() async {
        let transport = FakeTransport()
        transport.responder = { _ in .failure(.timedOut) }
        let result = await AppStoreIconClient(transport: transport).search(term: "netflix", storefront: "us")
        XCTAssertEqual(searchFailure(result), .timedOut)
    }

    // MARK: - 解码与裁剪

    func testDecodeStaysInsideThePixelBudget() {
        let image = IconImageProcessing.decode(pngData(200, 100), maxEdge: 64)
        XCTAssertNotNil(image)
        XCTAssertEqual(max(image?.size.width ?? 0, image?.size.height ?? 0), 64, accuracy: 1,
                       "解码就按最终尺寸来，不把原图整张带进内存")
    }

    func testDecodeRejectsBytesThatAreNotAnImage() {
        XCTAssertNil(IconImageProcessing.decode(Data("<html>nope</html>".utf8)))
        XCTAssertNil(IconImageProcessing.decode(Data()))
    }

    func testSquareCropTakesTheMiddleBand() {
        let cropped = IconImageProcessing.squareCrop(UIImage(cgImage: cgImage(width: 200, height: 100)))
        XCTAssertEqual(cropped.size.width, cropped.size.height, accuracy: 1)
        XCTAssertEqual(cropped.size.height, 100, accuracy: 1)
    }

    func testSquareCropLeavesASquareAlone() {
        let square = UIImage(cgImage: cgImage(width: 64, height: 64))
        XCTAssertEqual(IconImageProcessing.squareCrop(square).size, square.size)
    }

    // MARK: - 弹窗状态机：搜索

    /// 连打三个字只该问一次 —— 每敲一个字符都跑一趟网络，
    /// 结果是最后一趟被前几趟盖掉。
    func testTypingCollapsesIntoASingleRequest() async throws {
        let transport = FakeTransport()
        transport.responder = { _ in .success(appJSON([(380, "爱奇艺", art(380))])) }
        let model = makeModel(debounce: .milliseconds(120), transport: transport)

        model.setTerm("爱")
        model.setTerm("爱奇")
        model.setTerm("爱奇艺")
        try await waitUntil("去抖之后发出一次查询") { transport.hits.count == 1 }
        XCTAssertTrue(transport.hits.allSatisfy { $0.absoluteString.contains("爱奇艺") ||
            $0.absoluteString.contains("%E7%88%B1") }, "发的应该是最后一次输入")
        try await waitUntil("结果落屏") { model.phase == .loaded }
        XCTAssertEqual(transport.hits.count, 1, "去抖坏了就会看到三趟")
    }

    func testSubmitIgnoresTheDebounceWindow() async throws {
        let transport = FakeTransport()
        transport.responder = { _ in .success(appJSON([(1, "A", art(1))])) }
        let model = makeModel(debounce: .seconds(2), transport: transport)

        model.setTerm("netflix")
        model.submit()
        try await waitUntil("回车点放大镜都是立刻查", timeout: 0.5) { transport.hits.count == 1 }
        try await waitUntil("结果落屏") { model.phase == .loaded }
    }

    func testStorefrontChangeRequeriesWithoutWaiting() async throws {
        let transport = FakeTransport()
        transport.responder = { _ in .success(appJSON([(1, "A", art(1))])) }
        let model = makeModel(debounce: .seconds(2), transport: transport)

        model.setTerm("netflix")
        model.setStorefront("us")
        try await waitUntil("换店面马上换条件重查", timeout: 0.5) { transport.hits.count == 1 }
        XCTAssertTrue(queryItems(transport.hits[0]).contains(item("country", "us")))
        try await waitUntil("并且没让上一个去抖任务插进来") { model.phase == .loaded }
        XCTAssertEqual(transport.hits.count, 1)
    }

    /// 任务书原话：后发出的查询结果不能覆盖最新查询。
    func testSlowFirstQueryCannotOverwriteTheLatestOne() async throws {
        let transport = FakeTransport()
        transport.responder = { url in
            .success(url.absoluteString.contains("term=slow")
                     ? appJSON([(1, "慢的", art(1))])
                     : appJSON([(2, "快的", art(2))]))
        }
        transport.block(when: { $0.absoluteString.contains("term=slow") })
        let model = makeModel(debounce: .milliseconds(0), transport: transport)

        model.setTerm("slow")
        try await waitUntil("第一条查询发出去") { transport.hits.count == 1 }
        model.setTerm("fast")
        try await waitUntil("第二条后发先至") { model.phase == .loaded }
        XCTAssertEqual(model.results.map(\.id), [2])

        transport.unblock()
        try await waitUntil("第一条也回来了") { transport.resolved.count == 2 }
        XCTAssertEqual(model.results.map(\.id), [2], "先发但后到的那一趟，不许往屏上写")
    }

    func testSearchingKeepsThePreviousResultsOnScreen() async throws {
        let transport = FakeTransport()
        transport.responder = { url in
            .success(url.absoluteString.contains("term=a")
                     ? appJSON([(1, "A", art(1)), (2, "B", art(2))])
                     : appJSON([(3, "C", art(3))]))
        }
        transport.block(when: { $0.absoluteString.contains("term=b") })
        let model = makeModel(debounce: .milliseconds(0), transport: transport)

        model.setTerm("a")
        try await waitUntil("第一批落屏") { model.phase == .loaded }
        model.setTerm("b")
        try await waitUntil("第二批在查") { model.phase == .searching }
        XCTAssertEqual(model.results.map(\.id), [1, 2], "加载状态不该让旧内容突然消失")
        transport.unblock()
        try await waitUntil("第二批落屏") { model.phase == .loaded }
        XCTAssertEqual(model.results.map(\.id), [3])
    }

    func testEmptyResultAndFailureAreDifferentAnswers() async throws {
        let transport = FakeTransport()
        let model = makeModel(debounce: .milliseconds(0), transport: transport)

        transport.responder = { _ in .success(appJSON([])) }
        model.setTerm("zzzzz")
        try await waitUntil("真的搜了，0 条") { model.phase == .empty }

        transport.responder = { _ in .failure(.offline) }
        model.setTerm("netflix")
        try await waitUntil("没网") { model.phase == .failed(.offline) }
        XCTAssertNotEqual(model.phase, .empty, "「换个说法」和「检查网络」不能是同一句")
    }

    func testFailureKeepsTheTermAndRetryRefiresTheSameQuery() async throws {
        let transport = FakeTransport()
        transport.responder = { _ in .failure(.offline) }
        let model = makeModel(debounce: .seconds(2), transport: transport)

        model.setTerm("爱奇艺")
        model.submit()
        try await waitUntil("失败") { model.phase == .failed(.offline) }
        XCTAssertEqual(model.term, "爱奇艺", "失败了不能把人家输入清掉")

        transport.responder = { _ in .success(appJSON([(380, "爱奇艺", art(380))])) }
        model.submit()   // 界面上「重试」那颗按钮调的就是这个方法
        try await waitUntil("重试拿到结果") { model.phase == .loaded }
        XCTAssertEqual(model.results.map(\.id), [380])
        XCTAssertEqual(transport.hits.count, 2)
    }

    func testCancelledSearchIsNotShownAsAFailure() async throws {
        let transport = FakeTransport()
        transport.responder = { _ in .failure(.cancelled) }
        let model = makeModel(debounce: .milliseconds(0), transport: transport)
        model.setTerm("netflix")
        try await waitUntil("查询回来过") { transport.resolved.count == 1 }
        if case .failed = model.phase {
            XCTFail("自己撤掉的那一趟，不该红着脸说「服务返回的内容读不懂」：\(model.phase)")
        }
    }

    func testClearingTheTermResetsThePane() async throws {
        let transport = FakeTransport()
        transport.responder = { _ in .success(appJSON([(1, "A", art(1))])) }
        let model = makeModel(debounce: .milliseconds(0), transport: transport)

        model.setTerm("a")
        try await waitUntil("有结果") { model.phase == .loaded }
        model.select(model.results[0])
        model.setTerm("")
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.selectedAppID, "输入都空了还挂着选中，就是留着个没人问的答案")
    }

    func testSelectionDropsWhenTheAppLeavesTheResultList() async throws {
        let transport = FakeTransport()
        transport.responder = { url in
            .success(url.absoluteString.contains("term=a") ? appJSON([(1, "A", art(1))])
                                                            : appJSON([(2, "B", art(2))]))
        }
        let model = makeModel(debounce: .milliseconds(0), transport: transport)

        model.setTerm("a")
        try await waitUntil("第一批") { model.phase == .loaded }
        model.select(model.results[0])
        XCTAssertEqual(model.selectedAppID, 1)
        model.setTerm("b")
        try await waitUntil("第二批") { model.results.map(\.id) == [2] }
        XCTAssertNil(model.selectedAppID, "选中的那个已经不在列表里了，不能再当选中")
    }

    func testRepeatingAQueryIsServedFromCacheWithoutNetworking() async throws {
        let transport = FakeTransport()
        transport.responder = { url in
            .success(url.absoluteString.contains("term=a") ? appJSON([(1, "A", art(1))])
                                                            : appJSON([(2, "B", art(2))]))
        }
        let model = makeModel(debounce: .seconds(2), transport: transport)

        model.setTerm("a")
        model.submit()
        try await waitUntil("第一次查 a") { model.results.map(\.id) == [1] }
        model.setTerm("b")
        model.submit()
        try await waitUntil("查 b") { model.results.map(\.id) == [2] }

        transport.responder = { url in
            XCTFail("同一个店面同一个词，第二次不该再跑到网上：\(url)")
            return .failure(.offline)
        }
        model.setTerm("a")
        model.submit()
        try await waitUntil("回到 a 直接从缓存落屏") { model.results.map(\.id) == [1] }
        XCTAssertEqual(model.phase, .loaded)
    }

    // MARK: - 弹窗状态机：行上的图标

    func testRowIconLandsInPlaceAndIsCachedUnderAStableName() async throws {
        let store = makeStore()
        let transport = FakeTransport()
        transport.responder = { url in
            url.host == "itunes.apple.com" ? .success(appJSON([(380, "爱奇艺", art(380))]))
                                           : .success(pngData(512, 512))
        }
        let model = makeModel(debounce: .milliseconds(0), transport: transport, store: store)
        model.setTerm("爱奇艺")
        try await waitUntil("有结果") { model.phase == .loaded }
        let row = model.results[0]

        XCTAssertTrue(model.needsIconLoad(for: row))
        await model.loadIcon(for: row)
        XCTAssertNotNil(model.image(for: row), "下载完得马上刷这一行，不能等人离开页面再回来")
        XCTAssertEqual(store.fileNames, ["appstore-380.png"])

        // 换个模型（等于关窗再开）同一行：图从盘上来，一趟网络都不发。
        let second = makeModel(debounce: .seconds(2), transport: transport, store: store)
        await second.loadIcon(for: row)
        XCTAssertNotNil(second.image(for: row))
        XCTAssertEqual(transport.hits.count, 2, "1 次搜索 + 1 次图标，缓存命中不该再加")
    }

    func testSameRowNeverFiresTwoConcurrentDownloads() async throws {
        let transport = FakeTransport()
        transport.responder = { url in
            url.host == "itunes.apple.com" ? .success(appJSON([(380, "爱奇艺", art(380))]))
                                           : .success(pngData(128, 128))
        }
        transport.block(when: { $0.path.hasSuffix("art-380.png") })
        let model = makeModel(debounce: .milliseconds(0), transport: transport)
        model.setTerm("爱奇艺")
        try await waitUntil("有结果") { model.phase == .loaded }
        let row = model.results[0]

        let first = Task { await model.loadIcon(for: row) }
        try await waitUntil("第一条发出去") { transport.hits.count == 2 }   // 1 搜索 + 1 图标
        let second = Task { await model.loadIcon(for: row) }
        transport.unblock()
        await first.value
        await second.value
        XCTAssertEqual(transport.hits.filter { $0.path.hasSuffix("art-380.png") }.count, 1,
                       "行上被问两次就并发下两趟，是白下")
        XCTAssertNotNil(model.image(for: row))
    }

    func testIconFailureGetsItsOwnRetryAndDoesNotSpamItself() async throws {
        let transport = FakeTransport()
        transport.responder = { url in
            url.host == "itunes.apple.com" ? .success(appJSON([(380, "爱奇艺", art(380))]))
                                           : .failure(.offline)
        }
        let model = makeModel(debounce: .milliseconds(0), transport: transport)
        model.setTerm("爱奇艺")
        try await waitUntil("有结果") { model.phase == .loaded }
        let row = model.results[0]

        await model.loadIcon(for: row)
        XCTAssertNil(model.image(for: row))
        XCTAssertEqual(model.iconFailures, [380])
        XCTAssertFalse(model.needsIconLoad(for: row),
                       "失败了还一直要重下，就是在滚动里反复撞墙")

        transport.responder = { url in
            url.host == "itunes.apple.com" ? .success(appJSON([(380, "爱奇艺", art(380))]))
                                           : .success(pngData(128, 128))
        }
        await model.retryIcon(row)
        XCTAssertNotNil(model.image(for: row), "行上那颗重试是真能下的，不是个装饰")
        XCTAssertTrue(model.iconFailures.isEmpty)
    }

    func testCancelledIconDownloadLeavesNoFailureBehind() async throws {
        let transport = FakeTransport()
        transport.responder = { url in
            url.host == "itunes.apple.com" ? .success(appJSON([(380, "爱奇艺", art(380))]))
                                           : .failure(.cancelled)
        }
        let model = makeModel(debounce: .milliseconds(0), transport: transport)
        model.setTerm("爱奇艺")
        try await waitUntil("有结果") { model.phase == .loaded }
        await model.loadIcon(for: model.results[0])
        XCTAssertTrue(model.iconFailures.isEmpty, "人已经不在这行了，别留个红色的重试")
    }

    // MARK: - 弹窗状态机：网址与相册

    func testWebPreviewIsDroppedTheMomentTheAddressChanges() async throws {
        let transport = FakeTransport()
        transport.responder = { _ in .success(pngData(120, 120)) }
        let model = makeModel(transport: transport)

        model.setWebInput("setapp.com")
        model.fetchWebIcon()
        try await waitUntil("图拿到了") { model.webPhase == .done }
        XCTAssertNotNil(model.webImage)

        model.setWebInput("other.com")
        XCTAssertNil(model.webImage, "换了网址还挂着上一张的「已获取」，就是拿旧答案冒充新结果")
        XCTAssertEqual(model.webPhase, .idle)
    }

    func testWebBlankAndBadHostAreRefusedWithoutNetworking() async throws {
        let transport = FakeTransport()
        let model = makeModel(transport: transport)

        model.fetchWebIcon()
        try await waitUntil("空的先说空") { model.webPhase == .failed(.blank) }
        XCTAssertTrue(transport.hits.isEmpty)

        model.setWebInput("icloud")
        model.fetchWebIcon()
        try await waitUntil("少了后缀当场说") { model.webPhase == .failed(.badHost) }
        XCTAssertTrue(transport.hits.isEmpty)
    }

    func testWebOutageSaysOutageNotNotFound() async throws {
        let transport = FakeTransport()
        transport.responder = { _ in .failure(.timedOut) }
        let model = makeModel(transport: transport)
        model.setWebInput("setapp.com")
        model.fetchWebIcon()
        try await waitUntil("超时") { model.webPhase == .failed(.timedOut) }
        XCTAssertNil(model.webImage)
    }

    func testPhotoSelectionShowsLoadingImmediatelyAndClearsOnDeselect() {
        let model = makeModel(transport: FakeTransport())

        model.loadPhoto(nil)
        XCTAssertEqual(model.photoPhase, .empty)
        XCTAssertNil(model.photoImage)

        model.loadPhoto(PhotosPickerItem(itemIdentifier: "no-such-item"))
        XCTAssertEqual(model.photoPhase, .loading, "选完先给加载态，别让人对着一张空框怀疑没点上")
        XCTAssertNil(model.photoImage)

        model.loadPhoto(nil)
        XCTAssertEqual(model.photoPhase, .empty)
        XCTAssertNil(model.photoImage)
    }

    // MARK: - 收尾：落盘与回收

    func testFinishingTwiceWritesOneFile() async throws {
        let store = makeStore()
        let transport = FakeTransport()
        transport.responder = { _ in .success(pngData(120, 120)) }
        let model = makeModel(transport: transport, store: store)

        model.setWebInput("setapp.com")
        model.fetchWebIcon()
        try await waitUntil("图拿到了") { model.webPhase == .done }
        let first = model.finish(source: .web, currentImageFile: nil)
        XCTAssertNotNil(first)
        XCTAssertEqual(model.finish(source: .web, currentImageFile: first), first,
                       "点两次完成落两份文件，盘上就多一张没人要的图")
        XCTAssertEqual(store.fileNames.count, 1)
    }

    func testACommittedFileIsNotReapedByCancel() async throws {
        let store = makeStore()
        let transport = FakeTransport()
        transport.responder = { _ in .success(pngData(120, 120)) }
        let model = makeModel(transport: transport, store: store)

        model.setWebInput("setapp.com")
        model.fetchWebIcon()
        try await waitUntil("图拿到了") { model.webPhase == .done }
        guard let chosen = model.finish(source: .web, currentImageFile: nil) else {
            return XCTFail("拿到图就该给出文件名")
        }
        model.abandon(currentImageFile: chosen)
        XCTAssertEqual(store.fileNames, [chosen], "关窗时不能把表单正在用的那张一起收走")
    }

    func testSupersededWebIconIsReapedAndRenamed() async throws {
        let store = makeStore()
        let transport = FakeTransport()
        transport.responder = { url in
            .success(pngData(url.path.contains("180x180") ? 180 : 64,
                             url.path.contains("180x180") ? 180 : 64))
        }
        let model = makeModel(transport: transport, store: store)

        model.setWebInput("setapp.com")
        model.fetchWebIcon()
        try await waitUntil("第一张") { model.webPhase == .done }
        guard let first = model.finish(source: .web, currentImageFile: nil) else {
            return XCTFail("第一张该落成文件")
        }

        model.setWebInput("other.com")
        model.fetchWebIcon()
        try await waitUntil("第二张") { model.webPhase == .done }
        guard let second = model.finish(source: .web, currentImageFile: nil) else {
            return XCTFail("换网址之后新取的那张不能沿用旧文件")
        }
        XCTAssertNotEqual(first, second, "文件名跟着图走，否则表单收到的名字跟屏上预览的不是同一张")
        XCTAssertEqual(store.fileNames, [second], "这一趟被换掉的那张，关窗前要收干净")
    }

    func testAbandoningReapsEverythingFromThisSession() async throws {
        let store = makeStore()
        let transport = FakeTransport()
        transport.responder = { _ in .success(pngData(120, 120)) }
        let model = makeModel(transport: transport, store: store)

        model.setWebInput("setapp.com")
        model.fetchWebIcon()
        try await waitUntil("图拿到了") { model.webPhase == .done }
        XCTAssertNotNil(model.finish(source: .web, currentImageFile: nil))
        XCTAssertEqual(store.fileNames.count, 1)
        model.abandon(currentImageFile: nil)
        XCTAssertTrue(store.fileNames.isEmpty, "取消了这一趟，这一趟白写的文件不该留在盘上")
    }

    func testAppStoreIconCacheSurvivesAbandon() async throws {
        let store = makeStore()
        let transport = FakeTransport()
        transport.responder = { url in
            url.host == "itunes.apple.com" ? .success(appJSON([(380, "爱奇艺", art(380))]))
                                           : .success(pngData(128, 128))
        }
        let model = makeModel(debounce: .milliseconds(0), transport: transport, store: store)
        model.setTerm("爱奇艺")
        try await waitUntil("有结果") { model.phase == .loaded }
        await model.loadIcon(for: model.results[0])
        XCTAssertEqual(store.fileNames, ["appstore-380.png"])

        model.abandon(currentImageFile: nil)
        XCTAssertEqual(store.fileNames, ["appstore-380.png"],
                       "按 trackId 复用的缓存是下次搜索的加速，不是本次的垃圾")
    }

    func testFinishWithAppStoreSelectedNeedsTheIconAlreadyThere() async throws {
        let store = makeStore()
        let transport = FakeTransport()
        transport.responder = { url in
            url.host == "itunes.apple.com" ? .success(appJSON([(380, "爱奇艺", art(380))]))
                                           : .failure(.offline)
        }
        let model = makeModel(debounce: .milliseconds(0), transport: transport, store: store)
        model.setTerm("爱奇艺")
        try await waitUntil("有结果") { model.phase == .loaded }
        let row = model.results[0]

        model.select(row)
        XCTAssertNil(model.finish(source: .appStore, currentImageFile: nil),
                     "图标还没落地就点完成，要给「还在下载」而不是关页")

        transport.responder = { url in
            url.host == "itunes.apple.com" ? .success(appJSON([(380, "爱奇艺", art(380))]))
                                           : .success(pngData(128, 128))
        }
        await model.loadIcon(for: row)
        XCTAssertEqual(model.finish(source: .appStore, currentImageFile: nil), "appstore-380.png")
    }

    // MARK: - 图标库与颜色行：摆出来的必须都按得动

    func testLibraryNeverOffersASymbolThatDrawsNothing() {
        XCTAssertFalse(IconLibrary.availableGroups.isEmpty,
                       "整页筛空了就是图标库这一栏没了")
        var ids: [String] = []
        for group in IconLibrary.availableGroups {
            XCTAssertFalse(group.symbols.isEmpty, "「\(group.title)」被筛空了却还挂在页签上")
            XCTAssertFalse(ids.contains(group.id), "页签 id 重复：\(group.id)")
            ids.append(group.id)
            for symbol in group.symbols {
                XCTAssertNotNil(UIImage(systemName: symbol),
                                "「\(group.title)」里的 \(symbol) 这台系统画不出来，格子上是个空方块")
            }
        }
    }

    func testLibraryDropsOnlySymbolsTheSystemCannotDraw() {
        let offered = Set(IconLibrary.availableGroups.flatMap(\.symbols))
        let declared = Set(IconLibrary.groups.flatMap(\.symbols))
        XCTAssertEqual(offered, declared.filter { UIImage(systemName: $0) != nil },
                       "筛掉的东西必须真的画不出来，多筛一个就少一个能用的图标")
        for missing in declared.subtracting(offered) {
            XCTAssertNil(UIImage(systemName: missing), "\(missing) 明明画得出来，却被筛掉了")
        }
    }

    func testLibraryGroupsKeepTheirDeclaredOrderAndTitles() {
        XCTAssertEqual(IconLibrary.availableGroups.map(\.id),
                       IconLibrary.groups.filter { group in
                           group.symbols.contains { UIImage(systemName: $0) != nil }
                       }.map(\.id),
                       "分组顺序是页签条的顺序，筛完不能打乱")
        for group in IconLibrary.availableGroups {
            XCTAssertEqual(group.title,
                           IconLibrary.groups.first { $0.id == group.id }?.title)
        }
    }

    func testEveryPaletteColorStaysTappableOnTheNarrowestScreen() {
        // 12 个色点排成一行是 540 点宽。这一页在 ScrollView 里，横向顶穿屏幕不是
        // 滚动，是把页签条和网格两头一起切掉 —— 边上那几列根本点不到。
        // 换成自适应网格后要确认：列数至少 1（否则整行空白），换行后的高度也不许把网格挤出屏幕。
        let usable = 320 - Palette.rowGutter * 2
        let perRow = Palette.dotsPerRow(usableWidth: usable)
        XCTAssertGreaterThanOrEqual(perRow, 1, "列数算成 0，颜色行会整个空掉")
        let rows = (Palette.colors.count + perRow - 1) / perRow
        let height = CGFloat(rows) * Palette.dotSide + CGFloat(rows - 1) * Palette.dotSpacing
        XCTAssertLessThanOrEqual(height, 160,
                                 "颜色行换到 \(rows) 排，已经高到会把图标网格顶出屏幕")
    }

    func testPaletteColorsAreAllDistinctAndParseable() {
        XCTAssertEqual(Set(Palette.colors).count, Palette.colors.count, "调色板里有重复的色值")
        for hex in Palette.colors {
            XCTAssertNotNil(Color(hex: hex), "色值 \(hex) 解析不出来，点上去是个透明圆")
        }
    }
}

// MARK: - 假件与素材

/// 只到「拿到一段字节」为止的假传输。命中记账 + 可卡门，
/// 让「谁先回」「回几次」这类顺序问题能在测试里演出来。
private final class FakeTransport: IconTransport, @unchecked Sendable {
    typealias Responder = @Sendable (URL) -> Result<Data, IconProblem>

    private let lock = NSLock()
    private var _hits: [URL] = []
    private var _resolved: [URL] = []
    private var _responder: Responder = { _ in .failure(.offline) }
    private var _blocked: (@Sendable (URL) -> Bool)?
    private var _latch: Latch?

    var hits: [URL] { lock.lock(); defer { lock.unlock() }; return _hits }
    var resolved: [URL] { lock.lock(); defer { lock.unlock() }; return _resolved }

    var responder: Responder {
        get { lock.lock(); defer { lock.unlock() }; return _responder }
        set { lock.lock(); _responder = newValue; lock.unlock() }
    }

    func block(when predicate: @escaping @Sendable (URL) -> Bool) {
        lock.lock(); _blocked = predicate; _latch = Latch(); lock.unlock()
    }

    func unblock() {
        lock.lock(); let latch = _latch; lock.unlock()
        latch?.release()
    }

    func data(from url: URL) async -> Result<Data, IconProblem> {
        // NSLock 不能在 async 上下文里直接按，加锁都收在同步方法里。
        let plan = plan(for: url)
        if plan.shouldBlock, let latch = plan.latch { await latch.wait() }
        let result = plan.responder(url)
        markResolved(url)
        return result
    }

    private struct Plan {
        let responder: Responder
        let shouldBlock: Bool
        let latch: Latch?
    }

    private func plan(for url: URL) -> Plan {
        lock.lock(); defer { lock.unlock() }
        _hits.append(url)
        return Plan(responder: _responder, shouldBlock: _blocked?(url) == true, latch: _latch)
    }

    private func markResolved(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        _resolved.append(url)
    }
}

/// 一次性的门：卡住的请求放出去之后不再拦。
/// 用锁而不是 actor —— actor 的方法里没法把 continuation 存进自己的属性。
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            enqueue(continuation)
        }
    }

    private var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return released
    }

    /// 挂门和放门之间可能刚好开了，所以入队时必须再看一眼。
    private func enqueue(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        if released { continuation.resume(); return }
        waiters.append(continuation)
    }

    func release() {
        lock.lock()
        guard !released else { lock.unlock(); return }
        released = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

private func art(_ id: Int) -> String { "https://img.example/art-\(id).png" }

private func appJSON(_ entries: [(id: Int, name: String, artwork: String?)]) -> Data {
    let results: [[String: Any]] = entries.map { entry in
        var dict: [String: Any] = ["trackId": entry.id, "trackName": entry.name]
        if let artwork = entry.artwork { dict["artworkUrl512"] = artwork }
        return dict
    }
    return try! JSONSerialization.data(withJSONObject: ["resultCount": results.count, "results": results])
}

private func cgImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

private func pngData(_ width: Int, _ height: Int) -> Data {
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, cgImage(width: width, height: height), nil)
    CGImageDestinationFinalize(destination)
    return out as Data
}
