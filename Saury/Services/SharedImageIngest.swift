import UIKit

/// 分享扩展递进来的图片：从 App Group 的暂存目录搬进图标库。
///
/// 为什么非要搬：暂存目录是扩展写的，主 App 只是读。留在原地意味着
/// 「这条订阅的图标」和「一个扩展随手扔下的临时文件」是同一个东西 ——
/// 备份清单、孤儿回收、彻底删除时的图标清理全都管不到它，因为那些都按
/// `IconImageStore` 里的文件名说话。搬进来之后它就是一张普通图标。
enum SharedImageIngest {
    enum Problem: LocalizedError, Equatable {
        /// 文件名带路径分隔符。队列里的名字来自别处写下的 JSON，不能当可信路径用。
        case unsafeFileName(String)
        /// 暂存目录压根没找到（App Group 没配、或扩展那次没写成功）。
        case stagingUnavailable(String)
        /// 文件在，但解不出图。
        case undecodable(String)
        /// 解出来了却写不进图标库（磁盘满、目录建不出来）。
        case storeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsafeFileName(let name):
                return "分享过来的图片文件名不安全（\(name)），这张图没能用。"
            case .stagingUnavailable(let name):
                return "找不到分享暂存的那张图片（\(name)）。共享目录没配上，或者扩展那次没写成功。"
            case .undecodable(let name):
                return "这张图片读不出来（\(name)），可能是格式不支持或者文件被截断了。"
            case .storeFailed(let name):
                return "图片已经读出来了，但存不进本机的图标库（\(name)）。"
            }
        }
    }

    /// 暂存目录。扩展那边写的是 `Pending/<uuid>.jpg`，
    /// 见 `SauryShare/ShareViewController.swift` 的 `writePendingImage`。
    static func stagedDirectory() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ExternalInputStore.suiteName)?
            .appendingPathComponent("Pending", isDirectory: true)
    }

    /// 搬进来，返回图标库里的文件名。搬完把暂存文件删掉 ——
    /// 队列这一条已经消费了，留着一张没人认领的图只会变成孤儿。
    static func promote(_ fileName: String,
                        from directory: URL? = stagedDirectory(),
                        store: IconImageStore = .shared) throws -> String {
        guard !fileName.isEmpty, fileName != ".", fileName != "..",
              !fileName.contains("/"), !fileName.contains("\\") else {
            throw Problem.unsafeFileName(fileName)
        }
        guard let directory else { throw Problem.stagingUnavailable(fileName) }
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            throw Problem.undecodable(fileName)
        }
        // `store` 自己会缩到 512 以内并返回文件名；返回 nil 就是写盘失败。
        guard let stored = store.store(image) else { throw Problem.storeFailed(fileName) }
        try? FileManager.default.removeItem(at: url)
        return stored
    }
}
