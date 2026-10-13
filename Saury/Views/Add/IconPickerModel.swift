import Foundation
import PhotosUI
import SwiftUI

/// 图标选择弹窗背后的状态机（任务书 §7.2）。
///
/// 去抖、取消、旧结果不许盖新结果、缓存命中这些判断全收在这里：
/// View 只负责把 phase 画出来，测试跑的是同一份代码。
@MainActor
final class IconPickerModel: ObservableObject {
    enum Source: Hashable { case library, appStore, web, photos }

    /// 四种反馈要分得开：没结果、还在查、查崩了、还没查。
    enum SearchPhase: Equatable {
        case idle
        case searching       // 旧结果留在屏上压暗，不闪空
        case loaded
        case empty           // 真的搜了，0 条 —— 换个说法
        case failed(IconProblem)   // 没网 / 超时 / 读不懂 —— 可以重试
    }

    enum WebPhase: Equatable { case idle, loading, done, failed(IconProblem) }
    enum PhotoPhase: Equatable { case empty, loading, done, failed(IconProblem) }

    // MARK: App Store

    @Published private(set) var term = ""
    @Published private(set) var storefront = AppStoreIconClient.storefronts[0].code
    @Published private(set) var phase: SearchPhase = .idle
    /// 查询进行中不清空：加载状态不该让旧内容突然消失。
    @Published private(set) var results: [AppStoreIconClient.AppResult] = []
    @Published private(set) var icons: [Int64: UIImage] = [:]
    @Published private(set) var iconFailures: Set<Int64> = []
    @Published private(set) var selectedAppID: Int64?

    // MARK: 网址

    @Published private(set) var webInput = ""
    @Published private(set) var webPhase: WebPhase = .idle
    @Published private(set) var webImage: UIImage?

    // MARK: 相册

    @Published private(set) var photoPhase: PhotoPhase = .empty
    @Published private(set) var photoImage: UIImage?

    private let store: IconImageStore
    private let appStore: AppStoreIconClient
    private let web: WebIconClient
    private let debounce: Duration

    private var searchTask: Task<Void, Never>?
    private var webTask: Task<Void, Never>?
    private var photoTask: Task<Void, Never>?
    /// 每次查询领一个号；回来的号不是最新的那个，就不许往屏上写。
    private var requestToken = 0
    private var resultCache: [String: [AppStoreIconClient.AppResult]] = [:]
    private var inflightIcons: Set<Int64> = []
    /// 这一趟弹窗写到盘上、最后没被选中的文件。关窗前要收掉。
    private var sessionFiles: Set<String> = []
    /// 同一张图被点两次「完成」不该落两份：按来源记着已经写下的文件名。
    private var storedBySource: [Source: String] = [:]

    init(store: IconImageStore = .shared,
         transport: IconTransport = HTTPIconTransport.shared,
         debounce: Duration = .milliseconds(350)) {
        self.store = store
        self.appStore = AppStoreIconClient(transport: transport)
        self.web = WebIconClient(transport: transport)
        self.debounce = debounce
    }

    // MARK: - App Store 查询

    func setTerm(_ text: String) {
        guard text != term else { return }
        term = text
        scheduleSearch(debounced: true)
    }

