import Foundation
import CryptoKit

/// 扣费提醒的纯计算层：给一批订阅和一份留痕，算出「此刻应当存在的通知」，
/// 再和「现在真的挂着的那些」对账，得出要补哪几条、要撤哪几条。
///
/// # 为什么单独一层
///
/// 上一版把这件事全写在 `SubscriptionScheduler` 里，直接对着 `UNUserNotificationCenter`：
/// 于是「改金额之后旧通知会不会更新」这种问题只能靠真机点一遍才知道，
/// 而月末、闰年、跨年这些日期边界又只有纯函数能逐条钉住。这一层不收系统中心，
/// 只收数据，所以每一条规则都有对应的单元测试。
///
/// # 三条对账规矩（任务书 §5.2）
///
/// 1. **标识稳定**：一条订阅一个标识（`saury.reminder.<订阅 id>`），外加 `.snooze`
///    后缀表示「稍后提醒」那一条。标识里**不含日期** —— 上一版把它做成
///    `订阅 id + 触发日`，结果同一期换个金额仍是同一个标识，
///    而旧代码恰好又「标识已经在挂起列表里就跳过」，那条通知就永远停在旧文案上。
/// 2. **内容靠签名比**：签名涵盖订阅、实际扣费日、触发时刻、名称、金额、币种、状态。
///    签名换了就先撤再排。挂起列表本身不带内容，所以签名单独存在偏好里，
///    跨进程还在 —— 否则重启一次就没人记得「那条通知当时写的是多少钱」。
/// 3. **只排未来的时刻**：错过的期次不补过去的通知，顺着周期往后推到第一期
///    还来得及的日子（§5.3）。宁可少提醒一次，也不排一条永远不会响的死请求。
enum ReminderPlan {
    /// 一条「此刻应当存在」的通知。
    struct Desired: Equatable {
        let subscriptionID: UUID
        let identifier: String
        let name: String
        let body: String
        let chargeDate: Date
        let fireAt: Date
        let signature: String
        let isSnoozed: Bool
    }

    struct Reconciliation: Equatable {
        var toAdd: [Desired] = []
        var toRemove: [String] = []
        /// 对账之后应当留下的签名。挂起列表里没有对应标识的那些条目一并清掉，
        /// 这张表才不会越积越脏。
        var signatures: [String: String] = [:]
    }

    /// 系统能挂起的通知数量有限（64 条），留出余量。
    /// 超出的部分按「离现在最近」优先，其余的直接不排。
    static let capacity = 56

    /// 一次规划的产物：要挂的这几条，和被条数上限挤掉的那几条。
    /// 挤掉多少必须说出来 —— 不说，界面上和日志里都只剩「提醒已经排好了」这句假话。
    struct Plan: Equatable {
        var entries: [Desired] = []
        var droppedByCapacity: Int = 0
    }

    // MARK: - 应当存在的通知

    /// - Parameter globalEnabled: 设置里的总开关。关掉就是清空，
    ///   而不是「留着旧的等它自己响」—— 用户说别吵，就真的别吵。
    static func desired(subscriptions: [Subscription],
                        globalEnabled: Bool,
                        hour: Int,
                        ledger: ReminderLedger,
                        now: Date,
                        calendar: Calendar = BillingMath.calendar) -> Plan {
        guard globalEnabled else { return Plan() }
        var result: [Desired] = []
        for subscription in subscriptions {
            if let reminder = desired(for: subscription, hour: hour, ledger: ledger,
                                      now: now, calendar: calendar) {
                result.append(reminder)
            }
        }
        // 容量截断要看谁最紧迫，所以先按触发时刻排好。
        let sorted = result.sorted { $0.fireAt < $1.fireAt }
        return Plan(entries: Array(sorted.prefix(capacity)),
                    droppedByCapacity: sorted.count - min(sorted.count, capacity))
    }

