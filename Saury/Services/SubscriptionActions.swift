import Foundation
import UIKit
import SwiftUI
import SwiftData

/// 订阅生命周期动作的唯一编排处（任务书 §2.3、§8.5）。
///
/// 滑动操作、长按菜单、批量栏、详情工具栏以前各写一遍「改状态 + 触感 + 快照 + 撤销条 + 文案」，
/// 十六个调用点里有四处把仓储返回的快照直接丢掉 —— 置顶因此根本没有撤销；
/// 归档在长按菜单里缺席；事件删除没有撤销；单复数文案有三种写法。
/// 现在调用点只剩「要做什么」这一句，其余归这里。
///
/// # 失败时为什么不用「把行放回去」
///
/// 仓储的 `commitStrict` 在落盘失败时整批 `rollback()`，而且不广播「数据变了」，
/// 所以列表里那一行从来就没真的消失过。这里要做的只是把原因摊出来 ——
/// 「先删掉 UI 再静默失败」那种写法在这里没有可乘之机。
@MainActor
struct SubscriptionActions {
    let repository: SubscriptionRepository
    let feedback: WriteFeedbackCenter
    /// 提示条挂在哪。sheet 会盖住根视图上那一条，所以详情页里的失败要显示在页内；
    /// 撤销入口反过来必须挂到根视图 —— 详情页一关就没了。
    let local: Binding<WriteFeedback?>?

    init(repository: SubscriptionRepository,
         feedback: WriteFeedbackCenter? = nil,
         local: Binding<WriteFeedback?>? = nil) {
        self.repository = repository
        // `.shared` 不能在默认参数表达式里取：那一段不是 MainActor 上下文。
        self.feedback = feedback ?? .shared
        self.local = local
    }

    // MARK: - 置顶 / 归档 / 回收站 / 停用

    /// 返回值只有一件事：这次真的落库了没有。调用方用它决定要不要关页。
    @discardableResult
    func setPinned(_ subscriptions: [Subscription], _ pinned: Bool) -> Bool {
        run(subscriptions, verb: pinned ? "已置顶" : "已取消置顶", impact: .light) {
            try repository.setPinned(subscriptions, pinned)
        }
    }

    @discardableResult
    func archive(_ subscriptions: [Subscription]) -> Bool {
        run(subscriptions, verb: "已归档", impact: .medium) {
            try repository.archive(subscriptions)
        }
    }

    @discardableResult
    func unarchive(_ subscriptions: [Subscription]) -> Bool {
        run(subscriptions, verb: "已恢复", impact: .medium) {
            try repository.unarchive(subscriptions)
        }
    }

    @discardableResult
    func moveToTrash(_ subscriptions: [Subscription]) -> Bool {
        run(subscriptions, verb: "已移入回收站", impact: .heavy) {
            try repository.moveToTrash(subscriptions)
        }
    }

    @discardableResult
    func restoreFromTrash(_ subscriptions: [Subscription]) -> Bool {
        run(subscriptions, verb: "已从回收站恢复", impact: .medium) {
            try repository.restoreFromTrash(subscriptions)
        }
    }

    /// 改状态。这里没有「启用就是改回自动续费」那种猜测：调用方必须说要成哪一个状态，
    /// 手动续费的那条才不会被一次「启用」顺手改成自动。撤销走快照，回到的是原样。
    @discardableResult
    func setState(_ subscriptions: [Subscription], to state: SubscriptionState) -> Bool {
        run(subscriptions, verb: verb(for: state), impact: state == .inactive ? .medium : .light) {
            try repository.setState(subscriptions, state)
        }
    }

    private func verb(for state: SubscriptionState) -> String {
        switch state {
        case .inactive: return "已停用"
        case .autoRenew: return "已改为自动续费"
        case .manualRenew: return "已改为手动续费"
        }
    }

    // MARK: - 彻底删除

    /// 不可撤销，所以**调用方必须先拿到用户明确的确认**（任务书 §10.6「永久删除前明确提示」）。
    /// 这里不弹确认：同一个方法被行内按钮和「清空回收站」共用，确认文案各自不同。
    @discardableResult
    func deleteForever(_ subscriptions: [Subscription]) -> Bool {
        guard subscriptions.isEmpty == false else { return false }
        let names = subscriptions.map(\.name)
        do {
            try repository.deletePermanently(subscriptions)
            SelectionHaptics.impact(.heavy)
            feedback.show(.notice(summary("已彻底删除", names), actionTitle: nil))
            return true
        } catch {
            feedback.report(error, to: local)
            return false
        }
    }

    // MARK: - 事件

    /// 删一条记录。撤销是按删之前那份草稿重新补回同一行（按稳定 id upsert），
    /// 所以不会多出一条，也不会把删除凭据留在那儿让同步再删一遍。
    /// 补回来走的是 `restore`，不是 `record`：删除没动过现价，撤销也不该动。
    @discardableResult
    func remove(_ event: SubscriptionEvent) -> Bool {
        let draft = repository.draft(of: event)
        let title = event.type.title
        do {
            try repository.remove(event)
            SelectionHaptics.impact(.heavy)
            feedback.offerUndo("已删除一条\(title)记录", local: local) { [repository] in
                try repository.restore(draft)
            }
            return true
        } catch {
            feedback.report(error, to: local)
            return false
        }
    }

    // MARK: - 共用路径

    private func run(_ subscriptions: [Subscription],
                     verb: String,
                     impact: UIImpactFeedbackGenerator.FeedbackStyle,
                     _ work: () throws -> [SubscriptionRepository.StatusSnapshot]) -> Bool {
        guard subscriptions.isEmpty == false else { return false }
        // 名字先抄下来：撤销条上那句要读它，而对象在整批操作之后不一定还有效。
        let names = subscriptions.map(\.name)
        do {
            let before = try work()
            SelectionHaptics.impact(impact)
            feedback.offerUndo(summary(verb, names), before, using: repository, local: local)
            return true
        } catch {
            feedback.report(error, to: local)
            return false
        }
    }

    /// 「已归档「Netflix」」/「已归档 3 条」。
    private func summary(_ verb: String, _ names: [String]) -> String {
        names.count == 1 ? "\(verb)「\(names[0])」" : "\(verb) \(names.count) 条"
    }
}