    /// 回车、点放大镜、以及「重试」都走这里：输入原样留着，只重发。
    func submit() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in await self?.performSearch() }
    }

    func setStorefront(_ code: String) {
        guard code != storefront else { return }
        storefront = code
        // 换店面等于换了一次查询条件：上一批结果已经不再是任何问题的答案。
        scheduleSearch(debounced: false)
    }

    func select(_ result: AppStoreIconClient.AppResult) {
        selectedAppID = result.id
    }

    /// 行上该显示的图：内存 → 磁盘缓存 → 什么都没有（调用方用 `.task` 去拉）。
    /// 这里只读不写，避免在 body 求值过程中改动 @Published。
    func image(for result: AppStoreIconClient.AppResult) -> UIImage? {
        if let hit = icons[result.id] { return hit }
        return store.image(for: Self.appStoreKey(result.id))
    }

    private func storedAppStoreImage(_ trackID: Int64) -> UIImage? {
        icons[trackID] ?? store.image(for: Self.appStoreKey(trackID))
    }

    func needsIconLoad(for result: AppStoreIconClient.AppResult) -> Bool {
        result.artworkURL != nil && image(for: result) == nil && !iconFailures.contains(result.id)
    }

    /// 拉某一行的缩略图。同一行重复问不会并发发两趟；取消时什么都不写。
    func loadIcon(for result: AppStoreIconClient.AppResult) async {
        let id = result.id
        if let already = storedAppStoreImage(id) {
            icons[id] = already
            return
        }
        guard !inflightIcons.contains(id), let url = result.artworkURL else { return }
        inflightIcons.insert(id)
        defer { inflightIcons.remove(id) }

        switch await appStore.image(from: url) {
        case .success(let image):
            guard !Task.isCancelled else { return }
            icons[id] = image
            iconFailures.remove(id)
            _ = store.store(image, named: Self.appStoreKey(id))
        case .failure(let problem):
            guard !Task.isCancelled, problem != .cancelled else { return }
            iconFailures.insert(id)
        }
    }

    func retryIcon(_ result: AppStoreIconClient.AppResult) async {
        iconFailures.remove(result.id)
        await loadIcon(for: result)
    }

    private func scheduleSearch(debounced: Bool) {
        searchTask?.cancel()
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            // 清空输入：把屏收回「还没查」，旧结果不该继续顶着答案的样子。
            requestToken += 1
            searchTask = nil
            results = []
            iconFailures = []
            selectedAppID = nil
            phase = .idle
            return
        }
        searchTask = Task { [weak self] in
            guard let self else { return }
            if debounced {
                do { try await Task.sleep(for: self.debounce) } catch { return }
            }
            await self.performSearch()
        }
    }

    private func performSearch() async {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        requestToken += 1
        let token = requestToken
        let key = "\(storefront)|\(trimmed)"

        if let cached = resultCache[key] {
            apply(cached)
            return
        }
        phase = .searching
        switch await appStore.search(term: trimmed, storefront: storefront) {
        case .success(let found):
            guard token == requestToken else { return }
            resultCache[key] = found
            apply(found)
        case .failure(let problem):
            guard token == requestToken, problem != .cancelled else { return }
            phase = .failed(problem)
        }
    }

    private func apply(_ found: [AppStoreIconClient.AppResult]) {
        results = found
        if let selected = selectedAppID, !found.contains(where: { $0.id == selected }) {
            selectedAppID = nil
        }
        phase = found.isEmpty ? .empty : .loaded
    }

    static func appStoreKey(_ trackID: Int64) -> String { "appstore-\(trackID).png" }

    // MARK: - 网址

    func setWebInput(_ text: String) {
        guard text != webInput else { return }
        webInput = text
        // 换了网址还挂着上一张的「已获取」，就是拿旧答案冒充新结果。
        // 落盘名也要一起放下：不然下一张图会沿用上一张的文件，
        // 表单收到的文件名跟屏上预览的根本不是同一张。
        webTask?.cancel()
        webTask = nil
        webImage = nil
        webPhase = .idle
        storedBySource[.web] = nil
    }

    func fetchWebIcon() {
        webTask?.cancel()
        let input = webInput
        webTask = Task { [weak self] in
            guard let self else { return }
            guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.webPhase = .failed(.blank)
                return
            }
            self.webPhase = .loading
            switch await self.web.icon(for: input) {
            case .success(let image):
                guard !Task.isCancelled else { return }
                self.webImage = image
                self.webPhase = .done
            case .failure(let problem):
                guard !Task.isCancelled, problem != .cancelled else { return }
                self.webImage = nil
                self.webPhase = .failed(problem)
            }
        }
    }

    // MARK: - 相册

    func loadPhoto(_ item: PhotosPickerItem?) {
        photoTask?.cancel()
        guard let item else {
            photoTask = nil
            photoImage = nil
            photoPhase = .empty
            return
        }
        photoImage = nil
        photoPhase = .loading
        photoTask = Task { [weak self] in
            guard let self else { return }
            switch await Self.readPhoto(item) {
            case .success(let image):
                guard !Task.isCancelled else { return }
                self.photoImage = image
                self.photoPhase = .done
            case .failure(let problem):
                guard !Task.isCancelled else { return }
                self.photoPhase = .failed(problem)
            }
        }
    }

    /// 读相册条目。原图整张进内存是列表滚动的隐患：先按 512 边长解码，
    /// 再中心取方 —— 落盘的方形文件跟渲染端 `scaledToFill` 看到的是同一块区域。
    private static func readPhoto(_ item: PhotosPickerItem) async -> Result<UIImage, IconProblem> {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            return .failure(.unreadableItem)
        }
        guard let image = IconImageProcessing.decode(data) else { return .failure(.notAnImage) }
        return .success(IconImageProcessing.squareCrop(image))
    }

    // MARK: - 收尾

    /// 「完成」：定下这一趟的图片，并收掉本次写了却没选中的文件。
    ///
    /// 只收自己这一趟造的。`appstore-<id>.png` 是按 trackId 复用的缓存，
    /// 别的订阅、下次搜索都还要用，不能顺手删。
    func finish(source: Source, currentImageFile: String?) -> String? {
        let winner: String?
        switch source {
        case .library:
            winner = nil
        case .appStore:
            winner = selectedAppID.flatMap { id in
                storedAppStoreImage(id) != nil ? Self.appStoreKey(id) : nil
            }
        case .web:
            winner = webImage.flatMap { stored($0, for: .web) }
        case .photos:
            winner = photoImage.flatMap { stored($0, for: .photos) }
        }
        reap(keeping: [winner, currentImageFile])
        return winner
    }

    /// 「取消」：这一趟白写的文件收干净，表单上原来那张不动。
    func abandon(currentImageFile: String?) {
        reap(keeping: [currentImageFile])
    }

    private func stored(_ image: UIImage, for source: Source) -> String? {
        if let existing = storedBySource[source], store.exists(existing) { return existing }
        guard let fileName = store.store(image) else { return nil }
        storedBySource[source] = fileName
        sessionFiles.insert(fileName)
        return fileName
    }

    private func reap(keeping survivors: [String?]) {
        let keep = Set(survivors.compactMap { $0 })
        for file in sessionFiles where !keep.contains(file) {
            store.delete(file)
        }
        sessionFiles = sessionFiles.intersection(keep)
    }
}
