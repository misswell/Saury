import Foundation

/// 用户对通知做过的手，和上次排进去时留下的内容签名。
///
/// # 为什么要单独存
///
/// 系统那侧只肯告诉我们「现在挂着哪些标识」，不告诉我们那条通知当初写的是
/// 什么文案、也不记得用户有没有在它上面按过「本期不再提醒」。这两件事都必须
/// 活过进程重启，否则下次 `refill` 会把用户明确撤掉的那一期当新事项重新排回去 ——
/// 通知又弹一次，是任务书 §5.4 点名要避免的。
///
/// 键都带上报纸一样的日期戳：一条订阅的每一个扣费期各留一份痕迹，
/// 「这一期已经处理过」不会顺手把下一期也免掉。
///
/// 不加 `@MainActor`：它只读写 UserDefaults（本身线程安全），而 `ReminderPlan`
/// 那些纯计算要在非隔离的规划路径上查它。挂上 MainActor 会把纯计算层一起拽进
/// 主线程隔离里，测试也就没法在别的执行器上跑日期边界。
final class ReminderLedger {
    static let shared = ReminderLedger()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private enum Key {
        static let acknowledgements = "saury.reminder.acknowledged"
        static let snoozes = "saury.reminder.snoozedUntil"
        static let signatures = "saury.reminder.signatures"
    }

    // MARK: - 内容签名

    /// 上次真的排进去的那些标识 → 内容签名。对账就靠这张表。
    var signatures: [String: String] {
        (defaults.dictionary(forKey: Key.signatures) as? [String: String]) ?? [:]
    }

    func setSignatures(_ signatures: [String: String]) {
        defaults.set(signatures, forKey: Key.signatures)
    }

    // MARK: - 本期不再提醒

    /// 用户说这一期他已经处理过了。此后 `refill` 不再为同一期排通知，
    /// 但**下一期照常** —— 撤的从来不是这条订阅，只是这一笔。
    func acknowledge(subscriptionID: UUID, chargeDate: Date, at: Date = Date(),
                     calendar: Calendar = BillingMath.calendar) {
        var log = acknowledgements
        log[periodKey(subscriptionID, chargeDate, calendar: calendar)] = at.timeIntervalSince1970
        defaults.set(log, forKey: Key.acknowledgements)
    }

    func isAcknowledged(subscriptionID: UUID, chargeDate: Date,
                        calendar: Calendar = BillingMath.calendar) -> Bool {
        acknowledgements[periodKey(subscriptionID, chargeDate, calendar: calendar)] != nil
    }

    private var acknowledgements: [String: Double] {
        (defaults.dictionary(forKey: Key.acknowledgements) as? [String: Double]) ?? [:]
    }

    // MARK: - 稍后提醒

    /// snooze 只往将来推，且仍然算「这一期」的：`pendingSnooze` 期间正常那条不排。
    func snooze(subscriptionID: UUID, chargeDate: Date, until: Date,
                calendar: Calendar = BillingMath.calendar) {
        var log = snoozes
        log[periodKey(subscriptionID, chargeDate, calendar: calendar)] = until.timeIntervalSince1970
        defaults.set(log, forKey: Key.snoozes)
    }

    /// 这条订阅有没有一条还没到点的「稍后提醒」。有就把它属于哪一期、几点响一起带出来 ——
    /// 正文要写实际扣费日，所以「哪一期」不能到了渲染的时候再猜。
    /// 同时挂着好几条（用户连按两次）取最早要响的那一条。
    func pendingSnooze(for subscriptionID: UUID, now: Date = Date(),
                       calendar: Calendar = BillingMath.calendar) -> (chargeDate: Date, until: Date)? {
        let prefix = subscriptionID.uuidString + "|"
        var earliest: (chargeDate: Date, until: Date)?
        for (key, value) in snoozes where key.hasPrefix(prefix) {
            let until = Date(timeIntervalSince1970: value)
            guard until > now,
                  let chargeDate = dayDate(String(key.dropFirst(prefix.count)), calendar: calendar) else { continue }
            let candidate: (chargeDate: Date, until: Date) = (chargeDate, until)
            if let current = earliest, current.until <= candidate.until { continue }
            earliest = candidate
        }
        return earliest
    }

    private var snoozes: [String: Double] {
        (defaults.dictionary(forKey: Key.snoozes) as? [String: Double]) ?? [:]
    }

    // MARK: - 清理

    /// 扣费日已经过去的那些痕迹永远不会再被查到：留着只会让这张表一直长。
    /// 只清过去的，没到的期一次都不动。
    func pruneExpired(now: Date, calendar: Calendar = BillingMath.calendar) {
        let today = dayKey(calendar.startOfDay(for: now), calendar: calendar)
        defaults.set(acknowledgements.filter { periodStart($0.key) >= today },
                     forKey: Key.acknowledgements)
        defaults.set(snoozes.filter { periodStart($0.key) >= today }, forKey: Key.snoozes)
    }

    /// `<订阅 id>|<扣费日的年月日>`。
    ///
    /// 存的是「几月几号」而不是那一刻的时光戳：出了趟国、设备换了时区之后，
    /// 「这一期我已经处理过」必须还算数。按戳存的话，换区后的 0 点变成另一个瞬间，
    /// 痕迹查不到，那条通知就会再响一次 —— §5.4 点名要避免的正是这个。
    /// ISO 日期串按字典序比就是按时间比，清理时不用还原成日期。
    private func periodKey(_ subscriptionID: UUID, _ chargeDate: Date,
                           calendar: Calendar = BillingMath.calendar) -> String {
        "\(subscriptionID.uuidString)|\(dayKey(chargeDate, calendar: calendar))"
    }

    private func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// 反回来的一期扣费日 = 那个日期的当天 0 点（按同一套历法）。
    private func dayDate(_ dayKey: String, calendar: Calendar) -> Date? {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private func periodStart(_ key: String) -> String {
        String(key.split(separator: "|").last ?? Substring(key))
    }
}
