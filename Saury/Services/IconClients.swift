import Foundation
import UIKit

/// App Store 图标搜索。走公开的 iTunes Search API，按店面国家过滤，
/// 拿到 artworkUrl512 直接下载落盘。没有 key、没有 SDK，失败就静默回到空结果。
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

    func search(term: String, storefront: String) async throws -> [AppResult] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "country", value: storefront)
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let results = (object?["results"] as? [[String: Any]]) ?? []
        return results.compactMap(AppResult.init(json:))
    }

    func downloadImage(from url: URL) async -> UIImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: data)
    }
}

/// 网址取图标：先试 /apple-touch-icon.png，再退到 Google 的 favicon 服务。
struct WebIconClient {
    func fetchIcon(for input: String) async -> UIImage? {
        let host = normalizeHost(input)
        guard !host.isEmpty else { return nil }

        if let direct = try? await fetchDirectIcon(host: host) {
            return direct
        }
        let fallback = "https://www.google.com/s2/favicons?domain=\(host)&sz=256"
        guard let url = URL(string: fallback) else { return nil }
        return try? await download(url: url)
    }

    private func fetchDirectIcon(host: String) async throws -> UIImage? {
        for path in ["/apple-touch-icon.png", "/apple-touch-icon-precomposed.png", "/favicon.ico", "/favicon.png"] {
            guard let url = URL(string: "https://\(host)\(path)") else { continue }
            if let image = try? await download(url: url), image.size.width >= 64 {
                return image
            }
        }
        return nil
    }

    private func download(url: URL) async throws -> UIImage? {
        let (data, _) = try await URLSession.shared.data(from: url)
        return UIImage(data: data)
    }

    /// 输入可能是 iCloud.com、icloud.com/、带 https 前缀的一整串，都归一成主机名。
    func normalizeHost(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("http://") || text.hasPrefix("https://") {
            text = String(text.dropFirst(text.hasPrefix("https://") ? 8 : 7))
        }
        if let slash = text.firstIndex(of: "/") {
            text = String(text[..<slash])
        }
        return text.lowercased()
    }
}
