import XCTest
@testable import Saury

/// 任务书 §5 的提醒规则，全在 `ReminderPlan` 这一层算，所以这一层能逐条钉住。
///
/// 每一条都喂一个**确定的** `now` 和一套**指定的**历法，不拿 `Date()` 碰运气：
/// 月末、闰年、跨年、夏令时这些日子只在特定日期才存在，用「今天」写出来的测试
/// 一年里只有几天真的测到东西。
///
/// # 这里测不到什么
///
/// `UNUserNotificationCenter` 到底会不会响、通知中心里的条数上限是不是真的 64，
/// 只有真机能证明。这一层保证的是「该排哪几条、该撤哪几条、文案写什么」。
/// 系统那一侧的行为在 `Docs/EON_QA.md` 里单独按「需真机验收」记。
@MainActor
final class ReminderPlanTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDownWithError() throws {
        for name in suiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        suiteNames = []
    }

    // MARK: - 脚手架

    private var calendar: Calendar { BillingMath.calendar }

    private func day(_ year: Int, _ month: Int, _ d: Int, hour: Int = 9,
                     calendar: Calendar = BillingMath.calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: d, hour: hour))!
    }

    private func calendar(for zone: String) -> Calendar {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = TimeZone(identifier: zone) ?? .current
        return local
    }

    private func makeLedger() -> ReminderLedger {
        let name = "SauryReminderPlanTests.\(UUID().uuidString)"
        suiteNames.append(name)
        return ReminderLedger(defaults: UserDefaults(suiteName: name)!)
    }

    private func subscription(name: String = "Netflix",
                              cycle: BillingCycle = .monthly,
                              startDate: Date,
                              priceMinorUnits: Int = 4500,
                              currencyCode: String = "CNY",
                              state: SubscriptionState = .autoRenew,
                              remindersEnabled: Bool = true,
                              reminderDays: Int = 3,
                              customMonths: Int = 2,
                              endDate: Date? = nil) -> Subscription {
        Subscription(name: name,
                     priceMinorUnits: priceMinorUnits,
                     currencyCode: currencyCode,
                     cycle: cycle,
                     customMonths: customMonths,
                     state: state,
                     startDate: startDate,
                     endDate: endDate,
                     remindersEnabled: remindersEnabled,
                     reminderDays: reminderDays)
    }

    private func plan(_ subscriptions: [Subscription],
                      globalEnabled: Bool = true,
                      hour: Int = 9,
                      ledger: ReminderLedger? = nil,
                      now: Date,
                      calendar: Calendar = BillingMath.calendar) -> ReminderPlan.Plan {
        ReminderPlan.desired(subscriptions: subscriptions,
                             globalEnabled: globalEnabled,
                             hour: hour,
                             ledger: ledger ?? makeLedger(),
                             now: now,
                             calendar: calendar)
    }

    private func single(_ subscription: Subscription,
                        hour: Int = 9,
                        now: Date,
                        ledger: ReminderLedger? = nil,
                        calendar: Calendar = BillingMath.calendar) -> ReminderPlan.Desired? {
        ReminderPlan.desired(for: subscription,
                             hour: hour,
                             ledger: ledger ?? makeLedger(),
                             now: now,
                             calendar: calendar)
    }

    // MARK: - §5.1 开关、天数与「提前 0 天」

    /// 开关说「不提醒」就是不提醒：一条通知都不排。
    func testSwitchOffProducesNoReminderEvenWithADayOffset() {
        let subject = subscription(startDate: day(2026, 10, 20), remindersEnabled: false, reminderDays: 3)
        XCTAssertNil(single(subject, now: day(2026, 10, 15, hour: 12)))
        XCTAssertTrue(plan([subject], now: day(2026, 10, 15, hour: 12)).entries.isEmpty)
    }

    /// 天数还在，只是变成 0 —— 那是「扣费当天提醒」，不是旧界面嘴上说的「不提醒」。
    func testZeroDaysMeansReminderOnTheChargeDayItself() {
        let subject = subscription(startDate: day(2026, 10, 20), remindersEnabled: true, reminderDays: 0)
        let reminder = single(subject, now: day(2026, 10, 15, hour: 12))
        guard let reminder else { return XCTFail("提前 0 天必须排得出当天那一条") }
        XCTAssertEqual(calendar.component(.month, from: reminder.fireAt), 10)
        XCTAssertEqual(calendar.component(.day, from: reminder.fireAt), 20, "当天 = 扣费那一天自己")
        XCTAssertEqual(calendar.component(.hour, from: reminder.fireAt), 9, "落在设置的那个整点")
        XCTAssertTrue(calendar.isDate(reminder.chargeDate, inSameDayAs: reminder.fireAt))
        XCTAssertTrue(reminder.body.contains("今天"), reminder.body)
    }

    /// 提前 N 天 = 扣费日往前数 N 个日历天，落在那个整点。
    func testNDaysBackLandsOnTheRightLocalHour() {
        let subject = subscription(startDate: day(2026, 10, 20), reminderDays: 3)
        let reminder = single(subject, now: day(2026, 10, 15, hour: 12))
        guard let reminder else { return XCTFail("该排出一条") }
        XCTAssertEqual(calendar.component(.day, from: reminder.fireAt), 17)
        XCTAssertEqual(calendar.component(.hour, from: reminder.fireAt), 9)
        XCTAssertEqual(calendar.component(.day, from: reminder.chargeDate), 20)
    }

    /// 总开关关掉就是清空，而不是「留着旧的等它自己响」。
    func testGlobalSwitchOffPlansNothing() {
        let subject = subscription(startDate: day(2026, 10, 20))
        XCTAssertTrue(plan([subject], globalEnabled: false, now: day(2026, 10, 15, hour: 12)).entries.isEmpty)
    }

    // MARK: - §5.2 稳定标识

    /// 标识只认订阅，不认日期。
    func testIdentifierIsStableAndCarriesNoDate() {
        let id = UUID()
        XCTAssertEqual(ReminderPlan.identifier(for: id), ReminderPlan.identifier(for: id))
        XCTAssertFalse(ReminderPlan.identifier(for: id).contains("2026"))
        XCTAssertNotEqual(ReminderPlan.identifier(for: id),
                          ReminderPlan.identifier(for: id, kind: .snooze),
                          "「稍后提醒」另开一条，才不会和正常那条互相顶掉")
    }

    /// 对账只清理我们这一族；设置页的预览故意不在这个族里。
    func testIdentifierFamilyExcludesPreview() {
        XCTAssertTrue(ReminderPlan.isReminderIdentifier(ReminderPlan.identifier(for: UUID())))
        XCTAssertTrue(ReminderPlan.isReminderIdentifier(ReminderPlan.identifier(for: UUID(), kind: .snooze)))
        XCTAssertFalse(ReminderPlan.isReminderIdentifier(SubscriptionScheduler.previewIdentifier),
                       "预览三秒后就响，下一轮重排把它撤掉就成了「用户按了没反应」")
    }

    /// 同一订阅换期还是同一条通知。上一版把日期写进标识，于是改了金额的那一期
    /// 是一条新通知，旧的那条谁都不认识、永远停在旧数字上。
    func testSameSubscriptionKeepsOneIdentifierAcrossPeriods() {
        let subject = subscription(startDate: day(2026, 10, 20), reminderDays: 0)
        let october = single(subject, now: day(2026, 10, 1))
        let november = single(subject, now: day(2026, 10, 21))
        XCTAssertNotNil(october)
        XCTAssertNotNil(november)
        XCTAssertEqual(october?.identifier, november?.identifier)
        XCTAssertNotEqual(october?.signature, november?.signature, "同一标识下日期变了，签名必须变")
    }

    // MARK: - §5.2 内容签名

    /// 签名要覆盖任务书点名的每一项：任何一项变了，都必须检得出来。
    func testSignatureChangesWithEveryNamedField() {
        let base = subscription(startDate: day(2026, 10, 20), reminderDays: 3)
        let charge = day(2026, 10, 20)
        let fire = day(2026, 10, 17)
        let baseline = ReminderPlan.signature(for: base, chargeDate: charge, fireAt: fire, kind: .upcoming)

        let renamed = subscription(name: "Netflix 标准版", startDate: day(2026, 10, 20), reminderDays: 3)
        XCTAssertNotEqual(ReminderPlan.signature(for: renamed, chargeDate: charge, fireAt: fire, kind: .upcoming), baseline, "名称")

        let repriced = subscription(startDate: day(2026, 10, 20), priceMinorUnits: 4900, reminderDays: 3)
        XCTAssertNotEqual(ReminderPlan.signature(for: repriced, chargeDate: charge, fireAt: fire, kind: .upcoming), baseline, "金额")

        let recurrency = subscription(startDate: day(2026, 10, 20), currencyCode: "USD", reminderDays: 3)
        XCTAssertNotEqual(ReminderPlan.signature(for: recurrency, chargeDate: charge, fireAt: fire, kind: .upcoming), baseline, "币种")

        let manual = subscription(startDate: day(2026, 10, 20), state: .manualRenew, reminderDays: 3)
        XCTAssertNotEqual(ReminderPlan.signature(for: manual, chargeDate: charge, fireAt: fire, kind: .upcoming), baseline, "状态")

        let otherChargeDay = subscription(startDate: day(2026, 10, 21), reminderDays: 3)
        XCTAssertNotEqual(ReminderPlan.signature(for: otherChargeDay, chargeDate: day(2026, 10, 21),
                                                 fireAt: fire, kind: .upcoming), baseline, "实际扣费日")

        XCTAssertNotEqual(ReminderPlan.signature(for: base, chargeDate: charge,
                                                 fireAt: day(2026, 10, 17, hour: 20), kind: .upcoming), baseline, "提醒时刻")

        let otherOffset = subscription(startDate: day(2026, 10, 20), reminderDays: 5)
        XCTAssertNotEqual(ReminderPlan.signature(for: otherOffset, chargeDate: charge, fireAt: fire, kind: .upcoming), baseline, "提前天数")

        let switchedOff = subscription(startDate: day(2026, 10, 20), remindersEnabled: false, reminderDays: 3)
        XCTAssertNotEqual(ReminderPlan.signature(for: switchedOff, chargeDate: charge, fireAt: fire, kind: .upcoming), baseline, "提醒开关")

        XCTAssertNotEqual(ReminderPlan.signature(for: base, chargeDate: charge, fireAt: fire, kind: .snooze), baseline, "稍后提醒是另一条")

        // 反过来也得成立：什么都没变，签名就是同一个。
        // 不然每轮重排都把全部提醒判成「内容变了」，撤干净再排一遍 —— 那是自己造噪音。
        XCTAssertEqual(ReminderPlan.signature(for: base, chargeDate: charge, fireAt: fire, kind: .upcoming),
                       baseline, "同样的输入必须算出同样的签名，不然对账每次都判定成变了")
    }

    /// 签名认的是「几月几日几点」，不是那一刻的绝对时间：出国一趟之后
    /// 同一期还是同一签名，不该整批重排。
    func testSignatureFollowsNominalDatesNotTheDeviceTimeZone() {
        let subject = subscription(startDate: day(2026, 10, 20), reminderDays: 3)
        let shanghai = calendar(for: "Asia/Shanghai")
        let losAngeles = calendar(for: "America/Los_Angeles")
        let inShanghai = ReminderPlan.signature(
            for: subject, chargeDate: day(2026, 10, 20, calendar: shanghai),
            fireAt: day(2026, 10, 17, calendar: shanghai), kind: .upcoming, calendar: shanghai)
        let inLosAngeles = ReminderPlan.signature(
            for: subject, chargeDate: day(2026, 10, 20, calendar: losAngeles),
            fireAt: day(2026, 10, 17, calendar: losAngeles), kind: .upcoming, calendar: losAngeles)
        XCTAssertEqual(inShanghai, inLosAngeles)
    }

    // MARK: - §5.2 对账：撤与排

    /// 内容签名和挂着的那条一致 —— 什么都不做。
    /// 少了这条判据，每次回前台都会把所有提醒全撤再全排。
    func testUnchangedSignatureAddsAndRemovesNothing() {
        let reminder = single(subscription(startDate: day(2026, 10, 20)), now: day(2026, 10, 15, hour: 12))!
        let result = ReminderPlan.reconcile(desired: [reminder],
                                            pendingIdentifiers: [reminder.identifier],
                                            storedSignatures: [reminder.identifier: reminder.signature])
        XCTAssertTrue(result.toAdd.isEmpty)
        XCTAssertTrue(result.toRemove.isEmpty)
        XCTAssertEqual(result.signatures[reminder.identifier], reminder.signature)
    }

    /// 同标识但内容变了：**先撤再排**。旧文案必须真的从通知中心消失，
    /// 而不是赌一句「同名覆盖应该会换吧」。
    func testChangedSignatureWithdrawsBeforeReadding() {
        let reminder = single(subscription(startDate: day(2026, 10, 20)), now: day(2026, 10, 15, hour: 12))!
        let result = ReminderPlan.reconcile(desired: [reminder],
                                            pendingIdentifiers: [reminder.identifier],
                                            storedSignatures: [reminder.identifier: "旧的、金额还是 39 元那一份"])
        XCTAssertEqual(result.toAdd.map(\.identifier), [reminder.identifier])
        XCTAssertEqual(result.toRemove, [reminder.identifier], "撤旧排新要留下能对账的痕迹")
    }

    /// 签名表丢了（卸载重装、清过偏好）但通知还挂着：内容不明，按重排处理。
    func testPendingWithoutStoredSignatureIsRequeued() {
        let reminder = single(subscription(startDate: day(2026, 10, 20)), now: day(2026, 10, 15, hour: 12))!
        let result = ReminderPlan.reconcile(desired: [reminder],
                                            pendingIdentifiers: [reminder.identifier],
                                            storedSignatures: [:])
        XCTAssertEqual(result.toAdd.count, 1)
        XCTAssertEqual(result.toRemove, [reminder.identifier])
    }

    /// 已经不需要的标识（关掉的、删掉的、被条数上限挤掉的）一并撤掉，签名表跟着清。
    func testStalePendingIdentifiersAreWithdrawnAndPruned() {
        let reminder = single(subscription(startDate: day(2026, 10, 20)), now: day(2026, 10, 15, hour: 12))!
        let ghost = ReminderPlan.identifier(for: UUID())
        let result = ReminderPlan.reconcile(desired: [reminder],
                                            pendingIdentifiers: [reminder.identifier, ghost],
                                            storedSignatures: [reminder.identifier: reminder.signature,
                                                               ghost: "x"])
        XCTAssertEqual(result.toRemove, [ghost])
        XCTAssertEqual(Set(result.signatures.keys), Set([reminder.identifier]), "签名表不能越积越脏")
    }

    // MARK: - §5.2 条数上限

    /// 系统最多挂 64 条，留出余量按 56 算；超出的按「离现在最近」优先，
    /// 并且**必须把挤掉的条数说出来** —— 不说，日志里就只剩「提醒已排好」这句假话。
    func testCapacityKeepsTheNearestAndReportsTheRest() {
        let now = day(2026, 10, 1, hour: 0)
        let subjects = (0..<60).map { index -> Subscription in
            let start = calendar.date(byAdding: .day, value: index, to: day(2026, 10, 1))!
            return subscription(name: "订阅\(index)", startDate: start, reminderDays: 0)
        }
        let result = plan(subjects, now: now)
        XCTAssertEqual(result.entries.count, ReminderPlan.capacity)
        XCTAssertEqual(result.droppedByCapacity, 60 - ReminderPlan.capacity)
        XCTAssertEqual(result.entries.first?.name, "订阅0")
        XCTAssertEqual(result.entries.last?.name, "订阅\(ReminderPlan.capacity - 1)")
        let kept = Set(result.entries.map(\.name))
        XCTAssertFalse(kept.contains("订阅59"), "被挤掉的必须是最远的那几条")
        XCTAssertFalse(kept.contains("订阅56"), "被挤掉的必须是最远的那几条")
    }

    // MARK: - §5.3 日期边界

    /// 1 月 31 日的月付：2 月钳到 28 日，3 月要回到 31 日 —— 锚点跟着开始日走，不跟着当期走。
    func testMonthEndAnchorSurvivesFebruary() {
        let subject = subscription(startDate: day(2026, 1, 31), reminderDays: 3)
        let february = single(subject, now: day(2026, 2, 1, hour: 12))
        XCTAssertEqual(calendar.component(.month, from: february?.chargeDate ?? .distantPast), 2)
        XCTAssertEqual(calendar.component(.day, from: february?.chargeDate ?? .distantPast), 28)
        XCTAssertEqual(calendar.component(.day, from: february?.fireAt ?? .distantPast), 25)

        // 2 月这一期已经来不及了（现在 2 月 26 日，触发日 2 月 25 日过了）——
        // 往后推的第一期是 3 月 31 日，不是 3 月 28 日。
        let march = single(subject, now: day(2026, 2, 26, hour: 12))
        XCTAssertEqual(calendar.component(.month, from: march?.chargeDate ?? .distantPast), 3)
        XCTAssertEqual(calendar.component(.day, from: march?.chargeDate ?? .distantPast), 31,
                       "锚点日不能跟着被钳过的那一期走")
    }

    /// 2 月 29 日的年付：平年钳到 28 日，闰年回到 29 日。
    func testLeapDayAnnualClampsAndReturns() {
        let subject = subscription(cycle: .yearly, startDate: day(2024, 2, 29), reminderDays: 3)
        let flat = single(subject, now: day(2025, 1, 1, hour: 12))
        XCTAssertEqual(calendar.component(.year, from: flat?.chargeDate ?? .distantPast), 2025)
        XCTAssertEqual(calendar.component(.day, from: flat?.chargeDate ?? .distantPast), 28)

        let leap = single(subject, now: day(2028, 1, 1, hour: 12))
        XCTAssertEqual(calendar.component(.year, from: leap?.chargeDate ?? .distantPast), 2028)
        XCTAssertEqual(calendar.component(.month, from: leap?.chargeDate ?? .distantPast), 2)
        XCTAssertEqual(calendar.component(.day, from: leap?.chargeDate ?? .distantPast), 29)
    }

    /// 年末跨到次年：提醒日期里的年号要一起翻。
    func testReminderCrossesTheYearBoundary() {
        let subject = subscription(startDate: day(2026, 12, 15), reminderDays: 3)
        let reminder = single(subject, now: day(2026, 12, 20, hour: 12))
        XCTAssertEqual(calendar.component(.year, from: reminder?.chargeDate ?? .distantPast), 2027)
        XCTAssertEqual(calendar.component(.month, from: reminder?.chargeDate ?? .distantPast), 1)
        XCTAssertEqual(calendar.component(.day, from: reminder?.chargeDate ?? .distantPast), 15)
        XCTAssertEqual(calendar.component(.year, from: reminder?.fireAt ?? .distantPast), 2027)
        XCTAssertEqual(calendar.component(.day, from: reminder?.fireAt ?? .distantPast), 12)
    }

    /// 结束日当天那一笔照常提醒；过了结束日就没有下一次。
    func testEndDateDayStillRemindsAndNothingAfterIt() {
        let subject = subscription(startDate: day(2026, 10, 20), reminderDays: 3,
                                   endDate: day(2026, 10, 20, hour: 0))
        XCTAssertNotNil(single(subject, now: day(2026, 10, 15, hour: 12)), "结束日当天还是这一期")
        XCTAssertNil(single(subject, now: day(2026, 10, 21, hour: 12)))
    }

    /// 停用的不排；重新启用照排。
    func testPausedSubscriptionIsSkippedAndResumeWorks() {
        let startDate = day(2026, 10, 20)
        XCTAssertNil(single(subscription(startDate: startDate, state: .inactive),
                            now: day(2026, 10, 15, hour: 12)))
        XCTAssertNotNil(single(subscription(startDate: startDate, state: .autoRenew),
                               now: day(2026, 10, 15, hour: 12)))
    }

    /// 手动续费一样要提醒 —— 它比自动续费更容易忘。
    func testManualRenewIsScheduledLikeAutoRenew() {
        XCTAssertNotNil(single(subscription(startDate: day(2026, 10, 20), state: .manualRenew),
                               now: day(2026, 10, 15, hour: 12)))
    }

    /// 归档、回收站里的都不算「在跟踪」。
    func testArchivedAndTrashedAreNotScheduled() {
        let archived = subscription(startDate: day(2026, 10, 20))
        archived.archivedAt = day(2026, 10, 1)
        XCTAssertNil(single(archived, now: day(2026, 10, 15, hour: 12)))
        let trashed = subscription(startDate: day(2026, 10, 20))
        trashed.deletedAt = day(2026, 10, 1)
        XCTAssertNil(single(trashed, now: day(2026, 10, 15, hour: 12)))
    }

    /// 一次性买断没有「下一次」。
    func testOneTimePurchaseIsNeverScheduled() {
        XCTAssertNil(single(subscription(cycle: .oneTime, startDate: day(2026, 10, 20)),
                            now: day(2026, 10, 15, hour: 12)))
    }

    /// 错过的那一期不补过去的通知，顺着周期推到下一期还来得及的。
    func testMissedReminderRollsForwardInsteadOfFiringInThePast() {
        let now = day(2026, 10, 19, hour: 10)
        let reminder = single(subscription(startDate: day(2026, 10, 20), reminderDays: 3), now: now)
        guard let reminder else { return XCTFail("该往后推出一期") }
        XCTAssertGreaterThanOrEqual(reminder.fireAt, now, "绝不排一条永远不会响的死请求")
        XCTAssertEqual(calendar.component(.month, from: reminder.chargeDate), 11,
                       "10 月这一期的 17 日已经过去，就该整期跳过")
        XCTAssertEqual(calendar.component(.day, from: reminder.fireAt), 17)
    }

    /// 长期没打开 App：从那时候起往后重新算，排出来的仍然是未来的时刻。
    func testLongAbsenceStillPlansAFutureReminder() {
        let now = day(2026, 10, 12, hour: 22)
        let reminder = single(subscription(startDate: day(2024, 3, 7), reminderDays: 3), now: now)
        guard let reminder else { return XCTFail("四年多的锚点也要推得出来") }
        XCTAssertGreaterThanOrEqual(reminder.fireAt, now)
        XCTAssertGreaterThan(reminder.chargeDate, day(2026, 10, 12, hour: 0))
    }

    /// 「本期不再提醒」只免这一期，下一期照常。
    func testAcknowledgementSkipsOnePeriodOnly() {
        let ledger = makeLedger()
        let subject = subscription(startDate: day(2026, 10, 20), reminderDays: 3)
        ledger.acknowledge(subscriptionID: subject.id, chargeDate: day(2026, 10, 20))
        let reminder = single(subject, now: day(2026, 10, 15, hour: 12), ledger: ledger)
        XCTAssertEqual(calendar.component(.month, from: reminder?.chargeDate ?? .distantPast), 11,
                       "10 月被用户撤掉了，11 月照排")
    }

    /// 「稍后提醒」期间只挂那一条 snooze，正常那条不再重复吵。
    func testPendingSnoozeReplacesTheNormalReminder() {
        let ledger = makeLedger()
        let subject = subscription(startDate: day(2026, 10, 20), reminderDays: 3)
        let until = day(2026, 10, 17, hour: 15)
        ledger.snooze(subscriptionID: subject.id, chargeDate: day(2026, 10, 20), until: until)
        let reminder = single(subject, now: day(2026, 10, 17, hour: 10), ledger: ledger)
        XCTAssertEqual(reminder?.fireAt, until)
        XCTAssertEqual(reminder?.identifier, ReminderPlan.identifier(for: subject.id, kind: .snooze))
        XCTAssertEqual(reminder?.isSnoozed, true)
        XCTAssertEqual(calendar.component(.day, from: reminder?.chargeDate ?? .distantPast), 20,
                       "正文要写实际扣费日，snooze 不改属于哪一期")
    }

    /// snooze 到点之后回到正常口径（往后找第一期还来得及的）。
    func testExpiredSnoozeStopsWinning() {
        let ledger = makeLedger()
        let subject = subscription(startDate: day(2026, 10, 20), reminderDays: 3)
        ledger.snooze(subscriptionID: subject.id, chargeDate: day(2026, 10, 20),
                      until: day(2026, 10, 17, hour: 10))
        let reminder = single(subject, now: day(2026, 10, 17, hour: 12), ledger: ledger)
        XCTAssertNotNil(reminder)
        XCTAssertFalse(reminder?.isSnoozed ?? true, "已经响过的 snooze 不再占位")
        XCTAssertEqual(calendar.component(.month, from: reminder?.chargeDate ?? .distantPast), 11)
    }

    // MARK: - §5.3 夏令时与时区

    /// 跨夏令时结束的那一周：提醒仍然落在那一天的当地 9 点。
    ///
    /// 这一条钉的是「按固定 168 小时往前推」那种写法 —— 它会在换日之后
    /// 变成当地 8 点或 10 点。日历算法必须按当地日历天走。
    func testReminderKeepsItsLocalHourAcrossDaylightSaving() {
        let newyork = calendar(for: "America/New_York")
        // 2026 年 11 月 1 日美国夏令时结束。扣费 11 月 15 日，提前 7 天 = 11 月 8 日，落在换日之后。
        let subject = subscription(startDate: day(2026, 11, 15, calendar: newyork), reminderDays: 7)
        let reminder = single(subject, now: day(2026, 11, 1, hour: 12, calendar: newyork), calendar: newyork)
        guard let reminder else { return XCTFail("该排出一条") }
        XCTAssertEqual(newyork.component(.day, from: reminder.chargeDate), 15)
        XCTAssertEqual(newyork.component(.day, from: reminder.fireAt), 8)
        XCTAssertEqual(newyork.component(.hour, from: reminder.fireAt), 9,
                       "换日之后还是当地 9 点，不是推出来的 8 点或 10 点")
    }

    /// 换了时区，用户看到的还是「本地那一天、本地那个点」；日期不该跟着经度漂。
    func testReminderFollowsTheLocalCalendarAfterATimeZoneMove() {
        for zone in ["Asia/Shanghai", "America/Los_Angeles", "Europe/London"] {
            let local = calendar(for: zone)
            let subject = subscription(startDate: day(2026, 10, 20, calendar: local), reminderDays: 3)
            let reminder = single(subject, now: day(2026, 10, 10, hour: 12, calendar: local), calendar: local)
            guard let reminder else { return XCTFail("\(zone) 下该排出一条") }
            XCTAssertEqual(local.component(.day, from: reminder.chargeDate), 20, "\(zone) 扣费日漂了")
            XCTAssertEqual(local.component(.day, from: reminder.fireAt), 17, "\(zone) 触发日漂了")
            XCTAssertEqual(local.component(.hour, from: reminder.fireAt), 9, "\(zone) 触发时刻漂了")
        }
    }

    /// 提醒时刻本身可配：设置的那个整点就是落地的整点。
    func testConfiguredHourIsHonoured() {
        let reminder = single(subscription(startDate: day(2026, 10, 20)), hour: 21,
                              now: day(2026, 10, 15, hour: 12))
        XCTAssertEqual(calendar.component(.hour, from: reminder?.fireAt ?? .distantPast), 21)
    }

    // MARK: - §5.2 正文

    /// 正文写**实际扣费日**，不写「还有 N 天」。
    ///
    /// 上一版那个数是拿通知自己的触发日算的：排进去那天显示得对，
    /// 但用户在第 3 天看到的本该是「今天扣费」，实际看到的还是「还有 3 天」。
    func testBodyCarriesTheActualChargeDate() {
        let subject = subscription(name: "iCloud+", startDate: day(2026, 10, 20), reminderDays: 3)
        let reminder = single(subject, now: day(2026, 10, 15, hour: 12))!
        XCTAssertTrue(reminder.body.contains("10月20日"), reminder.body)
        XCTAssertFalse(reminder.body.contains("还有"), reminder.body)
    }

    /// 分摊过的订阅，正文报的是自己那一份，不是账单总额。
    func testBodyReportsMySharedPortion() {
        let subject = subscription(startDate: day(2026, 10, 20), priceMinorUnits: 4500, reminderDays: 3)
        subject.shareEnabled = true
        subject.shareHeadcount = 3
        subject.shareMode = .even
        let reminder = single(subject, now: day(2026, 10, 15, hour: 12))!
        XCTAssertTrue(reminder.body.contains("15.00"), reminder.body)
        XCTAssertFalse(reminder.body.contains("45.00"), reminder.body)
    }

    // MARK: - 留痕本身

    /// 「这一期处理过」按日历天记：换时区不该把已经撤掉的提醒放回来。
    func testAcknowledgementIsKeyedByNominalDate() {
        let ledger = makeLedger()
        let subject = subscription(startDate: day(2026, 10, 20), reminderDays: 3)
        let shanghai = calendar(for: "Asia/Shanghai")
        let reykjavik = calendar(for: "Atlantic/Reykjavik")
        ledger.acknowledge(subscriptionID: subject.id,
                           chargeDate: day(2026, 10, 20, calendar: shanghai), calendar: shanghai)
        XCTAssertTrue(ledger.isAcknowledged(subscriptionID: subject.id,
                                            chargeDate: day(2026, 10, 20, calendar: reykjavik),
                                            calendar: reykjavik),
                      "同一号（10 月 20 日）就该算同一期")
    }

    /// 只清过去的期次：还没到的那一期一次都不能动。
    func testPruningOnlyDropsExpiredPeriods() {
        let ledger = makeLedger()
        let subject = subscription(startDate: day(2026, 10, 20), reminderDays: 3)
        ledger.acknowledge(subscriptionID: subject.id, chargeDate: day(2026, 9, 20))
        ledger.acknowledge(subscriptionID: subject.id, chargeDate: day(2026, 10, 20))
        ledger.pruneExpired(now: day(2026, 10, 1))
        XCTAssertFalse(ledger.isAcknowledged(subscriptionID: subject.id, chargeDate: day(2026, 9, 20)))
        XCTAssertTrue(ledger.isAcknowledged(subscriptionID: subject.id, chargeDate: day(2026, 10, 20)))
    }

    /// 一条订阅的痕迹不能顺手把另一条也免掉。
    func testAcknowledgementDoesNotLeakAcrossSubscriptions() {
        let ledger = makeLedger()
        let first = subscription(name: "A", startDate: day(2026, 10, 20))
        let second = subscription(name: "B", startDate: day(2026, 10, 20))
        ledger.acknowledge(subscriptionID: first.id, chargeDate: day(2026, 10, 20))
        XCTAssertTrue(ledger.isAcknowledged(subscriptionID: first.id, chargeDate: day(2026, 10, 20)))
        XCTAssertFalse(ledger.isAcknowledged(subscriptionID: second.id, chargeDate: day(2026, 10, 20)))
    }
}
