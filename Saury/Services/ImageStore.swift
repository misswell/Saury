import UIKit

/// 扫描原图的存放处（方案 §34）。
///
/// SwiftData 里只放文件名，不放图片本身：把大图塞进数据库，导出、迁移和列表读取
/// 全会跟着变慢。每张图落两份 —— 原图 + 缩略图，列表只解缩略图，点开才碰原图（方案 §74）。
struct ImageStore {
    static let shared = ImageStore()

    /// identifier 就是原图的文件名（`<uuid>.heic` 或 `<uuid>.jpg`，取决于系统能不能编 HEIC），
    /// 缩略图是同一个 uuid 换 `-thumb.jpg`。这样库里那一列本身就带足了定位信息，
    /// 不用再维护第二份「哪张图是什么格式」的账。
    struct Reference: Hashable {
        let fileName: String

        var thumbnailFileName: String {
            (fileName as NSString).deletingPathExtension + ".jpg"
        }
    }

    let root: URL

    init(root: URL = ImageStore.defaultRoot()) {
        self.root = root
    }

    static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("Saury/Images", isDirectory: true)
    }

    // MARK: - 写入

    /// 存一张图，返回可以写进 SwiftData 的那一列。
    /// 存不下就返回 nil：图不是这条记录的必要条件，不能因为写文件失败就不让人保存物品。
    func store(_ image: UIImage, id: UUID = UUID()) -> String? {
        guard let original = Self.originalData(for: image) else {
            SauryLog.saveFailed("编码扫描原图", ImageStoreError.encodingFailed)
            return nil
        }
        let reference = Reference(fileName: "\(id.uuidString).\(Self.fileExtension(of: original))")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try original.write(to: url(reference.fileName), options: .atomic)
            if let thumbnail = Self.thumbnailData(from: image) {
                try thumbnail.write(to: url(reference.thumbnailFileName), options: .atomic)
            }
            return reference.fileName
        } catch {
            SauryLog.saveFailed("写入扫描原图", error)
            return nil
        }
    }

    // MARK: - 读取

    func image(for identifier: String?) -> UIImage? {
        guard let identifier, !identifier.isEmpty else { return nil }
        return UIImage(contentsOfFile: url(identifier).path)
    }

    /// 列表用。解出来的缩略图会缓存一份，滚动时不必反复读盘。
    func thumbnail(for identifier: String?) -> UIImage? {
        guard let identifier, !identifier.isEmpty else { return nil }
        let thumbnailName = Reference(fileName: identifier).thumbnailFileName
        if let hit = Self.cache.object(forKey: thumbnailName as NSString) { return hit }
        guard let image = UIImage(contentsOfFile: url(thumbnailName).path) else {
            // 老数据可能只有原图没有缩略图，那就现压一张出来。
            guard let original = image(for: identifier) else { return nil }
            let scaled = Self.thumbnailImage(from: original)
            Self.cache.setObject(scaled, forKey: thumbnailName as NSString)
            return scaled
        }
        Self.cache.setObject(image, forKey: thumbnailName as NSString)
        return image
    }

    // MARK: - 删除

    func delete(_ identifier: String?) {
        guard let identifier, !identifier.isEmpty else { return }
        let manager = FileManager.default
        for name in [identifier, Reference(fileName: identifier).thumbnailFileName] {
            let url = url(name)
            guard manager.fileExists(atPath: url.path) else { continue }
            do { try manager.removeItem(at: url) } catch { SauryLog.saveFailed("删除图片 \(name)", error) }
        }
        Self.cache.removeObject(forKey: Reference(fileName: identifier).thumbnailFileName as NSString)
    }

    // MARK: - 内部

    enum ImageStoreError: LocalizedError {
        case encodingFailed

        var errorDescription: String? { "这张图片压不出可用的文件。" }
    }

    /// 缩略图会被列表反复解，缓存能省掉绝大部分重复读盘。
    private static let cache = NSCache<NSString, UIImage>()

    private static let thumbnailMaxEdge: CGFloat = 256

    private func url(_ fileName: String) -> URL { root.appendingPathComponent(fileName) }

    private static func fileExtension(of data: Data) -> String {
        // jpeg 从 ff d8 ff 开头，认不出这个就当是刚编出来的 HEIC。
        data.starts(with: [0xff, 0xd8, 0xff]) ? "jpg" : "heic"
    }

    private static func originalData(for image: UIImage) -> Data? {
        image.heicData() ?? image.jpegData(compressionQuality: 0.8)
    }

    private static func thumbnailData(from image: UIImage) -> Data? {
        thumbnailImage(from: image).jpegData(compressionQuality: 0.7)
    }

    private static func thumbnailImage(from image: UIImage) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let scale = min(1, thumbnailMaxEdge / max(size.width, size.height))
        guard scale < 1 else { return image }
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
