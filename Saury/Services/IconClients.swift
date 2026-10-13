import Foundation
import ImageIO
import UIKit

/// 取一张图标能出问题的几种方式，分开列。
///
/// 「这个站点没有图标」和「设备没网」在用户那儿是两个动作 —— 一个换个网址，
/// 一个去看连接。合成一句「没找到」就哪个都不指向（任务书 §7.2 要求
/// 无结果、网络错误、下载错误各有各的反馈）。
enum IconProblem: Error, Equatable {
    case blank
    case badHost
    case offline
    case timedOut
    case cancelled
    case tooBig
    case notAnImage
    case unreadableItem
    case noIcon
    case badResponse

    var message: String {
        switch self {
        case .blank: return "先填点内容"
        case .badHost: return "这不像个网址，填完整域名试试（如 setapp.com）"
        case .offline: return "连不上那个地址，检查一下网络再试"
        case .timedOut: return "等得有点久，先放弃了。可以再试一次"
        case .cancelled: return "这次已经不要了"
        case .tooBig: return "这张图太大，换个小的"
        case .notAnImage: return "下载回来的不是图片"
        case .unreadableItem: return "这张图片读不出来，换一张试试"
        case .noIcon: return "这个站点没有现成的图标"
        case .badResponse: return "服务返回的内容读不懂"
        }
    }
}

/// 只到「拿到一段字节」为止。换一个假的实现，上面每一种失败都能在测试里演一遍 ——
/// 真网络不进单元测试。
protocol IconTransport {
    func data(from url: URL) async -> Result<Data, IconProblem>
}

/// 真到网上的那个实现。
///
/// 用 `download(for:)` 而不是 `data(for:)`：后者会先把整个响应体读进内存才让人看一眼，
/// 「最多 4 MB」就成了事后追认。下载到临时文件后先量大小再进内存，
/// 内存这条线就是硬的。
struct HTTPIconTransport: IconTransport {
    static let shared = HTTPIconTransport()

    /// 图标不该有这个尺寸。超了就是拿错了东西，或者对面在乱来。
    static let byteLimit = 4 * 1024 * 1024
    static let requestTimeout: TimeInterval = 8

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout * 3
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["Accept": "image/*,*/*;q=0.8"]
        return URLSession(configuration: config)
    }()

    func data(from url: URL) async -> Result<Data, IconProblem> {
        do {
            let (file, response) = try await Self.session.download(from: url)
            defer { try? FileManager.default.removeItem(at: file) }
            switch Self.verdict(of: response) {
            case .failure(let problem): return .failure(problem)
            case .success: break
            }
            let bytes = Self.size(of: file)
            guard bytes <= Self.byteLimit else { return .failure(.tooBig) }
            guard bytes > 0 else { return .failure(.noIcon) }
            guard let data = try? Data(contentsOf: file) else { return .failure(.badResponse) }
            return .success(data)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let error as URLError {
            return .failure(Self.problem(for: error.code))
        } catch {
            return .failure(.badResponse)
        }
    }

    /// 状态码在收字节之前就能否掉一批。这里**不看 Content-Type**：
    /// iTunes 搜索接口给的是一串 JSON，头里却写着 `text/javascript` —— 按类型白名单放行
    /// 会把这条正常结果当成「回来的不是图片」挡掉，是 `-saury-icon` 探针真跑线上才照出来的。
    /// 类型交给各自的解析器判断：JSON 读不通就是 `badResponse`，图解不出来就是 `notAnImage`，
    /// 说出来的那句才对着真正在做的这件事。
    static func verdict(of response: URLResponse) -> Result<Void, IconProblem> {
        guard let http = response as? HTTPURLResponse else { return .success(()) }
        guard (200...299).contains(http.statusCode) else {
            return .failure(http.statusCode == 404 ? .noIcon : .badResponse)
        }
        return .success(())
    }

    private static func size(of file: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        return (attributes?[.size] as? Int) ?? 0
    }

    /// URLError 的码翻成用户听得懂的那句话。同一族（找不到主机、连接断了、
    /// TLS 失败）都归到「连不上」，因为它们要用户做的是同一件事：看网络。
    static func problem(for code: URLError.Code) -> IconProblem {
        switch code {
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        case .badURL: return .badHost
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dataNotAllowed, .dnsLookupFailed, .secureConnectionFailed, .resourceUnavailable:
            return .offline
        default: return .badResponse
        }
    }
}

