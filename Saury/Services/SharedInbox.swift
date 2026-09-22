import UIKit

/// 分享扩展递图片过来的中转站（方案 §57）。
///
/// 扩展没法直接往数据库里写东西：它把图落到 App Group 的 `Pending/`，
/// 队列里只带文件名，主 App 取走之后即删 —— 识别成不成功都不该在共享目录里留第二份。
struct SharedInbox {
    static let shared = SharedInbox()

    /// nil 表示这台设备上打不开共享容器（没配 App Group 的构建）。
    let directory: URL?

    init(directory: URL? = SharedInbox.defaultDirectory()) {
        self.directory = directory
    }

    static func defaultDirectory(suiteName: String = ExternalInputStore.suiteName) -> URL? {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName) else { return nil }
        return base.appendingPathComponent("Pending", isDirectory: true)
    }

    var isAvailable: Bool { directory != nil }

    /// 放一张图，返回可以写进队列的那个文件名。
    func store(_ image: UIImage) -> String? {
        guard let directory, let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        let fileName = "\(UUID().uuidString).jpg"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
            return fileName
        } catch {
            SauryLog.saveFailed("接收分享图片", error)
            return nil
        }
    }

    func takeImage(_ fileName: String) -> UIImage? {
        guard let directory else { return nil }
        let url = directory.appendingPathComponent(fileName)
        let image = UIImage(contentsOfFile: url.path)
        delete(url)
        return image
    }

    private func delete(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            SauryLog.saveFailed("清理分享暂存图片", error)
        }
    }
}
