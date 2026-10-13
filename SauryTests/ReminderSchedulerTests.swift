import XCTest
import SwiftData
@testable import Saury

/// §5.2 与 §5.4 落地的那一半：对账结果怎么变成系统里的通知，
/// 以及用户在通知上按了三下之后，本机数据和待处理提醒怎么一起变。
///
/// `UNUserNotificationCenter` 在这个环境里跑不起来（没签名、没授权），
/// 所以投递走 `FakeDelivery` 这个假件：`refill` 的算法路径和真机完全一样，
/// 只有最后那一脚换成记账。这样「系统拒收的不能写进签名表」「挤掉的要说出来」
/// 这类规则才测得到。
///
/// 测不到的还是那两样：通知到底会不会响、系统上限到底是不是 64 条。
/// 它们在 `Docs/EON_QA.md` 里按「需真机验收」记，不在这里当作已过。
@MainActor
final class ReminderSchedulerTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDownWithError() throws {
        for name in suiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        suiteNames = []
    }

    // MARK: - 脚手架

    private func makeDefaults(_ tag: String) -> UserDefaults {
        let name = "SauryReminderSchedulerTests.\(tag).\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func day(_ year: Int, _ month: Int, _ d: Int, hour: Int = 9) -> Date {
        BillingMath.calendar.date(from: DateComponents(year: year, month: month, day: d, hour: hour))!
    }

    private func subscription(name: String = "Netflix", startDate: Date,
                              reminderDays: Int = 3,
                              remindersEnabled: Bool = true,
                              state: SubscriptionState = .autoRenew) -> Subscription {
        Subscription(name: name, priceMinorUnits: 4500, cycle: .monthly, state: state,
                     startDate: startDate, remindersEnabled: remindersEnabled,
                     reminderDays: reminderDays)
    }

    private func container(with subscriptions: [Subscription]) throws -> ModelContainer {
        let container = try ModelContainer(for: Schema(versionedSchema: SaurySchemaV4.self),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        subscriptions.forEach(context.insert)
        try context.save()
        return container
    }

    /// 总开关在偏好里默认是关的（提醒是用户开出来的），
    /// 走偏好这条路的重排测试必须自己把它打开，否则测的是「什么都没排」。
    private func makePreferences(_ tag: String) -> SubPreferences {
        let preferences = SubPreferences(defaults: makeDefaults(tag))
        preferences.notificationsEnabled = true
        return preferences
    }

    /// 等一个异步动作真的发生，不是「睡一下再断言」。超时就明确失败。
    private func waitUntil(_ label: String, timeout: TimeInterval = 3,
                           _ happening: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !happening() {
            if Date() > deadline {
                XCTFail("等不到：\(label)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - §5.2 对账落到系统

    /// 排进去的就是该排的那一条，内容签名跟着落进留痕。
    func testRefillAddsWhatShouldExistAndStoresItsSignature() async throws {
        let ledger = ReminderLedger(defaults: makeDefaults("add"))
        let delivery = FakeDelivery()
        let scheduler = SubscriptionScheduler(delivery: delivery, ledger: ledger)
        let subject = subscription(startDate: day(2026, 10, 20))

        let report = await scheduler.refill(subscriptions: [subject], hour: 9,
                                           enabled: true, now: day(2026, 10, 15, hour: 12))
        XCTAssertEqual(report.added, 1)
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(report.rejected, 0)
        let identifier = ReminderPlan.identifier(for: subject.id)
        XCTAssertEqual(delivery.pending, Set([identifier]))
        XCTAssertNotNil(ledger.signatures[identifier], "签名不落盘的话，重启之后没人记得那条写的是多少钱")
    }

    /// 改了金额：旧的那条要真的被撤掉，新的那条顶上。
    func testRepricingWithdrawsTheOldTextAndReadds() async throws {
        let ledger = ReminderLedger(defaults: makeDefaults("reprice"))
        let delivery = FakeDelivery()
        let scheduler = SubscriptionScheduler(delivery: delivery, ledger: ledger)
        let subject = subscription(startDate: day(2026, 10, 20))
        _ = await scheduler.refill(subscriptions: [subject], hour: 9, enabled: true,
                                   now: day(2026, 10, 15, hour: 12))
        XCTAssertEqual(delivery.adds.count, 1)

        subject.priceMinorUnits = 4900
        let report = await scheduler.refill(subscriptions: [subject], hour: 9, enabled: true,
                                            now: day(2026, 10, 15, hour: 12))
        XCTAssertEqual(report.removed, 1, "旧文案得先撤走")
        XCTAssertEqual(report.added, 1)
        XCTAssertEqual(delivery.lastRemovals, [ReminderPlan.identifier(for: subject.id)])
        XCTAssertTrue(delivery.adds.last?.body.contains("49.00") ?? false,
                      delivery.adds.last?.body ?? "")
    }

    /// 什么都没改的第二轮，一条都不该重排 —— 否则每次回前台都在把所有通知撤干净再排一遍。
    func testSecondRefillWithNothingChangedIsQuiet() async throws {
        let ledger = ReminderLedger(defaults: makeDefaults("quiet"))
        let delivery = FakeDelivery()
        let scheduler = SubscriptionScheduler(delivery: delivery, ledger: ledger)
        let subject = subscription(startDate: day(2026, 10, 20))
        _ = await scheduler.refill(subscriptions: [subject], hour: 9, enabled: true,
                                   now: day(2026, 10, 15, hour: 12))
        let report = await scheduler.refill(subscriptions: [subject], hour: 9, enabled: true,
                                            now: day(2026, 10, 15, hour: 12))
        XCTAssertEqual(report.added, 0)
        XCTAssertEqual(report.removed, 0)
    }

    /// 总开关关掉：一条都不留。
    func testDisabledRefillEmptiesTheSystem() async throws {
        let ledger = ReminderLedger(defaults: makeDefaults("disable"))
        let delivery = FakeDelivery()
        let scheduler = SubscriptionScheduler(delivery: delivery, ledger: ledger)
        let subject = subscription(startDate: day(2026, 10, 20))
        _ = await scheduler.refill(subscriptions: [subject], hour: 9, enabled: true,
                                   now: day(2026, 10, 15, hour: 12))
        let report = await scheduler.refill(subscriptions: [subject], hour: 9, enabled: false,
                                            now: day(2026, 10, 15, hour: 12))
        XCTAssertEqual(report.removed, 1)
        XCTAssertTrue(delivery.pending.isEmpty, "用户说别吵，就真的别吵")
        XCTAssertTrue(ledger.signatures.isEmpty, "撤干净之后签名表也该跟着空")
    }

    /// 系统拒收（没授权）不能写进签名表 —— 写进去下一轮就以为挂好了，永远不会再试。
    func testRejectedReminderIsNotRememberedAsScheduled() async throws {
        let defaults = makeDefaults("reject")
        let ledger = ReminderLedger(defaults: defaults)
        let delivery = FakeDelivery(accepts: false)
        let scheduler = SubscriptionScheduler(delivery: delivery, ledger: ledger)
        let subject = subscription(startDate: day(2026, 10, 20))

        let report = await scheduler.refill(subscriptions: [subject], hour: 9, enabled: true,
                                            now: day(2026, 10, 15, hour: 12))
        XCTAssertEqual(report.added, 0)
        XCTAssertEqual(report.rejected, 1, "拒收必须被数出来，不能算成功")
        XCTAssertTrue(ledger.signatures.isEmpty)

        let second = FakeDelivery()
        let retried = await SubscriptionScheduler(delivery: second, ledger: ledger)
            .refill(subscriptions: [subject], hour: 9, enabled: true, now: day(2026, 10, 15, hour: 12))
        XCTAssertEqual(retried.added, 1, "授权之后下一轮要能自己补上")
    }

    /// 没授权时系统「收了但不挂」—— 这条是模拟器实测出来的（`排入 3 / 挂着 0`）。
    /// 所以这一轮连 `add` 都不该调，结果要说成「拒收 1」，不能说「排入 1」。
    func testUnauthorizedDeliveryIsReportedAsNotScheduled() async throws {
        let defaults = makeDefaults("noauth")
        let ledger = ReminderLedger(defaults: defaults)
        let delivery = FakeDelivery(delivering: false)
        let scheduler = SubscriptionScheduler(delivery: delivery, ledger: ledger)
        let subject = subscription(startDate: day(2026, 10, 20))

        let report = await scheduler.refill(subscriptions: [subject], hour: 9, enabled: true,
                                            now: day(2026, 10, 15, hour: 12))
        XCTAssertEqual(report.added, 0, "没授权还报「排入」就是把用户当傻子")
        XCTAssertEqual(report.rejected, 1)
        XCTAssertTrue(delivery.adds.isEmpty, "系统不会挂的状态下就别再发请求了")
        XCTAssertTrue(ledger.signatures.isEmpty, "签名表不能记下根本没挂上的那条")
    }

    /// 授权状态的判断单独钉：`provisional`（静默投递）也算能投，
    /// 这一条如果判错，整个提醒功能会在「明明能提醒」时被自己关掉。
    func testOnlyNonDeliverableAuthorizationBlocksScheduling() {
        XCTAssertFalse(SubscriptionScheduler.deliversReminders(under: .notDetermined))
        XCTAssertFalse(SubscriptionScheduler.deliversReminders(under: .denied))
        XCTAssertTrue(SubscriptionScheduler.deliversReminders(under: .authorized))
        XCTAssertTrue(SubscriptionScheduler.deliversReminders(under: .provisional))
    }

    /// 超出条数上限的那几条要在结果里说出来，界面上和日志里才有据可查。
    func testCapacityOverflowIsReportedNotSilenced() async throws {
        let ledger = ReminderLedger(defaults: makeDefaults("capacity"))
        let delivery = FakeDelivery()
        let scheduler = SubscriptionScheduler(delivery: delivery, ledger: ledger)
        let subjects = (0..<60).map { index in
            subscription(name: "订阅\(index)",
                         startDate: BillingMath.calendar.date(byAdding: .day, value: index,
                                                              to: day(2026, 10, 1))!)
        }
        let report = await scheduler.refill(subscriptions: subjects, hour: 9, enabled: true,
                                            now: day(2026, 10, 1, hour: 0))
        XCTAssertEqual(report.added, ReminderPlan.capacity)
        XCTAssertEqual(report.droppedByCapacity, 60 - ReminderPlan.capacity)
    }

    /// 不属于这一族的标识（小组件、预览）一条都不许动。
    func testForeignIdentifiersAreLeftAlone() async throws {
        let ledger = ReminderLedger(defaults: makeDefaults("foreign"))
        let delivery = FakeDelivery(preexisting: [SubscriptionScheduler.previewIdentifier, "widget.refresh"])
        let scheduler = SubscriptionScheduler(delivery: delivery, ledger: ledger)
        let report = await scheduler.refill(subscriptions: [], hour: 9, enabled: true,
                                            now: day(2026, 10, 15, hour: 12))
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(delivery.pending, Set([SubscriptionScheduler.previewIdentifier, "widget.refresh"]))
    }

    // MARK: - §5.4 三个快捷入口

    /// 每条通知都读得出意图：查看、稍后、本期不再。读不出订阅身份的就什么都不做。
    func testNotificationTapsMapOntoIntentions() {
        let id = UUID()
        let charge = String(Int(day(2026, 10, 20).timeIntervalSince1970))
        let userInfo: [AnyHashable: Any] = ["subscriptionID": id.uuidString, "chargeDate": charge]
        XCTAssertEqual(ReminderActions.intent(actionIdentifier: ReminderActions.viewIdentifier, userInfo: userInfo),
                       .open(id))
        XCTAssertEqual(ReminderActions.intent(actionIdentifier: "", userInfo: userInfo), .open(id),
                       "点开通知本身默认就是「查看订阅」")
        XCTAssertEqual(ReminderActions.intent(actionIdentifier: ReminderActions.snoozeIdentifier, userInfo: userInfo),
                       .snooze(subscriptionID: id, chargeDate: day(2026, 10, 20)))
        XCTAssertEqual(ReminderActions.intent(actionIdentifier: ReminderActions.doneIdentifier, userInfo: userInfo),
                       .acknowledge(subscriptionID: id, chargeDate: day(2026, 10, 20)))
        XCTAssertEqual(ReminderActions.intent(actionIdentifier: ReminderActions.snoozeIdentifier,
                                              userInfo: ["somethingElse": "x"]), .ignore)
        XCTAssertEqual(ReminderActions.intent(actionIdentifier: ReminderActions.doneIdentifier,
                                              userInfo: ["subscriptionID": "不是 UUID"]), .ignore)
    }

    /// 「稍后提醒」：留痕写进去，重排只挂那一条 snooze，正常那条不再重复吵。
    func testSnoozeReplacesTheNormalReminderThroughTheSamePath() async throws {
        let ledger = ReminderLedger(defaults: makeDefaults("snooze"))
        let delivery = FakeDelivery()
        let scheduler = SubscriptionScheduler(delivery: delivery, ledger: ledger)
        let subject = subscription(startDate: day(2026, 10, 20))
        let container = try container(with: [subject])
        let preferences = makePreferences("snooze-prefs")
        // 和「本期不再提醒」那条同一个讲究：现在时刻要早于这一期的提醒触发点（10-17 09:00），
        // 否则第一轮排的根本不是 10-20 这一期，「同一期只留一条」就成了空话。
        let now = day(2026, 10, 15, hour: 12)

        _ = await scheduler.refill(subscriptions: [subject], hour: 9, enabled: true, now: now)
        XCTAssertEqual(delivery.pending, Set([ReminderPlan.identifier(for: subject.id)]))

        let outcome = ReminderInteraction.handle(.snooze(subscriptionID: subject.id, chargeDate: day(2026, 10, 20)),
                                                 preferences: preferences, scheduler: scheduler,
                                                 ledger: ledger, container: container, now: now)
        XCTAssertEqual(outcome, "已推后 1 小时")
        let snoozeIdentifier = ReminderPlan.identifier(for: subject.id, kind: .snooze)
        try await waitUntil("snooze 之后完成重排") { delivery.pending.contains(snoozeIdentifier) }
        XCTAssertEqual(delivery.pending, Set([snoozeIdentifier]), "同一期只留一条，正常那条不能再吵")
        XCTAssertEqual(delivery.adds.last?.fireAt, now.addingTimeInterval(ReminderActions.snoozeInterval),
                       "推的是 1 小时之后，不是随手一个时间")
        XCTAssertEqual(delivery.adds.last?.body.contains("10月20日"), true,
                       "延后提醒不改属于哪一期：" + (delivery.adds.last?.body ?? ""))
    }

    /// 「本期不再提醒」：撤的是这一笔，下一期照常排。
    func testAcknowledgementWithdrawsThisPeriodAndKeepsNextOne() async throws {
        let ledger = ReminderLedger(defaults: makeDefaults("acknowledge"))
        let delivery = FakeDelivery()
        let scheduler = SubscriptionScheduler(delivery: delivery, ledger: ledger)
        let subject = subscription(startDate: day(2026, 10, 20))
        let container = try container(with: [subject])
        // 现在时刻必须**早于**这一期的提醒触发点（10-20 往前推 3 天、9 点整 = 10-17 09:00）：
        // 那一刻已经过了的话，`ReminderPlan` 按 §5.3 直接推到下一期，
        // 这个测试就变成「确认一个本来就没排上的期次」，什么都没证明。
        let now = day(2026, 10, 15, hour: 12)

        _ = await scheduler.refill(subscriptions: [subject], hour: 9, enabled: true, now: now)
        // 排上的这一期按「哪一天」对，不按瞬间对：计划里的扣费日是那天 0 点，
        // day() 这个脚手架给的是那天 9 点，比时刻只会比出脚手架自己的偏移。
        XCTAssertTrue(BillingMath.calendar.isDate(delivery.adds.last?.chargeDate ?? .distantPast,
                                                  inSameDayAs: day(2026, 10, 20)),
                      "先要让这一期真的排上")
        XCTAssertEqual(delivery.adds.last?.body.contains("10月20日"), true)

        let outcome = ReminderInteraction.handle(.acknowledge(subscriptionID: subject.id,
                                                              chargeDate: day(2026, 10, 20)),
                                                 preferences: makePreferences("ack-prefs"),
                                                 scheduler: scheduler, ledger: ledger,
                                                 container: container, now: now)
        XCTAssertEqual(outcome, "本期不再提醒")
        XCTAssertTrue(ledger.isAcknowledged(subscriptionID: subject.id, chargeDate: day(2026, 10, 20)),
                      "痕迹不落盘的话，下次冷启动这条又会弹出来")
        // 排上去的换成下一期（11 月 20 日），这一期不再出现。
        try await waitUntil("换成下一期") { (delivery.adds.last?.chargeDate ?? .distantPast) > self.day(2026, 10, 20) }
        XCTAssertEqual(BillingMath.calendar.component(.month, from: delivery.adds.last?.chargeDate ?? .distantPast), 11,
                       "撤的是这一笔，不是这条订阅")
    }

    /// 库还没开起来的时候按了「稍后提醒」：留痕照样写，界面不能假装重排过了。
    func testSnoozeKeepsItsTraceEvenWithoutAContainer() {
        let ledger = ReminderLedger(defaults: makeDefaults("nocontainer"))
        let subject = subscription(startDate: day(2026, 10, 20))
        _ = ReminderInteraction.handle(.snooze(subscriptionID: subject.id, chargeDate: day(2026, 10, 20)),
                                       preferences: makePreferences("nocontainer-prefs"),
                                       scheduler: SubscriptionScheduler(delivery: FakeDelivery(), ledger: ledger),
                                       ledger: ledger, container: nil,
                                       now: day(2026, 10, 17, hour: 10))
        XCTAssertNotNil(ledger.pendingSnooze(for: subject.id, now: day(2026, 10, 17, hour: 10)),
                        "下一次真的重排要照这笔执行，不能把它丢了")
    }

    // MARK: - §5.4 「查看订阅」的交接

    /// 冷启动那一下根视图还没挂监听：点击必须排队等它来取，而且先进先出。
    ///
    /// 这里用的是自己的实例，不是 `ReminderNavigation.shared`：跑测试时宿主 App 的
    /// RootView 是活的，`request` 里那句广播会**同步**走到它的监听上，把刚存进去的点击
    /// 当场取走 —— 于是「按顺序交接」在全局那一份上根本观察不到。队列逻辑是同一份代码。
    func testNavigationQueueHandsOffInOrder() throws {
        let navigation = ReminderNavigation()
        let first = UUID()
        let second = UUID()
        navigation.request(first)
        navigation.request(second)
        XCTAssertEqual(navigation.consume(), first)
        XCTAssertEqual(navigation.consume(), second)
        XCTAssertNil(navigation.consume())
    }

    /// 点通知跳进来只有编号。编号在库里找不到就是找不到 —— 不能打开一条不相干的订阅充数。
    func testNavigationCarriesOnlyTheIdentifier() throws {
        let navigation = ReminderNavigation()
        let kept = subscription(name: "还在", startDate: day(2026, 10, 20))
        let gone = subscription(name: "已删", startDate: day(2026, 10, 20))
        let container = try container(with: [kept, gone])
        let context = ModelContext(container)
        let doomed = try XCTUnwrap(context.fetch(FetchDescriptor<Subscription>()).first { $0.name == "已删" })
        context.delete(doomed)
        try context.save()

        navigation.request(gone.id)
        let requested = try XCTUnwrap(navigation.consume())
        let remaining = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertFalse(remaining.contains { $0.id == requested }, "界面上要能说「这条订阅在本机已经找不到了」")
        XCTAssertEqual(remaining.map(\.name), ["还在"])
    }

    /// 三个动作的标识都是我们自己的那一族，注册和分发用的是同一份常量。
    /// 动作没注册就不会出现在通知上 —— 那件事只有真机看得见，这里先钉住常量别写岔。
    func testActionIdentifiersAreStable() {
        XCTAssertEqual(ReminderActions.viewIdentifier, "saury.reminder.action.view")
        XCTAssertEqual(ReminderActions.snoozeIdentifier, "saury.reminder.action.snooze")
        XCTAssertEqual(ReminderActions.doneIdentifier, "saury.reminder.action.done")
        XCTAssertTrue(ReminderActions.categoryIdentifier.hasPrefix("saury."))
    }
}

/// 投递假件：把「系统里此刻挂着什么」记在一个集合里，其余照真实现走。
/// `delivering: false` 演没授权那一种（实测：系统不报错，但一条都不挂）；
/// `accepts: false` 演超载 / 真报错那一种：拒绝必须是拒绝，不能算成功。
@MainActor
final class FakeDelivery: ReminderDelivery {
    private(set) var pending: Set<String>
    private(set) var adds: [ReminderPlan.Desired] = []
    private(set) var lastRemovals: [String] = []
    private let accepts: Bool
    private let delivering: Bool

    init(accepts: Bool = true, delivering: Bool = true, preexisting: [String] = []) {
        self.accepts = accepts
        self.delivering = delivering
        self.pending = Set(preexisting)
    }

    func pendingIdentifiers() async -> Set<String> {
        pending.filter(ReminderPlan.isReminderIdentifier(_:))
    }

    func canDeliver() async -> Bool { delivering }

    @discardableResult
    func add(_ reminder: ReminderPlan.Desired) async -> Bool {
        guard accepts else { return false }
        adds.append(reminder)
        pending.insert(reminder.identifier)
        return true
    }

    func remove(_ identifiers: [String]) async {
        lastRemovals = identifiers
        identifiers.forEach { pending.remove($0) }
    }
}
