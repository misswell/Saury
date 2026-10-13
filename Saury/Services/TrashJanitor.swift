import Foundation
import SwiftUI

/// 回收站的到期清理（任务书 §10.6「30 天期限有真实的数据清理任务」）。
///
/// # 这一层以前不存在
///
/// 页面上原先写着「保留 30 天」，而全工程没有任何一处按它清过 ——
/// 那是一句静态文案在冒充一个不存在的行为。改成「这里的东西不会自己消失」倒是真的，
/// 可它兑现的是「我们没做」。现在两边都对得上：没到期的一条都不动，
/// 到期的由这里连着事件和图标一起清掉，并且说出来。
///
/// # 触发点只有两处
///
/// 根视图的副作用（冷启动、回前台、数据变化后）和回收站页面（用户正盯着这张表的时候）。
/// 同步引擎不调它：「别的设备删了什么」和「这台设备什么时候该硬删」是两件事，
/// 后者的时钟属于本机，判据是 `deletedAt`（`TrashPolicy`）。
///
/// # 为什么整个方法是同步的
///
/// `SubscriptionRepository` 的写入路径本来就一路同步。中间不插 `await`，
/// 就不存在「两趟同时看到同一批到期项、各删一次」的窗口 ——
/// 第二趟拿到的已经是删完的库，自然一条都不到期。
@MainActor
struct TrashJanitor {
    struct Report: Equatable {
        /// 真的被彻底清除的那些名字，按删除时间从先到期排起。空数组 = 这一趟无事可做。
        var purged: [String]
        /// 落库失败的原因。有这一句就必须摊到用户眼前
        /// （§16「不静默吞掉重要保存或恢复失败」）：数据还留在回收站里，下一趟再试。
        var failure: String?

        /// 这一趟什么都不用说：没有到期项，也没有失败。
        var isQuiet: Bool { purged.isEmpty && failure == nil }

        /// 这一趟该对用户说的那句话；无事可做时是 nil，界面不该为一次空跑弹条。
        var feedback: WriteFeedback? {
            if let failure {
                return .failure("回收站到期清理没有成功：\(failure)。这些订阅还留在回收站里，下次打开会再试一次。")
            }
            guard purged.isEmpty == false else { return nil }
            let scope = "连同各自的历史扣费记录和只属于它们的图标一起"
            return .info(purged.count == 1
                ? "回收站里的「\(purged[0])」已满 \(TrashPolicy.retentionDays) 天保留期，\(scope)彻底删除。"
                : "回收站里的 \(purged.count) 条已满 \(TrashPolicy.retentionDays) 天保留期，\(scope)彻底删除。")
        }
    }

    let repository: SubscriptionRepository
    /// 「现在」由调用方给：到期判定要能被测试摆到第 29 天、第 30 天、第 31 天上去验。
    let now: Date

    init(repository: SubscriptionRepository, now: Date = Date()) {
        self.repository = repository
        self.now = now
    }

    /// 到期那几条。只读，不落盘 —— 回收站页面拿它决定「今天到期」这类话要不要说。
    var due: [Subscription] { repository.expiredTrashRows(now: now) }

    @discardableResult
    func run() -> Report {
        let candidates = due
        guard candidates.isEmpty == false else { return Report(purged: [], failure: nil) }
        let names = candidates.map(\.name)
        do {
            // 走仓储的批量彻底删除：事件跟着删、删除凭据在落盘成功之后才记、
            // 图标按引用计数释放 —— 手动「彻底删除」和到期清理必须走同一条路，
            // 不然两边会清出两种不同的结果。
            try repository.deletePermanently(candidates)
            return Report(purged: names, failure: nil)
        } catch {
            return Report(purged: [], failure: error.localizedDescription)
        }
    }
}
