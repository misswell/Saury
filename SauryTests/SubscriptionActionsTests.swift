import XCTest
import SwiftUI
import SwiftData
@testable import Saury

/// 任务书 §8.5：「长按菜单、滑动操作和批量操作调用相同的业务逻辑」，
/// 「失败时恢复显示并明确提示，不得先删掉 UI 后静默失败」。
///
/// `SubscriptionActions` 就是那一份「相同的业务逻辑」，所以这些规矩在这里测一遍：
/// 每个入口自己不再写一份，也就每个入口都不会漏一份。
/// 这里刻意不通过某个页面去测 —— 测的正是「四个按钮共用哪一条路径」。
@MainActor
final class SubscriptionActionsTests: XCTestCase {
    private func draft(_ name: String = "Netflix",
                       id: UUID = UUID(),
                       state: SubscriptionState = .autoRenew) -> SubscriptionDraft {
        var made = SubscriptionDraft(id: id, name: name, priceMinorUnits: 4500, currencyCode: "CNY")
        made.state = state
        return made
    }

    private func makeRepository() throws -> (ModelContext, SubscriptionRepository) {
        let container = try ModelContainer(for: Schema(versionedSchema: SaurySchemaV4.self),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        return (context, SubscriptionRepository(context: context,
                                                tombstones: SyncTombstoneLog(defaults: UserDefaults(suiteName: "saury.actions.\(UUID().uuidString)")!)))
    }

    /// 数一遍往外广播了几次「数据变了」。空选择一条都没改，就不该惊动提醒和小组件。
    private func broadcasts(_ action: @MainActor () -> Void) -> Int {
        var count = 0
        let token = NotificationCenter.default.addObserver(
            forName: .sauryDataChanged, object: nil, queue: nil
        ) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        action()
        return count
    }

    // MARK: - 撤销：每条路都要有，而且按下去真的能退回去

    /// 置顶以前把仓储返回的快照直接丢掉，所以那条提示压根没有撤销。
    @MainActor
    func testPinOffersAnUndoThatActuallyUnpins() throws {
        let (_, repository) = try makeRepository()
        let subscription = try repository.apply(draft())
        let center = WriteFeedbackCenter()
        let actions = SubscriptionActions(repository: repository, feedback: center)

        XCTAssertTrue(actions.setPinned([subscription], true))
        XCTAssertTrue(subscription.isPinned)
        XCTAssertEqual(center.message?.text, "已置顶「Netflix」")
        XCTAssertEqual(center.message?.actionTitle, "撤销")

        center.performAction()
        XCTAssertFalse(subscription.isPinned, "按了撤销就得真的取消置顶")
        XCTAssertNil(center.message)
    }

    /// 「停用 → 撤销」回到原本那种续费方式。
    /// 这条守的是动作层里最容易被猜错的一脚：把「启用」写成「改成自动续费」。
    @MainActor
    func testDisableThenUndoReturnsManualRenewal() throws {
        let (_, repository) = try makeRepository()
        let subscription = try repository.apply(draft(state: .manualRenew))
        let center = WriteFeedbackCenter()
        let actions = SubscriptionActions(repository: repository, feedback: center)

        XCTAssertTrue(actions.setState([subscription], to: .inactive))
        XCTAssertEqual(center.message?.text, "已停用「Netflix」")
        XCTAssertFalse(subscription.isTracked)

        center.performAction()
        XCTAssertEqual(subscription.state, .manualRenew, "撤销回的是手动续费，不是自动续费")
    }

    /// 状态是用户点出来的，文案就照着那个状态说，不许含糊成「已启用」。
    @MainActor
    func testStateVerbsSayWhichStateWasChosen() throws {
        let (_, repository) = try makeRepository()
        let subscription = try repository.apply(draft(state: .inactive))
        let center = WriteFeedbackCenter()
        let actions = SubscriptionActions(repository: repository, feedback: center)

        _ = actions.setState([subscription], to: .autoRenew)
        XCTAssertEqual(center.message?.text, "已改为自动续费「Netflix」")
        _ = actions.setState([subscription], to: .manualRenew)
        XCTAssertEqual(center.message?.text, "已改为手动续费「Netflix」")
    }

    /// 批量操作的文案报的是条数：三条订阅的名字塞进一句话读不完。
    @MainActor
    func testBatchOperationReportsTheCount() throws {
        let (_, repository) = try makeRepository()
        let rows = try (1...3).map { try repository.apply(draft("订阅 \($0)")) }
        let center = WriteFeedbackCenter()
        let actions = SubscriptionActions(repository: repository, feedback: center)

        XCTAssertTrue(actions.archive(rows))
        XCTAssertTrue(rows.allSatisfy { $0.archivedAt != nil })
        XCTAssertEqual(center.message?.text, "已归档 3 条")

        center.performAction()
        XCTAssertTrue(rows.allSatisfy { $0.archivedAt == nil }, "一次撤销要把三条都放回来")
    }

    /// 事件删除的撤销补回同一行，不多记一笔。
    @MainActor
    func testEventRemovalUndoRestoresTheSameRow() throws {
        let (_, repository) = try makeRepository()
        let subscription = try repository.apply(draft())
        let removed = try repository.record(SubscriptionEventDraft(subscriptionID: subscription.id,
                                                                  type: .charged,
                                                                  amountMinorUnits: 4500,
                                                                  currencyCode: "CNY"))
        let other = try repository.record(SubscriptionEventDraft(subscriptionID: subscription.id,
                                                                type: .note, note: "另一条"))
        let center = WriteFeedbackCenter()
        let actions = SubscriptionActions(repository: repository, feedback: center)

        XCTAssertTrue(actions.remove(removed))
        XCTAssertEqual(repository.events(subscriptionID: subscription.id).count, 1)
        XCTAssertEqual(center.message?.text, "已删除一条扣费记录")
        XCTAssertEqual(center.message?.actionTitle, "撤销")

        center.performAction()
        let back = repository.events(subscriptionID: subscription.id)
        XCTAssertEqual(back.count, 2, "撤销只补回删掉那一条")
        XCTAssertTrue(back.contains { $0.id == removed.id })
        XCTAssertTrue(back.contains { $0.id == other.id })
    }

    /// 撤销本身也是一次写库，它失败时同样不许咽下去。
    /// 这里的场景是删完才按撤销：那条已经不在库里了。
    @MainActor
    func testUndoFailureIsReported() throws {
        let (_, repository) = try makeRepository()
        let subscription = try repository.apply(draft())
        let center = WriteFeedbackCenter()
        let actions = SubscriptionActions(repository: repository, feedback: center)

        XCTAssertTrue(actions.archive([subscription]))
        try repository.deletePermanently(subscription)

        center.performAction()
        XCTAssertEqual(center.message?.style, .failure, "撤销没成功也要说清楚，不能装作退回了")
        XCTAssertTrue(center.message!.text.contains("不在库里"))
    }

    // MARK: - 失败：停在原地 + 说清楚

    /// 「先删掉 UI 再静默失败」的反面：仓储抛错时一条数据都没动，
    /// 界面上要给原因，而且不能给一个按下去什么都退不回来的撤销。
    @MainActor
    func testFailureKeepsTheRowAndRefusesToOfferUndo() throws {
        let (context, repository) = try makeRepository()
        let center = WriteFeedbackCenter()
        let actions = SubscriptionActions(repository: repository, feedback: center)
        let detached = Subscription(name: "预览里的")

        XCTAssertFalse(actions.archive([detached]))
        XCTAssertNil(detached.archivedAt, "没落库就不许先把界面改成归档")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Subscription>()).count, 0)
        XCTAssertEqual(center.message?.style, .failure)
        XCTAssertNil(center.message?.actionTitle, "没做成这件事，不能给撤销")
        XCTAssertTrue(center.message!.text.contains("预览里的"))
    }

    /// 批量里夹了一条不属于这个库的：整批不动，而不是删掉一半再报错。
    @MainActor
    func testBatchFailureMovesNothing() throws {
        let (_, repository) = try makeRepository()
        let stored = try repository.apply(draft("库里的"))
        let center = WriteFeedbackCenter()
        let actions = SubscriptionActions(repository: repository, feedback: center)

        XCTAssertFalse(actions.moveToTrash([stored, Subscription(name: "预览里的")]))
        XCTAssertNil(stored.deletedAt)
        XCTAssertEqual(center.message?.style, .failure)
    }

    /// sheet 里的失败要说在 sheet 上：根视图那条会被盖住，用户看不到原因。
    @MainActor
    func testFailureGoesToTheLocalBarWhenOneIsGiven() throws {
        let (_, repository) = try makeRepository()
        let center = WriteFeedbackCenter()
        final class Box { var value: WriteFeedback? }
        let box = Box()
        let local = Binding<WriteFeedback?>(get: { box.value }, set: { box.value = $0 })
        let actions = SubscriptionActions(repository: repository, feedback: center, local: local)

        XCTAssertFalse(actions.archive([Subscription(name: "预览里的")]))
        XCTAssertEqual(box.value?.style, .failure)
        XCTAssertNil(center.message, "已经交给页内那条了，根视图上不该再冒一遍")
    }

    /// 空选择：不动数据、不广播、不弹提示。
    /// 「已归档 0 条」这种话曾经真实出现在批量栏里。
    @MainActor
    func testEmptySelectionDoesNothingAtAll() throws {
        let (_, repository) = try makeRepository()
        let center = WriteFeedbackCenter()
        let actions = SubscriptionActions(repository: repository, feedback: center)

        XCTAssertEqual(broadcasts { _ = actions.archive([]) }, 0)
        XCTAssertEqual(broadcasts { _ = actions.setPinned([], true) }, 0)
        XCTAssertEqual(broadcasts { _ = actions.setState([], to: .inactive) }, 0)
        XCTAssertEqual(broadcasts { _ = actions.deleteForever([]) }, 0)
        XCTAssertNil(center.message)
    }

    // MARK: - 不可撤销的那一脚

    /// 彻底删除没有撤销入口 —— 给了就是骗人，因为数据和事件都已经从库里没了。
    /// 确认弹窗归调用方负责（页面上那条 `confirmationDialog`）。
    @MainActor
    func testDeleteForeverSaysSoAndOffersNoUndo() throws {
        let (context, repository) = try makeRepository()
        let subscription = try repository.apply(draft())
        let center = WriteFeedbackCenter()
        let actions = SubscriptionActions(repository: repository, feedback: center)

        XCTAssertTrue(actions.deleteForever([subscription]))
        XCTAssertNil(repository.subscription(id: subscription.id))
        XCTAssertEqual(center.message?.text, "已彻底删除「Netflix」")
        XCTAssertNil(center.message?.actionTitle)

        center.performAction()
        XCTAssertEqual(try context.fetch(FetchDescriptor<Subscription>()).count, 0,
                       "按下去什么该都不发生：这条没有退回的路")
    }
}
