import SwiftUI

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
    static let warn = Color(light: Color(red: 0.53, green: 0.35, blue: 0.07), dark: Color(red: 0.88, green: 0.70, blue: 0.36))

    static let pageGradient = LinearGradient(colors: [accent.opacity(0.10), calm.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension Color {
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

extension View {
    func qjCard(fill: Color = QJTheme.elevated, radius: CGFloat = 22) -> some View {
        self
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(QJTheme.line, lineWidth: 0.7))
    }
}
