import SwiftUI

struct QJHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String?
    let onSettings: () -> Void

    init(eyebrow: String, title: String, subtitle: String? = nil, onSettings: @escaping () -> Void) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.onSettings = onSettings
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text(eyebrow)
                    .font(.subheadline)
                    .foregroundStyle(QJTheme.subtle)
                Text(title)
                    .font(.system(size: 30, weight: .medium, design: .rounded))
                    .tracking(-0.8)
                    .foregroundStyle(QJTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(QJTheme.subtle)
                }
            }
            Spacer(minLength: 0)
            Button(action: onSettings) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(QJTheme.subtle)
                    .frame(width: 36, height: 36)
                    .background(QJTheme.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(QJTheme.line, lineWidth: 0.7))
            }
            .accessibilityLabel("打开设置")
        }
    }
}
