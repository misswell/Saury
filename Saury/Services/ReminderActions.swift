import Foundation
import UserNotifications
import SwiftData

/// 通知上的三个快捷入口（任务书 §5.4）：查看订阅、稍后提醒、本期不再提醒。
///
/// # 为什么「稍后提醒」不自己直接排一条通知
///
/// 它只往留痕里写一笔（`ReminderLedger.snooze`），然后叫调度器重排一次。
/// 排通知这件事只有一处实现，动作这边不可能排出一条和 `ReminderPlan` 口径不一样的 ——
/// 触发类型、正文、签名、条数上限全都归那条路管。
/// 直接在这里 `center.add(...)` 也能响，但那就成了第二条排通知的路，
/// 下一轮重排会把它当旧东西撤掉，用户的「稍后提醒」白按。
///
/// # 不做的那两个入口
///
/// 「标记已扣费」「直接停用」这类按钮没有做。前者会替用户写一笔他并没有真实
/// 付过的付款记录（任务书 §16 明令不许把计划扣费说成实际付款），后者要在通知里
/// 做一次不可逆的数据改动却只有一句标题。要真做，得先在界面里确认。
enum ReminderActions {
    static let categoryIdentifier = "saury.subscription.reminder"
    static let viewIdentifier = "saury.reminder.action.view"
    static let snoozeIdentifier = "saury.reminder.action.snooze"
    static let doneIdentifier = "saury.reminder.action.done"

    /// 「稍后提醒」推多久。一小时：够把手头的事做完，又不会推到扣费日之后去。
    static let snoozeInterval: TimeInterval = 60 * 60

    /// 动作算出来的意图。纯函数，不碰系统中心。
    enum Intent: Equatable {
        /// 点开通知，或点「查看订阅」：要看到哪一条。
        case open(UUID)
        /// 「稍后提醒」：这一期往后再推一次。
        case snooze(subscriptionID: UUID, chargeDate: Date)
        /// 「本期不再提醒」：这一期的提醒撤掉，下一期照常。
        case acknowledge(subscriptionID: UUID, chargeDate: Date)
        /// 认不出来的通知（旧版本留下的、别的功能的）什么都不做。
        case ignore
    }

    /// 从一次点击响应里读出意图。
    ///
    /// 只认带 `subscriptionID` + `chargeDate` 的这一族；读不出订阅身份
    /// （旧版本排的通知、别的功能的通知）就什么都不做 —— 瞎跳一条订阅比不跳更糟。
    static func intent(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> Intent {
        guard let raw = userInfo["subscriptionID"] as? String, let id = UUID(uuidString: raw) else {
            return .ignore
        }
        let chargeDate = (userInfo["chargeDate"] as? Double).map(Date.init(timeIntervalSince1970:))
            ?? (userInfo["chargeDate"] as? String).flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
        guard let chargeDate else { return .open(id) }
        switch actionIdentifier {
        case snoozeIdentifier:
            return .snooze(subscriptionID: id, chargeDate: chargeDate)
        case doneIdentifier:
            return .acknowledge(subscriptionID: id, chargeDate: chargeDate)
        default:
            // 系统的默认动作（点开通知本身）就是「查看订阅」。
            return .open(id)
        }
    }

    @MainActor
    static func register(in center: UNUserNotificationCenter) {
        let view = UNNotificationAction(identifier: viewIdentifier,
                                        title: "查看订阅",
                                        options: [.foreground])
        let snooze = UNNotificationAction(identifier: snoozeIdentifier,
                                         title: "稍后提醒（1 小时）",
                                         options: [])
        let done = UNNotificationAction(identifier: doneIdentifier,
                                       title: "本期不再提醒",
                                       options: [])
        let category = UNNotificationCategory(identifier: categoryIdentifier,
                                              actions: [view, snooze, done],
                                              intentIdentifiers: [],
                                              options: [])
        center.setNotificationCategories([category])
    }
}

/// 通知动作落到本机数据上的那一脚。
@MainActor
enum ReminderInteraction {
    /// 处理一次点击。返回做了什么，调用方（App 委托）只负责转达，不做判断。
    @discardableResult
    static func handle(_ intent: ReminderActions.Intent,
                       preferences: SubPreferences,
                       scheduler: SubscriptionScheduler,
                       ledger: ReminderLedger,
                       container: ModelContainer?,
                       now: Date = Date()) -> String {
        switch intent {
        case .ignore:
            return "没认出来的通知，什么都没做"
        case .open(let id):
            ReminderNavigation.shared.request(id)
            return "打开订阅"
        case .snooze(let id, let chargeDate):
            ledger.snooze(subscriptionID: id, chargeDate: chargeDate,
                          until: now.addingTimeInterval(ReminderActions.snoozeInterval))
            refill(preferences: preferences, scheduler: scheduler, container: container, now: now)
            return "已推后 1 小时"
        case .acknowledge(let id, let chargeDate):
            ledger.acknowledge(subscriptionID: id, chargeDate: chargeDate)
            refill(preferences: preferences, scheduler: scheduler, container: container, now: now)
            return "本期不再提醒"
        }
    }

    /// 用库里的当前状态重排一次。拿不到库的时候不报错、不假装：
    /// 留痕已经写进去了，下一次真的重排（回前台、改动）会照它执行。
    private static func refill(preferences: SubPreferences,
                              scheduler: SubscriptionScheduler,
                              container: ModelContainer?,
                              now: Date) {
        guard let container else { return }
        let context = ModelContext(container)
        let subscriptions = (try? context.fetch(FetchDescriptor<Subscription>())) ?? []
        Task { await scheduler.refill(subscriptions: subscriptions,
                                      hour: preferences.reminderHour,
                                      enabled: preferences.notificationsEnabled,
                                      now: now) }
    }
}

/// 「点开通知要看哪条订阅」的交接处。
///
/// 为什么不能只发一条通知广播：App 很可能就是被这一下点击才起来的，
/// 那一刻根视图还没挂上监听，广播发出去就没人接 —— 用户看到的是
/// 「点通知没反应」。先存着，根视图起来第一件事就是取；已经在前台跑着的时候
/// 靠下面那个广播当场就跳。
///
/// 为什么是个实例而不是全局静态：跑测试时宿主 App 的 RootView 是活的，
/// `post` 会同步走到它的监听里、把队列当场取走，于是「按顺序交接」这件事
/// 在全局那一份上永远测不到。生产只用 `shared`，测试各自 new 一个。
@MainActor
final class ReminderNavigation {
    static let shared = ReminderNavigation()

    private var queue: [UUID] = []

    func request(_ id: UUID) {
        queue.append(id)
        NotificationCenter.default.post(name: .sauryOpenSubscription, object: nil)
    }

    /// 取走最早那一次点击。队列空了就返回 nil（不是每次点击都还找得到那条订阅）。
    func consume() -> UUID? {
        queue.isEmpty ? nil : queue.removeFirst()
    }
}

extension Notification.Name {
    /// 通知里点进来的那一条订阅。根视图接住，切到订阅页并把详情打开。
    static let sauryOpenSubscription = Notification.Name("saury.openSubscription")
}
