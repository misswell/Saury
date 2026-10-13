import Foundation

/// 回收站的保留规则（任务书 §10.6）。
///
/// 判据只有一个：`deletedAt`。不是「App 什么时候打开的」，也不是「这条什么时候同步到的」——
/// 拿那两个当尺子，离线设备的时钟会把 30 天拉成任意长度。
///
/// 按「日历天」数而不是 30×86400 秒：跨夏令时的那一天少一小时，
/// 按秒数会让同一条订阅在时区切换那天早一天被判到期。
/// `BillingMath` 那一整条日期链也是这个口径，两边不能各算各的。
enum TrashPolicy {
    /// 保留期（天）。
    ///
    /// 这个数字必须明显短于 `SyncTombstoneLog.retention`：本机硬删的那一刻才写下删除凭据，
    /// 凭据要是比保留期先到期，离线设备手上那条活的就有机会重新爬回云端。
    /// 谁改了哪一边，`TrashPurgeTests.testPurgeHorizonStaysShorterThanTombstoneRetention` 会红。
    static let retentionDays = 30

    enum Verdict: Equatable {
        /// 这一条根本不在回收站里（`deletedAt` 为空）。它永远不是清理候选 ——
        /// 在用的、归档的、停用的都走这一支，判错一次就是删用户的数据。
        case notTrashed
        /// 还没到期，还能剩 `daysLeft` 天。
        case kept(daysLeft: Int)
        /// 已满保留期，这一次可以彻底删除。
        case due
    }

    static func verdict(deletedAt: Date?, now: Date,
                        calendar: Calendar = BillingMath.calendar) -> Verdict {
        guard let deletedAt else { return .notTrashed }
        let elapsed = daysElapsed(since: deletedAt, now: now, calendar: calendar)
        guard elapsed >= retentionDays else {
            // 设备时钟被往回拨过会得到负数：按满额显示，别报「还剩 45 天」这种话。
            return .kept(daysLeft: min(max(retentionDays - elapsed, 0), retentionDays))
        }
        return .due
    }

    static func isDue(deletedAt: Date?, now: Date,
                      calendar: Calendar = BillingMath.calendar) -> Bool {
        verdict(deletedAt: deletedAt, now: now, calendar: calendar) == .due
    }

    /// 进回收站到现在过了几个日历天（同一天算 0）。
    static func daysElapsed(since deletedAt: Date, now: Date,
                            calendar: Calendar = BillingMath.calendar) -> Int {
        calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: deletedAt), to: calendar.startOfDay(for: now)
        ).day ?? 0
    }

    /// 「还剩 N 天」/「保留期已满」。页面拿它写那一行小字，
    /// 免得「30 天」这个数字在两个地方各写一遍。
    ///
    /// 到期那一支故意不说「今天就删」：清理也可能失败（落盘没成），
    /// 那一行字讲的是这一条处在哪一档，不是承诺下一次一定删得掉。
    static func notice(for deletedAt: Date?, now: Date,
                       calendar: Calendar = BillingMath.calendar) -> String {
        switch verdict(deletedAt: deletedAt, now: now, calendar: calendar) {
        case .notTrashed: return ""
        case .due: return "保留期已满"
        case .kept(let days): return "还剩 \(days) 天"
        }
    }
}
