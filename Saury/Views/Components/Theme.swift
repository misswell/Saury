import SwiftUI

/// 内容层配色。品牌强调色只有一个（`accent`），其余是纸、墨、灰阶。
/// 状态色不在这里，见 `ExpiryUrgency`。
enum QJTheme {
    static let canvas = Color(light: Color(red: 0.93, green: 0.92, blue: 0.88), dark: Color(red: 0.09, green: 0.10, blue: 0.10))
    static let surface = Color(light: Color(red: 0.98, green: 0.97, blue: 0.94), dark: Color(red: 0.13, green: 0.14, blue: 0.14))
    static let elevated = Color(light: .white, dark: Color(red: 0.17, green: 0.18, blue: 0.18))
    static let ink = Color(light: Color(red: 0.12, green: 0.15, blue: 0.13), dark: Color(red: 0.95, green: 0.96, blue: 0.94))
    static let subtle = Color(light: Color(red: 0.42, green: 0.45, blue: 0.43), dark: Color(red: 0.68, green: 0.71, blue: 0.69))
    static let line = Color(light: Color(red: 0.85, green: 0.85, blue: 0.82), dark: Color(red: 0.24, green: 0.26, blue: 0.25))
    static let accent = Color(light: Color(red: 0.85, green: 0.29, blue: 0.23), dark: Color(red: 0.94, green: 0.44, blue: 0.35))
    static let accentSoft = Color(light: Color(red: 0.98, green: 0.86, blue: 0.83), dark: Color(red: 0.27, green: 0.16, blue: 0.14))
    static let calm = Color(light: Color(red: 0.19, green: 0.36, blue: 0.29), dark: Color(red: 0.48, green: 0.73, blue: 0.61))
    static let calmSoft = Color(light: Color(red: 0.86, green: 0.92, blue: 0.88), dark: Color(red: 0.13, green: 0.24, blue: 0.19))
}

/// 内容层节奏。导航、工具栏、Tab 栏、搜索、菜单、弹层都交给系统，
/// 页面只负责这一套间距。
enum QJMetric {
    static let screen: CGFloat = 16
    static let section: CGFloat = 26
    static let card: CGFloat = 16
    static let row: CGFloat = 12
}

extension Color {
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

extension View {
    /// 内容卡片：只有分组背景，没有描边和阴影。层级靠间距和字号，不靠描边。
    func qjCard(fill: Color = QJTheme.elevated, radius: CGFloat = 20) -> some View {
        self
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