/// 解码与裁剪。落盘之前先按最终尺寸处理，别把 12MP 的原图整张带进内存 ——
/// 列表滚动就先卡一轮（任务书 §9.5）。
enum IconImageProcessing {
    /// 图标最终存 512 边长，解码也按这个尺寸来。
    static let maxEdge: CGFloat = 512

    /// 按上限尺寸解码。ImageIO 走缩略图路径，不会先做一次全尺寸解码。
    static func decode(_ data: Data, maxEdge: CGFloat = maxEdge) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // 跟着 EXIF 方向转正
            kCGImageSourceThumbnailMaxPixelSize: maxEdge
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    /// 中心取方。渲染端一直是 `scaledToFill` + 圆角方框，
    /// 落盘前裁成同样的方形，「会自动裁成方形图标」才不是空话。
    static func squareCrop(_ image: UIImage) -> UIImage {
        let side = min(image.size.width, image.size.height)
        guard side > 0, side < max(image.size.width, image.size.height) else { return image }
        let canvas = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            image.draw(in: CGRect(
                x: (side - image.size.width) / 2,
                y: (side - image.size.height) / 2,
                width: image.size.width,
                height: image.size.height
            ))
        }
    }
}

/// App Store 图标搜索。走公开的 iTunes Search API，按店面国家过滤。
/// 没有 key、没有 SDK —— 但失败要能分出是哪种失败，不能一律当成没搜到。
struct AppStoreIconClient {
    struct AppResult: Identifiable, Hashable {
        let id: Int64
        let name: String
        let artworkURL: URL?

        init(id: Int64, name: String, artworkURL: URL?) {
            self.id = id
            self.name = name
            self.artworkURL = artworkURL
        }

        init?(json: [String: Any]) {
            guard let trackID = json["trackId"] as? Int64 else { return nil }
            self.id = trackID
            self.name = (json["trackName"] as? String) ?? ""
            let raw = (json["artworkUrl512"] as? String)
                ?? (json["artworkUrl100"] as? String)?.replacingOccurrences(of: "100x100", with: "512x512")
            self.artworkURL = raw.flatMap(URL.init(string:))
        }
    }

    /// 支持的 App Store 店面（与视频一致的那几个）。
    static let storefronts: [(code: String, name: String, flag: String)] = [
        ("cn", "中国", "🇨🇳"),
        ("us", "美国", "🇺🇸"),
        ("jp", "日本", "🇯🇵"),
        ("gb", "英国", "🇬🇧"),
        ("hk", "香港", "🇭🇰"),
        ("de", "德国", "🇩🇪"),
        ("kr", "韩国", "🇰🇷"),
        ("fr", "法国", "🇫🇷"),
        ("es", "西班牙", "🇪🇸")
    ]

    var transport: IconTransport = HTTPIconTransport.shared

    func search(term: String, storefront: String) async -> Result<[AppResult], IconProblem> {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "country", value: storefront)
        ]
        guard let url = components?.url else { return .failure(.badHost) }
        switch await transport.data(from: url) {
        case .failure(let problem):
            return .failure(problem)
        case .success(let data):
            // 读不懂就是读不懂。以前这里 `?? []` 一路兜到空数组，
            // 界面就指着一次解析失败说「输入名称后点搜索」。
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = object["results"] as? [[String: Any]] else {
                return .failure(.badResponse)
            }
            return .success(entries.compactMap(AppResult.init(json:)))
        }
    }

    func image(from url: URL) async -> Result<UIImage, IconProblem> {
        switch await transport.data(from: url) {
        case .failure(let problem):
            return .failure(problem)
        case .success(let data):
            guard let image = IconImageProcessing.decode(data) else { return .failure(.notAnImage) }
            return .success(image)
        }
    }
}

