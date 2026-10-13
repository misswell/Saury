import XCTest
import SwiftData
@testable import Saury

/// 任务书 §2.3：新增、编辑、删除、归档、恢复、调价、扣费都走同一个写库入口。
/// 这里逐条测的是「这个入口对用户的承诺」：
/// 连点两次不多出第二行、改坏了能撤销、不属于库的对象不许装作写成功、
/// 一次操作只广播一遍变更。
final class SubscriptionRepositoryTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Schema(versionedSchema: SaurySchemaV4.self),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func draft(_ name: String = "Netflix",
                       id: UUID = UUID(),
                       price: Int = 4500,
                       cycle: BillingCycle = .monthly) -> SubscriptionDraft {
        SubscriptionDraft(id: id, name: name, priceMinorUnits: price,
                          currencyCode: "CNY", cycle: cycle)
    }

    /// 数一遍这次操作往外广播了几次「数据变了」。
    /// 提醒队列、小组件和 iCloud 都挂在这个通知上，多播一次就是白排一遍队。
    @MainActor
    private func dataChanges(_ action: @MainActor () throws -> Void) rethrows -> Int {
        var count = 0
        let token = NotificationCenter.default.addObserver(
            forName: .sauryDataChanged, object: nil, queue: nil
        ) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        try action()
        return count
    }

    // MARK: - 新增与编辑

    /// 表单连点两次「保存」补的是同一行，不会记下两份钱。
    @MainActor
    func testRepeatedSaveWithSameDraftIDCreatesOneRow() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        let id = UUID()
        var second = draft(id: id)
        second.priceMinorUnits = 6800

        try repository.apply(draft(id: id))
        try repository.apply(second)

        let all = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertEqual(all.count, 1, "同一个草稿 id 提交两次只能有一行")
        XCTAssertEqual(all[0].priceMinorUnits, 6800, "第二次是覆盖这一行，不是再插一行")
    }

    /// 去重只认身份。同名两条是用户真的订了两份，悄悄合并就是丢数据。
    @MainActor
    func testSameNameDifferentDraftIsNotMerged() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        try repository.apply(draft("Netflix"))
        try repository.apply(draft("Netflix"))
        XCTAssertEqual(try context.fetch(FetchDescriptor<Subscription>()).count, 2)
    }

    /// 名字空着不许落库，也不许留下一半。
    @MainActor
    func testEmptyNameIsRejectedBeforeWriting() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        XCTAssertThrowsError(try repository.apply(draft("   "))) { error in
            XCTAssertEqual(error as? SubscriptionRepository.Failure, .nameRequired)
        }
        XCTAssertEqual(try context.fetch(FetchDescriptor<Subscription>()).count, 0)
    }

    /// 编辑不动身份：id 和创建时间保持原样，改的只是内容。
    @MainActor
    func testEditKeepsIdentityAndCreatedAt() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        let id = UUID()
        let created = try repository.apply(draft("旧名", id: id))
        let createdAt = created.createdAt

        var edit = draft("新名", id: id, price: 9900, cycle: .yearly)
        edit.plan = "标准版"
        edit.notes = "  和家人共用  "
        let edited = try repository.apply(edit)

        XCTAssertEqual(edited.id, id)
        XCTAssertEqual(edited.createdAt, createdAt, "编辑不该把创建时间刷成现在")
        XCTAssertEqual(edited.name, "新名")
        XCTAssertEqual(edited.priceMinorUnits, 9900)
        XCTAssertEqual(edited.cycle, .yearly)
        XCTAssertEqual(edited.notes, "和家人共用", "首尾空白进库前就清掉")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Subscription>()).count, 1)
    }

    /// 表单填了一半没保存，库里那条一个字都不能变 —— 「取消」才是无损的。
    @MainActor
    func testDraftChangesStayOutOfTheStoreUntilSaved() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        let stored = try repository.apply(draft("Netflix", price: 4500))

        var abandoned = SubscriptionDraft(id: stored.id, name: stored.name)
        abandoned.name = "改成别的了"
        abandoned.priceMinorUnits = 1
        _ = abandoned

        XCTAssertEqual(stored.name, "Netflix")
        XCTAssertEqual(stored.priceMinorUnits, 4500)
    }

    // MARK: - 置顶 / 归档 / 回收站

    /// 「撤销」回到的是改动前那一格：归档过 → 进回收站 → 撤销，仍在归档列表。
    @MainActor
    func testUndoAfterTrashReturnsToArchiveList() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        let subscription = try repository.apply(draft())

        try repository.archive(subscription)
        let beforeTrash = try repository.moveToTrash(subscription)
        XCTAssertNotNil(subscription.deletedAt)

        try repository.restore(beforeTrash)
        XCTAssertNil(subscription.deletedAt)
        XCTAssertNotNil(subscription.archivedAt, "撤销只清删除标记，不能顺手把它放回在用列表")
    }

    /// 撤销是按快照原样倒回去的，时间戳也必须是原来那个。
    @MainActor
    func testRestorePutsBackExactTimestamps() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        let pinnedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let subscription = try repository.apply(draft())
        subscription.pinnedAt = pinnedAt
        try repository.commit("测试：置顶")

        let snapshot = try repository.setPinned(subscription, false)
        XCTAssertNil(subscription.pinnedAt)

        try repository.restore(snapshot)
        XCTAssertEqual(subscription.pinnedAt, pinnedAt, "恢复置顶要保留原来的置顶时间")
    }

    /// 回收站是软删除：历史事件一条都不能跟着丢。
    @MainActor
    func testSoftDeleteKeepsEventHistory() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        let subscription = try repository.apply(draft())
        try repository.record(SubscriptionEventDraft(subscriptionID: subscription.id,
                                                     type: .charged, amountMinorUnits: 4500))
        try repository.record(SubscriptionEventDraft(subscriptionID: subscription.id,
                                                     type: .note, note: "续了年付"))

        try repository.moveToTrash(subscription)
        XCTAssertNotNil(subscription.deletedAt)
        XCTAssertEqual(repository.events(subscriptionID: subscription.id).count, 2)
    }

    @MainActor
    func testRestoreFromTrashKeepsArchivedRowArchived() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        let subscription = try repository.apply(draft())
        try repository.archive(subscription)
        try repository.moveToTrash(subscription)

        try repository.restoreFromTrash(subscription)
        XCTAssertNil(subscription.deletedAt)
        XCTAssertNotNil(subscription.archivedAt)
    }

    @MainActor
    func testUnarchiveBringsRowBackToUse() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        let subscription = try repository.apply(draft())
        try repository.archive(subscription)
        XCTAssertFalse(subscription.isTracked)

        try repository.unarchive(subscription)
        XCTAssertNil(subscription.archivedAt)
        XCTAssertTrue(subscription.isTracked)
    }

    // MARK: - 批量

    /// 批量一次落盘、一次广播；撤销整批回到各自原来的位置。
    @MainActor
    func testBatchArchiveIsOneCommitAndOneNotification() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        let a = try repository.apply(draft("A"))
        let b = try repository.apply(draft("B"))
        let pinned = try repository.apply(draft("C"))
        try repository.setPinned(pinned, true)

        var captured: [SubscriptionRepository.StatusSnapshot] = []
        let notifications = try dataChanges { captured = try repository.archive([a, b, pinned]) }
        XCTAssertEqual(notifications, 1, "批量归档只广播一遍，逐条广播会把提醒和小组件打成连环重绘")
        XCTAssertNotNil(a.archivedAt)
        XCTAssertNotNil(b.archivedAt)
        XCTAssertTrue(pinned.isPinned, "归档不该顺手把置顶抹掉")

        try repository.restore(captured)
        XCTAssertNil(a.archivedAt)
        XCTAssertNil(b.archivedAt)
        XCTAssertNil(pinned.archivedAt)
        XCTAssertTrue(pinned.isPinned, "整批撤销要把它原来置顶的样子也还回来")
    }

    @MainActor
    func testBatchUndoOfTrashRestoresEveryRow() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        let rows = try (1...3).map { try repository.apply(draft("订阅 \($0)")) }

        let snapshots = try repository.moveToTrash(rows)
        XCTAssertEqual(snapshots.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.deletedAt != nil })

        try repository.restore(snapshots)
        XCTAssertTrue(rows.allSatisfy { $0.deletedAt == nil })
        XCTAssertEqual(try context.fetch(FetchDescriptor<Subscription>()).count, 3)
    }

    // MARK: - 状态：停用与续费方式

    /// 「停用 → 撤销」回到的是原本那一种续费方式。
    /// 这条盯的是最容易顺手写出来的那个 bug：把「启用」实现成「改成自动续费」，
    /// 于是手动续费的那条被一次撤销悄悄改成了自动扣款。
    @MainActor
    func testUndoOfDisableReturnsTheOriginalRenewalMode() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        var original = draft()
        original.state = .manualRenew
        let subscription = try repository.apply(original)

        let before = try repository.setState(subscription, .inactive)
        XCTAssertEqual(subscription.state, .inactive)
        XCTAssertFalse(subscription.isTracked, "停用不该再进账本和提醒")

        try repository.restore(before)
        XCTAssertEqual(subscription.state, .manualRenew, "撤销要回到手动续费，不是猜一个自动续费")
        XCTAssertTrue(subscription.isTracked)
    }

    /// 批量改状态：一次落盘、一遍广播，撤销时各回各的原样 —— 三条原来并不一样。
    @MainActor
    func testBatchSetStateIsOneCommitAndUndoesToEachOriginal() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        var auto = draft("自动那条"); auto.state = .autoRenew
        var manual = draft("手动那条"); manual.state = .manualRenew
        var off = draft("停用的那条"); off.state = .inactive
        let rows = [try repository.apply(auto), try repository.apply(manual), try repository.apply(off)]

        var captured: [SubscriptionRepository.StatusSnapshot] = []
        let notifications = try dataChanges {
            captured = try repository.setState(rows, .inactive)
        }
        XCTAssertEqual(notifications, 1, "整批只广播一遍，不然提醒队列和小组件白重排三轮")
        XCTAssertEqual(captured.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.state == .inactive })

        try repository.restore(captured)
        XCTAssertEqual(rows[0].state, .autoRenew)
        XCTAssertEqual(rows[1].state, .manualRenew)
        XCTAssertEqual(rows[2].state, .inactive, "本来就是停用的那条，撤销后仍该是停用")
    }

    @MainActor
    func testSetStateRejectsDetachedRow() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        let stored = try repository.apply(draft("库里的"))
        let detached = Subscription(name: "预览里的")

        XCTAssertThrowsError(try repository.setState(detached, .inactive)) { error in
            XCTAssertEqual(error as? SubscriptionRepository.Failure, .notStored("预览里的"))
        }
        XCTAssertThrowsError(try repository.setState([stored, detached], .inactive))
        XCTAssertEqual(stored.state, .autoRenew, "整批里有一条不在库里，这条也不许动")
    }

    // MARK: - 批量恢复

    /// 批量从回收站捞回来：一次落盘，每条的删除凭据跟着作废。
    /// 凭据不撤的话，下一次同步会把它按进回收站 —— 用户刚刚明明点了「恢复」。
    @MainActor
    func testBatchRestoreFromTrashIsOneCommitAndPardonsEveryRow() throws {
        let context = ModelContext(try makeContainer())
        let suiteName = "saury.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let tombstones = SyncTombstoneLog(defaults: defaults)
        let repository = SubscriptionRepository(context: context, tombstones: tombstones)
        let rows = try (1...3).map { try repository.apply(draft("订阅 \($0)")) }
        try repository.moveToTrash(rows)
        XCTAssertTrue(rows.allSatisfy { tombstones.date(for: .subscription, name: $0.id.uuidString) == nil },
                      "软删除只清标记，不留死刑凭据")

        tombstones.record(kind: .subscription, name: rows[0].id.uuidString, at: Date())
        tombstones.record(kind: .subscription, name: rows[1].id.uuidString, at: Date())

        var captured: [SubscriptionRepository.StatusSnapshot] = []
        let notifications = try dataChanges {
            captured = try repository.restoreFromTrash(rows)
        }
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(captured.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.deletedAt == nil })
        XCTAssertNil(tombstones.date(for: .subscription, name: rows[0].id.uuidString))
        XCTAssertNil(tombstones.date(for: .subscription, name: rows[1].id.uuidString))

        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    func testBatchUnarchiveIsOneCommitAndKeepsOtherStatusFields() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        let a = try repository.apply(draft("A"))
        let b = try repository.apply(draft("B"))
        try repository.setPinned(b, true)
        var off = draft("C"); off.state = .inactive
        let c = try repository.apply(off)
        try repository.archive([a, b, c])

        var captured: [SubscriptionRepository.StatusSnapshot] = []
        let notifications = try dataChanges {
            captured = try repository.unarchive([a, b, c])
        }
        XCTAssertEqual(notifications, 1)
        XCTAssertNil(a.archivedAt)
        XCTAssertNil(b.archivedAt)
        XCTAssertNil(c.archivedAt)
        XCTAssertTrue(b.isPinned, "从归档回来不该把置顶一起冲掉")
        XCTAssertEqual(c.state, .inactive, "解归档只解归档，不替用户改续费方式")
        XCTAssertFalse(c.isTracked, "停用那条就算解了归档也仍然不进账本")

        try repository.restore(captured)
        XCTAssertNotNil(a.archivedAt, "整批撤销把它放回归档列表")
        XCTAssertNotNil(c.archivedAt)
    }

    // MARK: - 不属于库的对象

    /// 预览造出来的、别的 context 拿来的行，改了也落不了盘 —— 直接报错，不许当作成功。
    @MainActor
    func testDetachedSubscriptionIsRejected() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        let stored = try repository.apply(draft("库里的"))
        let detached = Subscription(name: "预览里的")

        XCTAssertThrowsError(try repository.archive(detached)) { error in
            XCTAssertEqual(error as? SubscriptionRepository.Failure, .notStored("预览里的"))
        }
        XCTAssertNil(detached.archivedAt, "报错之前不许先把界面改掉")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Subscription>()).count, 1)
        XCTAssertNil(stored.archivedAt)
    }

    @MainActor
    func testBatchRejectsWhenAnyRowIsNotStored() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        let stored = try repository.apply(draft("库里的"))
        XCTAssertThrowsError(try repository.moveToTrash([stored, Subscription(name: "预览里的")]))
        XCTAssertNil(stored.deletedAt, "整批里有一条不在库里，这条也不许动")
    }

    // MARK: - 彻底删除

    /// 删订阅必须连它的事件一起删：留下一堆没主人的扣费记录，
    /// 账本把它们当孤儿丢掉后，用户看到的累计支付就凭空少一块。
    @MainActor
    func testDeletePermanentlyRemovesItsEvents() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        let gone = try repository.apply(draft("要删的"))
        let kept = try repository.apply(draft("留下的"))
        try repository.record(SubscriptionEventDraft(subscriptionID: gone.id,
                                                    type: .charged, amountMinorUnits: 4500))
        try repository.record(SubscriptionEventDraft(subscriptionID: gone.id,
                                                    type: .note, note: "备注"))
        try repository.record(SubscriptionEventDraft(subscriptionID: kept.id,
                                                    type: .charged, amountMinorUnits: 990))

        try repository.deletePermanently(gone)

        XCTAssertNil(repository.subscription(id: gone.id))
        XCTAssertEqual(repository.events(subscriptionID: gone.id).count, 0)
        XCTAssertEqual(repository.events(subscriptionID: kept.id).count, 1, "别人的事件不能跟着遭殃")
        XCTAssertEqual(try context.fetch(FetchDescriptor<SubscriptionEvent>()).count, 1)
    }

    /// 整批彻底删除：一次落盘、一遍广播，订阅和它们的事件都留下凭据。
    /// 逐条删会广播 N 次，提醒队列和小组件就跟着重排 N 轮。
    @MainActor
    func testBatchDeletePermanentlyIsOneCommitAndTombstonesEverything() throws {
        let context = ModelContext(try makeContainer())
        let suiteName = "saury.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let tombstones = SyncTombstoneLog(defaults: defaults)
        let repository = SubscriptionRepository(context: context, tombstones: tombstones)
        let goneA = try repository.apply(draft("要删的 A"))
        let goneB = try repository.apply(draft("要删的 B"))
        let kept = try repository.apply(draft("留下的"))
        let eventsA = try (1...2).map {
            try repository.record(SubscriptionEventDraft(subscriptionID: goneA.id, type: .charged,
                                                         amountMinorUnits: 100 * $0))
        }
        let eventB = try repository.record(SubscriptionEventDraft(subscriptionID: goneB.id, type: .note))
        let keptEvent = try repository.record(SubscriptionEventDraft(subscriptionID: kept.id, type: .charged,
                                                                    amountMinorUnits: 990))

        let notifications = try dataChanges {
            try repository.deletePermanently([goneA, goneB])
        }
        XCTAssertEqual(notifications, 1)
        XCTAssertNil(repository.subscription(id: goneA.id))
        XCTAssertNil(repository.subscription(id: goneB.id))
        XCTAssertEqual(repository.events(subscriptionID: goneA.id).count, 0)
        XCTAssertEqual(repository.events(subscriptionID: goneB.id).count, 0)
        XCTAssertEqual(repository.events(subscriptionID: kept.id).map(\.id), [keptEvent.id],
                       "别人的事件不能跟着遭殃")

        for id in [goneA.id, goneB.id] {
            XCTAssertNotNil(tombstones.date(for: .subscription, name: id.uuidString),
                            "彻底删除必须留下凭据，否则别的设备那份会在下一次同步原样爬回来")
        }
        for event in eventsA + [eventB] {
            XCTAssertNotNil(tombstones.date(for: .event, name: event.id.uuidString))
        }
        XCTAssertNil(tombstones.date(for: .subscription, name: kept.id.uuidString))
        XCTAssertNil(tombstones.date(for: .event, name: keptEvent.id.uuidString))

        defaults.removePersistentDomain(forName: suiteName)
    }

    /// 整批里有一条不属于这个库：一条都不许动，也不能留下半张凭据。
    @MainActor
    func testBatchDeletePermanentlyRejectsDetachedRow() throws {
        let context = ModelContext(try makeContainer())
        let suiteName = "saury.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let tombstones = SyncTombstoneLog(defaults: defaults)
        let repository = SubscriptionRepository(context: context, tombstones: tombstones)
        let stored = try repository.apply(draft("库里的"))

        XCTAssertThrowsError(try repository.deletePermanently([stored, Subscription(name: "预览里的")]))
        XCTAssertNotNil(repository.subscription(id: stored.id))
        XCTAssertNil(tombstones.date(for: .subscription, name: stored.id.uuidString))

        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    func testWipeAllClearsBothTables() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        let subscription = try repository.apply(draft())
        try repository.record(SubscriptionEventDraft(subscriptionID: subscription.id,
                                                     type: .charged, amountMinorUnits: 4500))

        let notifications = try dataChanges { try repository.wipeAll() }
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Subscription>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SubscriptionEvent>()).count, 0)
    }

    // MARK: - 事件

    /// 同一份事件草稿交两遍只有一笔，改的是那一笔。
    @MainActor
    func testRecordingTheSameEventDraftTwiceKeepsOneRow() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        let subscription = try repository.apply(draft())
        let id = UUID()
        var again = SubscriptionEventDraft(id: id, subscriptionID: subscription.id,
                                           type: .charged, amountMinorUnits: 4500,
                                           currencyCode: "CNY")
        try repository.record(again)
        again.amountMinorUnits = 5000
        again.note = "  实付 50  "
        try repository.record(again)

        let events = repository.events(subscriptionID: subscription.id)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].amountMinorUnits, 5000)
        XCTAssertEqual(events[0].note, "实付 50")
        XCTAssertEqual(try context.fetch(FetchDescriptor<SubscriptionEvent>()).count, 1)
    }

    /// 调价是「改价 + 留痕」一次落盘：写成一半，后面的账全对不上。
    @MainActor
    func testPriceChangeWritesPriceAndEventTogether() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        let subscription = try repository.apply(draft(price: 4500))

        try repository.record(SubscriptionEventDraft(subscriptionID: subscription.id,
                                                    type: .priceChanged,
                                                    amountMinorUnits: 6800,
                                                    currencyCode: "CNY"))

        XCTAssertEqual(subscription.priceMinorUnits, 6800)
        XCTAssertEqual(repository.events(subscriptionID: subscription.id).count, 1)
        XCTAssertEqual(repository.subscription(id: subscription.id)?.priceMinorUnits, 6800,
                       "新价必须真的在库里，不只是界面上看着变了")
    }

    /// 调价没填金额时只留痕，不能把现价刷成 0。
    @MainActor
    func testPriceChangeWithoutAmountLeavesPriceAlone() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        let subscription = try repository.apply(draft(price: 4500))
        try repository.record(SubscriptionEventDraft(subscriptionID: subscription.id,
                                                     type: .priceChanged))
        XCTAssertEqual(subscription.priceMinorUnits, 4500)
        XCTAssertEqual(repository.events(subscriptionID: subscription.id).count, 1)
    }

    /// 记一笔扣费改的是历史，不是现价。
    @MainActor
    func testChargedEventDoesNotChangeCurrentPrice() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        let subscription = try repository.apply(draft(price: 4500))
        try repository.record(SubscriptionEventDraft(subscriptionID: subscription.id,
                                                     type: .charged,
                                                     amountMinorUnits: 3000,
                                                     currencyCode: "CNY"))
        XCTAssertEqual(subscription.priceMinorUnits, 4500)
        XCTAssertEqual(repository.events(subscriptionID: subscription.id).first?.amountMinorUnits, 3000)
    }

    @MainActor
    func testRemoveEvent() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        let subscription = try repository.apply(draft())
        let event = try repository.record(SubscriptionEventDraft(subscriptionID: subscription.id,
                                                                 type: .skipped))
        try repository.remove(event)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SubscriptionEvent>()).count, 0)

        let detached = SubscriptionEvent(subscriptionID: subscription.id, type: .note)
        XCTAssertThrowsError(try repository.remove(detached)) { error in
            XCTAssertEqual(error as? SubscriptionRepository.Failure, .notStored("备注"))
        }
    }

    /// 撤销删除补回来的是同一条：认稳定 id，不会多出一笔。
    @MainActor
    func testRestoreEventReinsertsTheSameRow() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        let subscription = try repository.apply(draft())
        let happenedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let event = try repository.record(SubscriptionEventDraft(subscriptionID: subscription.id,
                                                                 type: .charged,
                                                                 amountMinorUnits: 4500,
                                                                 currencyCode: "CNY",
                                                                 note: "  含税费  ",
                                                                 happenedAt: happenedAt))
        let copy = repository.draft(of: event)

        try repository.remove(event)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SubscriptionEvent>()).count, 0)

        try repository.restore(copy)
        let back = repository.events(subscriptionID: subscription.id)
        XCTAssertEqual(back.count, 1, "撤销只能补回那一条，不能凭空多记一笔")
        XCTAssertEqual(back[0].id, event.id)
        XCTAssertEqual(back[0].amountMinorUnits, 4500)
        XCTAssertEqual(back[0].note, "含税费")
        XCTAssertEqual(back[0].happenedAt, happenedAt, "扣费时间按原样回来，不能记成撤销那一刻")
    }

    /// 删掉的是一条旧调价，撤销不该把现价盖回那个旧数字：
    /// 删除本身没动现价，撤销也就该只把那一行补回来。
    @MainActor
    func testRestoreEventDoesNotReplayPriceChange() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        let subscription = try repository.apply(draft(price: 4500))
        let oldPriceEvent = try repository.record(SubscriptionEventDraft(subscriptionID: subscription.id,
                                                                        type: .priceChanged,
                                                                        amountMinorUnits: 3000,
                                                                        currencyCode: "CNY"))
        try repository.record(SubscriptionEventDraft(subscriptionID: subscription.id,
                                                    type: .priceChanged,
                                                    amountMinorUnits: 6800,
                                                    currencyCode: "CNY"))
        XCTAssertEqual(subscription.priceMinorUnits, 6800)

        let copy = repository.draft(of: oldPriceEvent)
        try repository.remove(oldPriceEvent)
        try repository.restore(copy)

        XCTAssertEqual(subscription.priceMinorUnits, 6800, "撤销一条历史调价不能把现价改回三年前的数")
        XCTAssertEqual(repository.events(subscriptionID: subscription.id).count, 2)
        XCTAssertEqual(repository.event(id: oldPriceEvent.id)?.amountMinorUnits, 3000)
    }

    /// 主人已经没了的时候不许把事件补回来：那种孤儿记录会让账本凭空多一笔支出。
    @MainActor
    func testRestoreEventNeedsItsSubscription() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        let subscription = try repository.apply(draft())
        let event = try repository.record(SubscriptionEventDraft(subscriptionID: subscription.id, type: .note))
        let copy = repository.draft(of: event)
        try repository.deletePermanently(subscription)

        XCTAssertThrowsError(try repository.restore(copy)) { error in
            XCTAssertEqual(error as? SubscriptionRepository.Failure, .notStored("这条订阅"))
        }
        XCTAssertEqual(try context.fetch(FetchDescriptor<SubscriptionEvent>()).count, 0)
    }

    // MARK: - 入库与落盘

    /// 导入和示例数据整批一次落盘，换一个新的 context 读也得读得到。
    @MainActor
    func testInstallPersistsForAFreshContext() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let repository = SubscriptionRepository(context: context)
        let subscription = Subscription(name: "iCloud", priceMinorUnits: 600,
                                       currencyCode: "CNY", cycle: .monthly)
        let event = SubscriptionEvent(subscriptionID: subscription.id, type: .charged,
                                      amountMinorUnits: 600, currencyCode: "CNY")
        try repository.install([subscription], events: [event])

        let reader = ModelContext(container)
        XCTAssertEqual(try reader.fetch(FetchDescriptor<Subscription>()).count, 1)
        XCTAssertEqual(try reader.fetch(FetchDescriptor<SubscriptionEvent>()).count, 1)
    }

    /// 一次用户操作 = 一遍广播。漏广播的话提醒队列和小组件就停在旧数据上，
    /// 多广播则是白重排一遍。
    @MainActor
    func testEachOperationBroadcastsDataChangeOnce() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        let subscription = try repository.apply(draft())

        XCTAssertEqual(try dataChanges { _ = try repository.apply(draft("第二条")) }, 1)
        XCTAssertEqual(try dataChanges { _ = try repository.setPinned(subscription, true) }, 1)
        XCTAssertEqual(try dataChanges {
            _ = try repository.record(SubscriptionEventDraft(subscriptionID: subscription.id,
                                                             type: .resumed))
        }, 1)
    }

    /// 成功落盘才广播：库里还挂着没提交干净的改动就发通知，等于把半成品推给整台设备。
    @MainActor
    func testCommitWithoutChangesStillBroadcastsOnce() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        let notifications = try dataChanges { try repository.commit("测试：空提交") }
        XCTAssertEqual(notifications, 1)
    }

    /// 负数和 0 人数这类脏输入夹在入口，不靠每个页面自己记得夹。
    @MainActor
    func testApplyClampsNonsensicalNumbers() throws {
        let context = ModelContext(try makeContainer())
        let repository = SubscriptionRepository(context: context)
        var weird = draft()
        weird.priceMinorUnits = -500
        weird.shareHeadcount = 0
        weird.shareEnabled = true
        weird.shareMyMinorUnits = -1
        weird.customMonths = 0
        weird.cycle = .custom
        let subscription = try repository.apply(weird)

        XCTAssertEqual(subscription.priceMinorUnits, 0)
        XCTAssertEqual(subscription.shareHeadcount, 1)
        XCTAssertEqual(subscription.shareMyMinorUnits, 0)
        XCTAssertEqual(subscription.customMonths, 1)
    }
}