    /// 单条订阅应当挂哪一条通知。不满足条件（不提醒 / 不跟踪 / 一次性 /
    /// 后面没有来得及提醒的期次）就是 nil。
    static func desired(for subscription: Subscription,
                        hour: Int,
                        ledger: ReminderLedger,
                        now: Date,
                        calendar: Calendar = BillingMath.calendar) -> Desired? {
        // §5.1：要不要提醒只问这个开关。`reminderDays == 0` 是「当天」，
        // 不是旧界面嘴上说的「不提醒」。
        guard subscription.remindersEnabled, subscription.isTracked,
              subscription.cycle.isRecurring else { return nil }

        // 「稍后提醒」那一条还在将来：这一期就只排它，正常那条撤掉不再重复吵。
        if let snoozed = ledger.pendingSnooze(for: subscription.id, now: now, calendar: calendar) {
            return make(subscription: subscription, chargeDate: snoozed.chargeDate,
                        fireAt: snoozed.until, kind: .snooze, calendar: calendar)
        }

        // 顺着周期往后走，取第一期「还来得及、且这一期的提醒没有被用户撤掉」的。
        // 上限 24 期：年付也不会在这里绕圈 —— 推不出日子本身就会停。
        guard var chargeDate = upcomingChargeDate(for: subscription, from: now,
                                                  calendar: calendar, advancing: false) else { return nil }
        for _ in 0..<24 {
            if let fireAt = fireDate(chargeDate: chargeDate, days: subscription.reminderDays,
                                     hour: hour, calendar: calendar),
               fireAt >= now,
               !ledger.isAcknowledged(subscriptionID: subscription.id, chargeDate: chargeDate,
                                      calendar: calendar) {
                return make(subscription: subscription, chargeDate: chargeDate,
                            fireAt: fireAt, kind: .upcoming, calendar: calendar)
            }
            guard let next = upcomingChargeDate(for: subscription, from: chargeDate,
                                                calendar: calendar, advancing: true) else { return nil }
            chargeDate = next
        }
        return nil
    }

