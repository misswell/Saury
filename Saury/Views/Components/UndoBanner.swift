import SwiftUI

/// 「已标记为『用完』 —— 撤销」（方案 §37）。误操作之后给一次反悔的机会，
/// 而不是弹一个确认框把每一步都打断。
struct UndoBanner: View {
    let record: ExpiryUndoRecord
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: record.action.symbolName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(QJTheme.calm)
            Text("\(record.itemName) 已标记为「\(record.actionTitle)」")
                .font(.subheadline)
                .foregroundStyle(QJTheme.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("撤销", action: onUndo)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(QJTheme.accent)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.semibold))
                    .foregroundStyle(QJTheme.subtle)
            }
            .accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
        .padding(.horizontal, QJMetric.screen)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task {
            try? await Task.sleep(for: .seconds(6))
            onDismiss()
        }
    }
}
