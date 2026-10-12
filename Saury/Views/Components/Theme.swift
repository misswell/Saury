import SwiftUI

extension Color {
    /// 同一个颜色在浅色 / 深色模式下取不同的值。
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

/// 视觉基调：近黑底、卡片、圆角、大数字用圆体。
/// 强调色跟随主题色设置（SubPreferences.accentHex），由根视图注入 tint。
enum SauryTheme {
    static let background = Color(light: Color(red: 0.949, green: 0.949, blue: 0.969), dark: Color(red: 0.043, green: 0.043, blue: 0.047))
    static let surface = Color(light: .white, dark: Color(red: 0.106, green: 0.106, blue: 0.114))
    static let surfaceElevated = Color(light: Color(white: 0.97), dark: Color(red: 0.157, green: 0.157, blue: 0.169))
    static let line = Color(light: Color(white: 0.85), dark: Color(white: 0.18))

    static let ink = Color.primary
    static let subtle = Color.secondary

    static let screen: CGFloat = 16
    static let card: CGFloat = 16
    static let radius: CGFloat = 20
    static let cardRadius: CGFloat = 18

    /// 大金额数字：圆体、粗、带千分位。
    static func amountFont(size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }
}

/// 订阅卡片的渐变底。一个色是单色卡，两三个按顺序拉对角渐变。
struct CardGradient: View {    let hexes: [String]
    var fallback: Color = .gray

    var body: some View {
        Group {
            if hexes.count >= 2 {
                let colors = hexes.prefix(3).compactMap { Color(hex: $0) }
                LinearGradient(
                    colors: colors.isEmpty ? [fallback] : colors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else if let single = hexes.first, let color = Color(hex: single) {
                LinearGradient(
                    colors: [color.opacity(0.92), color],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                LinearGradient(
                    colors: [fallback.opacity(0.7), fallback],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }
}

/// 从一张图里取主色：画进 1×1 的 RGBA 上下文读平均色。太浅/太深就往中间压一档，
/// 否则白色图标的卡片会白成一片、黑色图标的会黑成一片。
enum IconTint {
    static func dominantColor(of image: UIImage?) -> Color? {
        guard let image, let cgImage = image.cgImage else { return nil }
        guard let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data else { return nil }
        let buffer = data.bindMemory(to: UInt8.self, capacity: 4)
        var red = Double(buffer[0]) / 255
        var green = Double(buffer[1]) / 255
        var blue = Double(buffer[2]) / 255
        let alpha = Double(buffer[3]) / 255
        guard alpha > 0.05 else { return nil }
        let brightness = red * 0.299 + green * 0.587 + blue * 0.114
        if brightness > 0.92 {
            red = max(red - 0.35, 0.45); green = max(green - 0.35, 0.45); blue = max(blue - 0.35, 0.45)
        }
        if brightness < 0.10 {
            red = min(red + 0.3, 0.6); green = min(green + 0.3, 0.6); blue = min(blue + 0.3, 0.6)
        }
        let isNeutral = abs(red - green) < 0.06 && abs(green - blue) < 0.06 && abs(red - blue) < 0.06
        if isNeutral { return Color(red: 0.45, green: 0.45, blue: 0.47) }
        return Color(red: red, green: green, blue: blue)
    }
}

extension View {
    func sauryCard(fill: Color = SauryTheme.surface, radius: CGFloat = SauryTheme.radius) -> some View {
        self
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
