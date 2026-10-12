import SwiftUI

/// 订阅图标的统一渲染：符号、落盘图片、首字母块三种形态。
/// 列表、卡片、详情、日历、小票都用这一个视图，视觉才不会散。
struct SubscriptionIconView: View {
    let subscription: Subscription
    var size: CGFloat = 44
    /// 放在彩色渐变卡上时用白色反白形态，不然同色图标会糊进底色里。
    var onColorCard: Bool = false

    @EnvironmentObject private var preferences: SubPreferences

    var body: some View {
        iconBody
            .id(iconSignature)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .transition(.scale(scale: 0.82).combined(with: .opacity))
            .animation(Motion.pop, value: iconSignature)
    }

    /// 图标换了才重建：让「换图标」这件事在列表、卡片、详情页里都会弹一下。
    private var iconSignature: String {
        "\(subscription.iconImageFile ?? "")|\(subscription.iconSymbolName ?? "")|\(subscription.name.prefix(1))"
    }

    @ViewBuilder
    private var iconBody: some View {
        let tint = onColorCard ? Color.white : tintColor
        if let file = subscription.iconImageFile, let image = IconImageStore.shared.image(for: file) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else if let symbol = subscription.iconSymbolName, UIImage(systemName: symbol) != nil {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(onColorCard ? Color.white.opacity(0.25) : tint.opacity(0.22))
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(tint)
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(onColorCard ? Color.white.opacity(0.25) : tint.opacity(0.22))
                Text(String(subscription.name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
            }
        }
    }

    /// 图标的主色：手动挑过用那个；图片取主色；否则退主题色。
    var tintColor: Color {
        if let hex = subscription.iconColorHex, let color = Color(hex: hex) { return color }
        if let file = subscription.iconImageFile {
            return IconTint.dominantColor(of: IconImageStore.shared.image(for: file)) ?? Color(hex: preferences.accentHex) ?? .accentColor
        }
        return Color(hex: preferences.accentHex) ?? .accentColor
    }
}

/// 下载图标的落盘处。文件名即标识，缩略图场景不多（图标本来就小），只存一份。
final class IconImageStore {
    static let shared = IconImageStore()

    private let root: URL
    private let cache = NSCache<NSString, UIImage>()

    init(root: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        self.root = root ?? base.appendingPathComponent("Saury/Icons", isDirectory: true)
    }

    func image(for identifier: String?) -> UIImage? {
        guard let identifier, !identifier.isEmpty else { return nil }
        if let hit = cache.object(forKey: identifier as NSString) { return hit }
        let url = self.url(for: identifier)
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: identifier as NSString)
        return image
    }

    /// 存图并返回文件名；同 uuid 旧文件会被顶掉。
    func store(_ image: UIImage, id: UUID = UUID()) -> String? {
        storeScaled(image, fileName: "\(id.uuidString).png")
    }

    /// 按指定文件名存（App Store 结果用 trackId 做稳定键，存读两边对得上）。
    func store(_ image: UIImage, named fileName: String) -> String? {
        storeScaled(image, fileName: fileName)
    }

    private func storeScaled(_ image: UIImage, fileName: String) -> String? {
        let scaled = image.resized(maxEdge: 512) ?? image
        guard let data = scaled.pngData() ?? scaled.jpegData(compressionQuality: 0.9) else { return nil }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: url(for: fileName), options: .atomic)
            cache.setObject(scaled, forKey: fileName as NSString)
            return fileName
        } catch {
            return nil
        }
    }

    func delete(_ identifier: String?) {
        guard let identifier, !identifier.isEmpty else { return }
        try? FileManager.default.removeItem(at: url(for: identifier))
        cache.removeObject(forKey: identifier as NSString)
    }

    var cacheSizeBytes: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    func clearOrphans(keep identifiers: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for file in files where !identifiers.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func url(for fileName: String) -> URL { root.appendingPathComponent(fileName) }
}

extension UIImage {
    func resized(maxEdge: CGFloat) -> UIImage? {
        let larger = max(size.width, size.height)
        guard larger > maxEdge, larger > 0 else { return nil }
        let scale = maxEdge / larger
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
