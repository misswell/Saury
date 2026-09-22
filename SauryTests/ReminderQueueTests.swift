import XCTest
@testable import Saury

/// 通知队列（方案 §39–§42）的口径。这些判断全部放在 `ReminderQueue` 里，
/// 是因为 §90 要求的场景——超过 64 条、snooze、删除、改日期、归档、已用完、重启——
/// 必须能在单元测试里跑完，而不是靠人对着真机的通知中心数。
final class ReminderQueueTests: XCTestCase {
    private let calendar = ExpiryEngine.calendar
    private let reference = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 9))!
    private let hour = 9
    private let dayMinutes = 24 * 60

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: reference) ?? reference
    }

    private func makeItem(
        name: String = "牛奶",
        category: ExpiryCategory = .food,
        offset: Int = 3,
        reminders: [Int]? = nil,
        recurrence: ExpiryRecurrence = .none,
        state: ExpiryState = .active
    ) -> ExpiryItem {
        ExpiryItem(
            name: name, category: category, expiryDate: day(offset),
            recurrence: recurrence, reminderOffsets: reminders ?? [7 * dayMinutes, dayMinutes, 0],
            state: state
        )
    }

    private func pending(_ candidates: [ReminderQueue.Candidate]) -> [ReminderQueue.Pending] {
        candidates.map { ReminderQueue.Pending(identifier: $0.identifier, fireAt: $0.fireAt) }
    }

    private func queue(_ items: [ExpiryItem]) -> [ReminderQueue.Candidate] {
        ReminderQueue.candidates(for: items, now: reference, preferredHour: hour)
    }

    // MARK: - 标识符

    func testIdentifiersCarryTheItemAndSurviveRoundTrip() {
        let item = makeItem()
        let expiry = NotificationIdentifier.expiry(itemID: item.id, offset: dayMinutes)
        XCTAssertEqual(expiry, "saury.expiry.\(item.id.uuidString).1440")
        XCTAssertEqual(NotificationIdentifier.itemID(for: expiry), item.id)

        let snooze = NotificationIdentifier.snooze(itemID: item.id)
        XCTAssertTrue(NotificationIdentifier.isSnooze(snooze))
        XCTAssertFalse(NotificationIdentifier.isExpiry(snooze))
        XCTAssertEqual(NotificationIdentifier.itemID(for: snooze), item.id)
        XCTAssertNotEqual(snooze, NotificationIdentifier.snooze(itemID: item.id), "两次推迟是两条通知")
    }

    func testLegacyIdentifiersAreRecognised() {
        XCTAssertTrue(NotificationIdentifier.isLegacy("qijian.renewal.A.B"))
        XCTAssertTrue(NotificationIdentifier.isLegacy("qijian.snooze.A"))
        XCTAssertFalse(NotificationIdentifier.isLegacy(NotificationIdentifier.expiry(itemID: makeItem().id, offset: 0)))
    }

    // MARK: - 候选

    func testRemindersThatAlreadyPassedNeverEnterTheQueue() {
        // 提前 30 天和 7 天都已经过去，只剩明天和当天。
        let candidates = queue([makeItem(offset: 3, reminders: [30 * dayMinutes, 7 * dayMinutes, dayMinutes, 0])])
        XCTAssertEqual(candidates.map(\.offset), [dayMinutes, 0])
    }

    func testTheDayItselfQueuesOnlyWhenThatTimeIsStillAhead() {
        // 到期日就是今天：当天的 09:00 与参考时刻重合，来不及排，但明天的还没到。
        XCTAssertTrue(queue([makeItem(offset: 0, reminders: [0])]).isEmpty)
        XCTAssertEqual(queue([makeItem(offset: 1, reminders: [0])]).count, 1)
    }

    func testFarFutureItemsWaitForTheNextRefill() {
        let candidates = queue([makeItem(offset: ReminderQueue.horizonDays + 30)])
        XCTAssertTrue(candidates.isEmpty)
    }

    func testQueueKeepsTheNearestRemindersAndLeavesRoomForSnooze() {
        let items = (1...30).map { makeItem(name: "物品 \($0)", offset: $0) }
        let candidates = queue(items)
        XCTAssertGreaterThan(candidates.count, ReminderQueue.regularCapacity)

        let chosen = ReminderQueue.scheduled(candidates)
        XCTAssertEqual(chosen.count, ReminderQueue.regularCapacity)
        let chosenIDs = Set(chosen.map(\.identifier))
        let dropped = candidates.filter { !chosenIDs.contains($0.identifier) }
        XCTAssertFalse(dropped.isEmpty)
        // 淘汰的必须全是更晚的那些，不能凭字典序碰运气。
        let latestKept = chosen.map(\.fireAt).max() ?? .distantFuture
        let earliestDropped = dropped.map(\.fireAt).min() ?? .distantPast
        XCTAssertLessThanOrEqual(latestKept, earliestDropped)
        // 普通提醒加 snooze 一起也不能顶破系统的上限。
        XCTAssertLessThanOrEqual(
            ReminderQueue.regularCapacity + ReminderQueue.snoozeCapacity, 64
        )
    }

    func testTheSameSlotOnlyQueuesOnce() {
        let item = makeItem(offset: 5)
        let chosen = ReminderQueue.scheduled(queue([item, item]))
        XCTAssertEqual(Set(chosen.map(\.identifier)).count, chosen.count, "重复标识符会让同一条通知排两次")
    }

    // MARK: - 差额重排

    func testRefillWithAnUnchangedQueueAddsNothing() {
        let items = [makeItem(name: "牛奶", offset: 3), makeItem(name: "药", category: .medicine, offset: 8)]
        let candidates = queue(items)
        let changes = ReminderQueue.delta(pending: pending(candidates), desired: candidates)
        // App 重启之后拿同一份数据再排一次，不该撤掉也不该新增任何一条。
        XCTAssertTrue(changes.toAdd.isEmpty)
        XCTAssertTrue(changes.toRemove.isEmpty)
        XCTAssertEqual(Set(changes.keeping), Set(candidates.map(\.identifier)))
    }

    func testSnoozeIsNeverTouchedByAReschedule() {
        let item = makeItem(offset: 5)
        let candidates = queue([item])
        let snooze = NotificationIdentifier.snooze(itemID: item.id)
        let changes = ReminderQueue.delta(
            pending: [ReminderQueue.Pending(identifier: snooze, fireAt: day(9))] + pending(candidates),
            desired: candidates
        )
        XCTAssertFalse(changes.toRemove.contains(snooze), "普通重排撤掉 snooze 就是方案 §40 要修的那个 bug")
    }

    func testEditingTheDateReplacesOnlyThatNotifications() {
        let item = makeItem(offset: 3)
        let old = queue([item])
        item.expiryDate = day(20)
        let fresh = queue([item])

        let changes = ReminderQueue.delta(pending: pending(old), desired: fresh)
        XCTAssertEqual(Set(changes.toAdd.map(\.identifier)), Set(fresh.map(\.identifier)))
        XCTAssertEqual(Set(changes.toRemove), Set(old.map(\.identifier)))
        XCTAssertTrue(changes.keeping.isEmpty)
    }

    func testHandledItemLosesItsReminders() {
        let kept = makeItem(name: "还在跟踪", offset: 5)
        let done = makeItem(name: "已经喝完", offset: 2)
        let queued = queue([kept, done])
        done.state = .consumed

        let changes = ReminderQueue.delta(pending: pending(queued), desired: queue([kept, done]))
        let doneIDs = Set(queued.filter { $0.item.id == done.id }.map(\.identifier))
        XCTAssertFalse(doneIDs.isEmpty)
        XCTAssertTrue(changes.toRemove.allSatisfy { doneIDs.contains($0) })
        XCTAssertEqual(Set(changes.toRemove), doneIDs)
        XCTAssertTrue(changes.keeping.allSatisfy { NotificationIdentifier.itemID(for: $0) == kept.id })
    }

    func testArchivingClearsEverythingForThatItem() {
        let item = makeItem(offset: 6)
        let queued = queue([item])
        item.state = .archived
        let changes = ReminderQueue.delta(pending: pending(queued), desired: queue([item]))
        XCTAssertEqual(Set(changes.toRemove), Set(queued.map(\.identifier)))
        XCTAssertTrue(changes.toAdd.isEmpty)
    }

    func testRefillFillsTheSlotsAFreedItemLeftBehind() {
        let items = (1...(ReminderQueue.regularCapacity + 4)).map { makeItem(name: "物品 \($0)", offset: $0) }
        let all = queue(items)
        let chosen = ReminderQueue.scheduled(all)
        let chosenIDs = Set(chosen.map(\.identifier))
        // 原本排不上的，按触发时间先后等着补位。
        let waiting = all.filter { !chosenIDs.contains($0.identifier) }.sorted { $0.fireAt < $1.fireAt }
        XCTAssertFalse(waiting.isEmpty)

        let handled = items[0]
        let freed = chosen.filter { $0.item.id == handled.id }
        XCTAssertFalse(freed.isEmpty)
        handled.state = .archived

        let changes = ReminderQueue.delta(pending: pending(chosen), desired: queue(items))
        XCTAssertEqual(Set(changes.toRemove), Set(freed.map(\.identifier)))
        XCTAssertEqual(changes.toAdd.count, changes.toRemove.count, "腾出几个位置就补几条")
        XCTAssertEqual(
            changes.toAdd.map(\.identifier),
            Array(waiting.prefix(changes.toRemove.count)).map(\.identifier),
            "补进来的必须是等得最久的那几条"
        )
    }

    func testLegacyEntriesAreClearedAndForeignOnesLeftAlone() {
        let item = makeItem(offset: 4)
        let candidates = queue([item])
        let legacy = "qijian.renewal.\(item.id.uuidString).0"
        let foreign = "com.example.other.thing"
        let changes = ReminderQueue.delta(
            pending: [
                ReminderQueue.Pending(identifier: legacy, fireAt: nil),
                ReminderQueue.Pending(identifier: foreign, fireAt: nil),
            ] + pending(candidates),
            desired: candidates
        )
        XCTAssertEqual(changes.toRemove, [legacy])
    }

    func testPendingWithoutAFireDateIsAlwaysRescheduled() {
        let item = makeItem(offset: 4)
        let candidates = queue([item])
        let changes = ReminderQueue.delta(
            pending: candidates.map { ReminderQueue.Pending(identifier: $0.identifier, fireAt: nil) },
            desired: candidates
        )
        // 旧版本排的通知没留下时刻，宁可重排一次也不能猜它是对的。
        XCTAssertTrue(changes.keeping.isEmpty)
        XCTAssertEqual(changes.toAdd.count, candidates.count)
        XCTAssertEqual(Set(changes.toRemove), Set(candidates.map(\.identifier)))
    }

    // MARK: - 通知按钮

    func testNotificationButtonsMatchTheInAppActions() {
        let food = makeItem(category: .food)
        XCTAssertEqual(ReminderCategory.actions(for: food), [.consumed, .discarded, .snoozed])

        let subscription = makeItem(name: "会员", category: .subscription, recurrence: .monthly)
        XCTAssertEqual(ReminderCategory.actions(for: subscription), [.renewed, .cancelled, .snoozed])

        let passport = makeItem(name: "护照", category: .document)
        XCTAssertEqual(ReminderCategory.actions(for: passport), [.snoozed])

        for action in ReminderCategory.actions(for: food) {
            XCTAssertEqual(ReminderCategory.action(for: ReminderCategory.actionIdentifier(action)), action)
        }
        XCTAssertNil(ReminderCategory.action(for: "com.apple.notification-action"))
        XCTAssertNotEqual(ReminderCategory.identifier(for: food), ReminderCategory.identifier(for: subscription))
    }

    func testButtonSetsAreKeyedSeparatelyWithinOneCategory() {
        let passport = makeItem(name: "护照", category: .document)
        let carCheck = makeItem(name: "车检", category: .document, recurrence: .yearly)
        XCTAssertEqual(ReminderCategory.actions(for: carCheck), [.renewed, .cancelled, .snoozed])
        XCTAssertNotEqual(
            ReminderCategory.identifier(for: passport),
            ReminderCategory.identifier(for: carCheck),
            "同一个分类下的两套按钮必须分开注册，否则先注册的那套会赢"
        )
    }

    func testButtonTitlesStayItemSpecific() {
        XCTAssertEqual(ExpiryAction.consumed.title(forCategory: .food), "吃完")
        XCTAssertEqual(ExpiryAction.consumed.title(forCategory: .medicine), "用完")
        XCTAssertEqual(ExpiryAction.renewed.title(forCategory: .subscription), "已续订")
        XCTAssertEqual(ExpiryAction.discarded.title(forCategory: .document), "已丢弃")
    }

    func testFireDateIsAlignedToTheMinuteTheSystemFiresOn() {
        let odd = day(3).addingTimeInterval(37)
        let rounded = ReminderQueue.rounded(odd, calendar: calendar)
        XCTAssertEqual(rounded, calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: odd)))
        XCTAssertEqual(rounded, ReminderQueue.rounded(rounded, calendar: calendar), "对齐必须幂等，否则每次 refill 都会重排")
    }
}