    /// 下一次扣费日。`advancing` 为真时不含 `from` 当天 —— 用来从「已经排过的这一期」
    /// 走到下一期，否则永远原地踏步。
    private static func upcomingChargeDate(for subscription: Subscription,
                                           from: Date,
                                           calendar: Calendar,
                                           advancing: Bool) -> Date? {
        let reference = advancing
            ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: from)) ?? from
            : from
        return BillingMath.nextChargeDate(for: subscription, onOrAfter: reference, calendar: calendar)
    }

    /// 扣费日往前推 N 天、落在 `hour` 整点。N = 0 就是扣费当天那个整点。
    /// 构造不出来（极端时区）或已经过了当天，返回 nil 让调用方往后推一期。
    static func fireDate(chargeDate: Date, days: Int, hour: Int,
                         calendar: Calendar = BillingMath.calendar) -> Date? {
        guard let day = calendar.date(byAdding: .day, value: -max(days, 0), to: chargeDate) else { return nil }
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = min(max(hour, 0), 23)
        components.minute = 0
        components.second = 0
        return calendar.date(from: components)
    }

    // MARK: - 正文与签名

    enum Kind { case upcoming, snooze }

    private static func make(subscription: Subscription, chargeDate: Date,
                             fireAt: Date, kind: Kind,
                             calendar: Calendar = BillingMath.calendar) -> Desired {
        let identifier = identifier(for: subscription.id, kind: kind)
        return Desired(
            subscriptionID: subscription.id,
            identifier: identifier,
            name: subscription.name,
            body: body(for: subscription, chargeDate: chargeDate, fireAt: fireAt, calendar: calendar),
            chargeDate: chargeDate,
            fireAt: fireAt,
            signature: signature(for: subscription, chargeDate: chargeDate, fireAt: fireAt,
                                 kind: kind, calendar: calendar),
            isSnoozed: kind == .snooze
        )
    }

    /// 正文写的是**实际扣费日**。
    ///
    /// 上一版写的是「还有 N 天」，那个数拿通知自己的触发日去算 ——
    /// 排进去的那天算出来是对的，可它是提前 N 天**排**的，用户在第 N 天看到的
    /// 本该是「今天扣费」，实际看到的却还是「还有 N 天」。
    /// 绝对日期不受这个矛盾影响：什么时候看都是那一句。
    static func body(for subscription: Subscription, chargeDate: Date, fireAt: Date,
                     calendar: Calendar = BillingMath.calendar) -> String {
        let amount = subscription.myAmount
        let chargeText = QJFormat.shortDate(chargeDate)
        let sameDay = calendar.isDate(chargeDate, inSameDayAs: fireAt)
        let when = sameDay ? "今天（\(chargeText)）" : chargeText
        let money = amount.minorUnits > 0 ? "扣费 \(amount.formatted)" : "该扣费了"
        return "「\(subscription.name)」将于 \(when)\(money)。"
    }

    /// 内容签名。任务书点名要覆盖的那几项都在里面：订阅、实际扣费日、触发时刻、
    /// 名称、金额、币种、状态。少一项，那一类改动就检不出来。
    static func signature(for subscription: Subscription, chargeDate: Date,
                          fireAt: Date, kind: Kind,
                          calendar: Calendar = BillingMath.calendar) -> String {
        // 签名叫的是「用户看得见的那一期、那一个点」，全部取本地日历分量：
        // 出了趟国、设备换了时区，同一期的分量没变，签名也就不该变。
        // 用时光戳的话，每次换区都会把所有提醒判成「内容变了」重排一遍 —— 那是自己造噪音。
        let chargeDay = calendar.dateComponents([.year, .month, .day], from: chargeDate)
        let fireParts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
        let amount = subscription.myAmount
        let canonical = [
            subscription.id.uuidString,
            "\(chargeDay.year ?? 0)-\(chargeDay.month ?? 0)-\(chargeDay.day ?? 0)",
            "\(fireParts.year ?? 0)-\(fireParts.month ?? 0)-\(fireParts.day ?? 0)"
                + "T\(fireParts.hour ?? 0):\(fireParts.minute ?? 0)",
            subscription.name,
            String(amount.minorUnits),
            amount.currencyCode,
            subscription.stateRawValue,
            String(subscription.reminderDays),
            subscription.remindersEnabled ? "on" : "off",
            kind == .snooze ? "snooze" : "upcoming",
        ].joined(separator: "\u{1f}")
        return BackupContainer.sha256(Data(canonical.utf8))
    }

    /// 稳定业务标识：一条订阅一个，「稍后提醒」另开一条。
    /// 不带日期：内容换了靠签名识别，标识本身只管「撤哪一条」。
    static func identifier(for subscriptionID: UUID, kind: Kind = .upcoming) -> String {
        switch kind {
        case .upcoming: return "saury.reminder.\(subscriptionID.uuidString)"
        case .snooze: return "saury.reminder.\(subscriptionID.uuidString).snooze"
        }
    }

    /// 这条标识属不属于本层管的范围（撤回与容量清理都只动这一族）。
    static func isReminderIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix("saury.reminder.")
    }

    // MARK: - 对账

    /// 应当存在的 vs 现在挂着的。
    ///
    /// - Parameters:
    ///   - pendingIdentifiers: 系统里此刻挂着的、属于订阅提醒这一族的标识。
    ///   - storedSignatures: 上次排进去时留下的内容签名。
    static func reconcile(desired: [Desired],
                          pendingIdentifiers: Set<String>,
                          storedSignatures: [String: String]) -> Reconciliation {
        var plan = Reconciliation()
        let desiredIDs = Set(desired.map(\.identifier))

        var obsolete = pendingIdentifiers.filter { !desiredIDs.contains($0) }

        var signatures: [String: String] = [:]
        for reminder in desired {
            signatures[reminder.identifier] = reminder.signature
            let alreadyPending = pendingIdentifiers.contains(reminder.identifier)
            if alreadyPending, storedSignatures[reminder.identifier] == reminder.signature {
                continue
            }
            // 没挂过，或者挂过但内容不是现在这一份。
            // 后者要先撤再排：同标识的 `add` 名义上会覆盖，可覆盖这件事只有真机能证明；
            // 显式撤一次，旧文案的消失就进了 `toRemove`，日志和测试都看得见。
            plan.toAdd.append(reminder)
            if alreadyPending { obsolete.insert(reminder.identifier) }
        }
        plan.toRemove = obsolete.sorted()
        // 挂起列表里那些已经不归我们管的条目，把签名一起清掉。
        plan.signatures = signatures
        return plan
    }
}
