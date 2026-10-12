import Foundation
import SwiftUI

/// 支出分类。内置一套，用户可以在设置里增删改；
/// 订阅身上只存 id，删除分类时订阅归入「其他」。
struct SubscriptionCategory: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    /// 十六进制，如 #4A9DFF。
    var colorHex: String
    var symbol: String

    var color: Color { Color(hex: colorHex) ?? .accentColor }

    static func with(id: String, in categories: [SubscriptionCategory]) -> SubscriptionCategory? {
        categories.first { $0.id == id }
    }
}

/// 内置支付方式。用户可以在设置里排序、增删；订阅只存名字。
enum PaymentCatalog {
    static let builtIn: [String] = [
        "支付宝", "微信支付", "Apple Pay", "Visa", "Mastercard", "美国运通", "银联", "PayPal"
    ]
}

/// 图标库：SF 符号按用途分组，配合调色板的颜色点出来就是一张图标。
enum IconLibrary {
    struct Group: Identifiable {
        let id: String
        let title: String
        let symbols: [String]
    }

    static let groups: [Group] = [
        Group(id: "general", title: "通用", symbols: [
            "textformat", "sparkles", "brain.head.profile", "play.tv.fill", "music.note",
            "film", "headphones", "tv", "cloud.fill", "internaldrive.fill",
            "hammer.fill", "chevron.left.forwardslash.chevron.right", "book.fill", "graduationcap.fill", "creditcard.fill",
            "dollarsign.circle.fill", "chart.line.uptrend.xyaxis", "gamecontroller.fill", "newsletters.fill", "bolt.fill",
            "globe", "envelope.fill", "camera.fill", "paintbrush.fill", "checkmark.shield.fill",
            "wifi", "bag.fill", "cart.fill", "photo.fill", "pencil",
            "clock.fill", "alarm.fill", "gift.fill", "heart.fill", "star.fill",
            "crown.fill", "mic.fill", "speaker.wave.3.fill", "phone.fill", "message.fill",
            "doc.text.fill", "folder.fill", "lock.fill", "key.fill", "bell.fill",
            "bolt.badge.clock", "server.rack", "desktopcomputer", "laptopcomputer.and.iphone", "apps.iphone"
        ]),
        Group(id: "cn-video", title: "国内影音", symbols: [
            "play.rectangle.fill", "play.square.stack", "hifispeaker.fill", "video.fill", "airplayvideo"
        ]),
        Group(id: "cn-service", title: "国内服务", symbols: [
            "bicycle", "car.fill", "bus.fill", "fork.knife", "bag.badge.plus",
            "shippingbox.fill", "tray.full.fill", "leaf.fill"
        ]),
        Group(id: "apple", title: "Apple", symbols: [
            "apple.logo", "music.note.list", "app.gift.fill", "icloud.fill", "newspaper.fill",
            "arcade.stick", "fitness", "tv.and.hifispeaker.fill"
        ]),
        Group(id: "ai", title: "AI", symbols: [
            "brain", "sparkle.magnifyingglass", "waveform.path.ecg", "cpu.fill", "text.bubble",
            "wand.and.stars", "slider.horizontal.2", "bubble.left.and.text.bubble.right"
        ])
    ]
}

/// 图标与卡片的调色板。顺序即图标选择器颜色行的顺序。
enum Palette {
    static let colors: [String] = [
        "#0A84FF", "#5E5CE6", "#BF5AF2", "#FF375F", "#FF453A",
        "#FF9F0A", "#30D158", "#63E6E2", "#64D2FF", "#FFD60A",
        "#FF6482", "#0FBFBF"
    ]

    /// 常用渐变组合（两色，主色在前）。
    static let gradients: [[String]] = [
        ["#FF375F", "#FF9F0A"],
        ["#5E5CE6", "#BF5AF2"],
        ["#0A84FF", "#64D2FF"],
        ["#30D158", "#63E6E2"],
        ["#FF6482", "#BF5AF2"],
        ["#FF9F0A", "#FFD60A"],
        ["#0FBFBF", "#30D158"],
        ["#FF453A", "#FF375F"]
    ]

    static func color(_ hex: String) -> Color {
        Color(hex: hex) ?? .accentColor
    }
}

extension Color {
    /// 支持 #RGB / #RRGGBB / #RRGGBBAA。
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 3 || text.count == 6 || text.count == 8 else { return nil }
        var value: UInt64 = 0
        Scanner(string: text).scanHexInt64(&value)
        switch text.count {
        case 3:
            let r = Double((value >> 8 & 0xF) * 17) / 255
            let g = Double((value >> 4 & 0xF) * 17) / 255
            let b = Double((value & 0xF) * 17) / 255
            self.init(red: r, green: g, blue: b)
        case 6:
            self.init(
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255
            )
        default:
            self.init(
                red: Double((value >> 24) & 0xFF) / 255,
                green: Double((value >> 16) & 0xFF) / 255,
                blue: Double((value >> 8) & 0xFF) / 255,
                opacity: Double(value & 0xFF) / 255
            )
        }
    }

    /// 渲染成 #RRGGBB，存库和取主色都用这个形态。
    var hexString: String {
        let ui = UIColor(self)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        ui.getRed(&red, green: &green, blue: &blue, alpha: nil)
        return String(format: "#%02X%02X%02X", Int(round(red * 255)), Int(round(green * 255)), Int(round(blue * 255)))
    }
}

enum DefaultCategories {
    static let items: [SubscriptionCategory] = [
        SubscriptionCategory(id: "video", name: "视频", colorHex: "#FF375F", symbol: "play.tv.fill"),
        SubscriptionCategory(id: "music", name: "音乐", colorHex: "#FF6482", symbol: "music.note"),
        SubscriptionCategory(id: "game", name: "游戏", colorHex: "#BF5AF2", symbol: "gamecontroller.fill"),
        SubscriptionCategory(id: "ai", name: "AI", colorHex: "#5E5CE6", symbol: "sparkles"),
        SubscriptionCategory(id: "efficiency", name: "效率", colorHex: "#0A84FF", symbol: "bolt.fill"),
        SubscriptionCategory(id: "cloud", name: "云盘", colorHex: "#64D2FF", symbol: "cloud.fill"),
        SubscriptionCategory(id: "reading", name: "阅读", colorHex: "#FF9F0A", symbol: "book.fill"),
        SubscriptionCategory(id: "shopping", name: "购物", colorHex: "#30D158", symbol: "bag.fill"),
        SubscriptionCategory(id: "health", name: "健康", colorHex: "#63E6E2", symbol: "heart.fill"),
        SubscriptionCategory(id: "other", name: "其他", colorHex: "#98989D", symbol: "square.grid.2x2")
    ]

    static var fallback: SubscriptionCategory { items.last! }
}
