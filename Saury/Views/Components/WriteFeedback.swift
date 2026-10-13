import SwiftUI

/// 底部反馈条的内容。两种用途共用一条样式：写库失败要说清楚原因，
/// 软删除要给一个撤销入口。可比等值，动画才挂得住。
struct WriteFeedback: Equatable {
    enum Style {
        case failure
        case notice
        /// 数据真的变了、而且不可撤销的一句话（回收站到期清理）。
        /// 和 `.notice` 的区别只有那条计时器：撤销入口浮一会儿就够了，
        /// 「已经删掉的东西」不能靠一闪而过带过去，得留到用户自己关掉。
        case info
    }

    var style: Style
    var text: String
    var actionTitle: String?

    static func failure(_ text: String) -> WriteFeedback {
        WriteFeedback(style: .failure, text: text, actionTitle: nil)
    }

    static func notice(_ text: String, actionTitle: String?) -> WriteFeedback {
        WriteFeedback(style: .notice, text: text, actionTitle: actionTitle)
    }

    static func info(_ text: String) -> WriteFeedback {
        WriteFeedback(style: .info, text: text, actionTitle: nil)
    }

    var symbol: String {
        switch style {
        case .failure: return "exclamationmark.triangle.fill"
        case .notice: return "arrow.uturn.backward.circle.fill"
        case .info: return "trash.circle.fill"
        }
    }

    var tint: Color {
        switch style {
        case .failure: return Color(red: 0.86, green: 0.24, blue: 0.24)
        case .notice, .info: return Color(white: 0.16)
        }
    }
}

extension View {
    /// 贴在底部的写库反馈条。`action` 对应条上那个按钮（撤销、重试）。
    @ViewBuilder
    func writeFeedback(
        _ feedback: Binding<WriteFeedback?>,
        bottomPadding: CGFloat = 12,
        action: (() -> Void)? = nil
    ) -> some View {
        overlay(alignment: .bottom) {
            WriteFeedbackBanner(feedback: feedback, bottomPadding: bottomPadding, action: action)
        }
    }
}

/// 跨页面的一句话：删除后的撤销、批量操作的结果。
/// 谁触发的不重要，用户看得见才重要 —— 详情页删完就关页了，
/// 条子必须活在根视图上，不然「撤销」跟着 sheet 一起消失。
@MainActor
final class WriteFeedbackCenter: ObservableObject {
    static let shared = WriteFeedbackCenter()

    @Published var message: WriteFeedback?
    private var action: (() -> Void)?

    func show(_ message: WriteFeedback, action: (() -> Void)? = nil) {
        self.message = message
        self.action = action
    }

    func clear() {
        message = nil
        action = nil
    }

    /// 按钮按下去：先把条子收掉，再执行动作。动作自己负责报错。
    func performAction() {
        let action = self.action
        clear()
        action?()
    }

    /// 页面里的写库都从这里过：成功才轮到成功触感，失败就把原因摊出来。
    /// `local` 非空时提示条显示在当前 sheet 里（sheet 会盖住根视图上的那一条）。
    @MainActor
    func perform(_ action: () throws -> Void, local: Binding<WriteFeedback?>? = nil) {
        do {
            try action()
        } catch {
            report(error, to: local)
        }
    }

    @MainActor
    func report(_ error: Error, to local: Binding<WriteFeedback?>? = nil) {
        SelectionHaptics.error()
        let message = WriteFeedback.failure(error.localizedDescription)
        if let local {
            local.wrappedValue = message
        } else {
            show(message)
        }
    }

    /// 通用撤销入口。怎么把刚才那一步退回去由调用方说 ——
    /// 状态快照、事件重记，都是同一句「撤销」，不该各写一条路径。
    @MainActor
    func offerUndo(_ text: String,
                   local: Binding<WriteFeedback?>? = nil,
                   _ undo: @escaping () throws -> Void) {
        let center = self
        show(.notice(text, actionTitle: "撤销")) {
            do {
                try undo()
                SelectionHaptics.success()
            } catch {
                center.report(error, to: local)
            }
        }
    }

    /// 软删除 / 归档之后的撤销入口。撤销本身也是一次写库，失败照样摊出来。
    @MainActor
    func offerUndo(
        _ text: String,
        _ snapshots: [SubscriptionRepository.StatusSnapshot],
        using repository: SubscriptionRepository,
        local: Binding<WriteFeedback?>? = nil
    ) {
        guard snapshots.isEmpty == false else {
            show(.notice(text, actionTitle: nil))
            return
        }
        offerUndo(text, local: local) { try repository.restore(snapshots) }
    }
}

private struct WriteFeedbackBanner: View {
    @Binding var feedback: WriteFeedback?
    var bottomPadding: CGFloat
    var action: (() -> Void)?

    var body: some View {
        Group {
            if let feedback {
                HStack(spacing: 10) {
                    Image(systemName: feedback.symbol)
                        .font(.system(size: 13, weight: .semibold))
                    Text(feedback.text)
                        .font(.footnote.weight(.medium))
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    if let title = feedback.actionTitle, let action {
                        Button(title) {
                            withAnimation(Motion.ui) { self.feedback = nil }
                            action()
                        }
                        .font(.footnote.weight(.bold))
                    }
                    Button {
                        withAnimation(Motion.ui) { self.feedback = nil }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                    }
                    .accessibilityLabel("关闭提示")
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(feedback.tint.opacity(0.96))
                        .shadow(color: .black.opacity(0.32), radius: 12, y: 4)
                )
                .padding(.horizontal, SauryTheme.screen)
                .padding(.bottom, bottomPadding)
                .transition(.offset(y: 80).combined(with: .opacity))
                // 提示条是自己管动画的：挂在宿主页面上会把整棵子树的动画事务改成 nil。
                .task(id: feedback) {
                    // 撤销入口只浮一小会儿；真正的恢复随时能在回收站里做到，
                    // 所以这条计时器不承载任何数据结果。
                    // `.info`（到期清理已经删了什么）和 `.failure` 都不在这里自动收 ——
                    // 前者讲的是一件不可恢复的事，得等用户自己关掉。
                    guard feedback.style == .notice else { return }
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled else { return }
                    withAnimation(Motion.ui) { self.feedback = nil }
                }
            }
        }
        .animation(Motion.pop, value: feedback)
    }
}