/// 网址取图标：按分辨率从高到低试站点自己那几个约定路径，最后才退到 Google 的
/// favicon 服务。每一步失败的原因都留着，好知道该跟用户说哪句。
struct WebIconClient {
    var transport: IconTransport = HTTPIconTransport.shared

    /// 站点自己提供的图标地址，从最清楚的到最糊的。
    static func candidates(forHost host: String) -> [URL] {
        let paths = [
            "/apple-touch-icon-180x180.png",
            "/apple-touch-icon-precomposed.png",
            "/apple-touch-icon.png",
            "/favicon.png",
            "/favicon.ico"
        ]
        var urls = paths.compactMap { URL(string: "https://\(host)\($0)") }
        urls += fallbackURLs(forHost: host)
        return urls
    }

    /// 兜底服务。host 走 `URLQueryItem` 拼，不能直接塞进字符串 ——
    /// 里面带 `&` 就能改掉这条请求要查的是什么。
    static func fallbackURLs(forHost host: String) -> [URL] {
        [256, 128, 64].compactMap { size in
            var components = URLComponents(string: "https://www.google.com/s2/favicons")
            components?.queryItems = [
                URLQueryItem(name: "domain", value: host),
                URLQueryItem(name: "sz", value: String(size))
            ]
            return components?.url
        }
    }

    func icon(for input: String) async -> Result<UIImage, IconProblem> {
        let host = Self.host(of: input)
        guard !host.isEmpty else { return .failure(.blank) }
        guard Self.looksLikeHost(host) else { return .failure(.badHost) }

        for url in Self.candidates(forHost: host) {
            switch await fetch(url) {
            case .success(let image):
                return .success(image)
            case .failure(let problem):
                // 只有「这条路径上没有图标」才值得换下一条试试。
                // 超时、太大、读不懂、用户已经换输入 —— 再问五条只是白等。
                guard problem == .noIcon || problem == .notAnImage else {
                    return .failure(problem)
                }
            }
        }
        // 八条路径都只剩「没有图」这一种说法，那就是真没有。
        return .failure(.noIcon)
    }

    /// 站点在、给了张图，但小得不像图标（很多站对未知路径回一张 1×1 的灰点）——
    /// 这种不算成功，接着往下试。
    private func fetch(_ url: URL) async -> Result<UIImage, IconProblem> {
        switch await transport.data(from: url) {
        case .failure(let problem):
            return .failure(problem)
        case .success(let data):
            guard let image = IconImageProcessing.decode(data) else { return .failure(.notAnImage) }
            guard max(image.size.width, image.size.height) >= 32 else { return .failure(.noIcon) }
            return .success(image)
        }
    }

    /// 输入可能是 `iCloud.com`、`icloud.com/`、`https://user@host:8443/x?y=1`。
    /// 只有主机部分能用来拼图标地址，其余一律丢掉。
    static func host(of input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if !text.contains("://") { text = "https://" + text }
        if let components = URLComponents(string: text), let host = components.host, !host.isEmpty {
            return host.lowercased()
        }
        // 整串 URL 解析不动时（比如混进了非法字符），退回最朴素的切法。
        // 先把 scheme 摘掉再找斜杠，不然 `http://ex ample.com/` 会切出个 `http`。
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        if let slash = text.firstIndex(of: "/") { text = String(text[text.startIndex..<slash]) }
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        if let colon = text.firstIndex(of: ":") { text = String(text[text.startIndex..<colon]) }
        return text.lowercased()
    }

    /// 像个主机名吗：有至少一个点、每段非空、只放得下字母数字和 `.-_`。
    /// `icloud` 这种少了后缀的，直接说清楚，而不是白跑五条请求再报「没找到」。
    static func looksLikeHost(_ host: String) -> Bool {
        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") }
    }
}
