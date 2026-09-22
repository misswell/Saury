import Foundation
import SwiftData
import Observation

/// 一次处理动作之后的收尾：写事件、刷新 Widget、重排通知、留下撤销入口。
/// 这几件事在每个页面都要做一遍，散在 View 里迟早有一处漏掉。
@MainActor
@Observable
final class ExpiryActionCenter {
    static let shared = ExpiryActionCenter()

    /// 最近一次可撤销的动作（方案 §37）。界面只保留最后一条。
    var pendingUndo: ExpiryUndoRecord?

    private init() {}

    /// 返回 false 表示这个动作对当前物品没有可执行的效果，数据未改动。
    @discardableResult
    func perform(
        _ action: ExpiryAction,
        on item: ExpiryItem,
        in context: ModelContext,
        snoozeChoice: SnoozeChoice = .tomorrow
    ) async -> Bool {
        guard let record = ExpiryRepository(context: context).perform(action, on: item) else { return false }
        pendingUndo = action == .snoozed ? nil : record
        await refresh(in: context)
        // 排队不会撤掉 snooze（方案 §40），所以补排放在重排之后也不会被冲掉。
        if action == .snoozed { await ReminderScheduler.shared.scheduleSnooze(for: item, choice: snoozeChoice) }
        return true
    }

    /// 删除一条记录：通知得跟着一起消失，不然物品没了提醒还在响。
    func delete(_ item: ExpiryItem, in context: ModelContext) async {
        context.delete(item)
        context.saveOrLog("删除物品")
        await ReminderScheduler.shared.cancel(itemID: item.id)
        await refresh(in: context)
    }

    func renew(_ item: ExpiryItem, to date: Date, in context: ModelContext) async {
        pendingUndo = ExpiryRepository(context: context).renew(item, to: date)
        await refresh(in: context)
    }

    func undo(in context: ModelContext) async {
        guard let record = pendingUndo else { return }
        pendingUndo = nil
        ExpiryRepository(context: context).undo(record)
        await refresh(in: context)
    }

    /// 物品集合变化后要一起刷新的外围状态。
    func refresh(in context: ModelContext) async {
        let items = (try? context.fetch(FetchDescriptor<ExpiryItem>())) ?? []
        WidgetSnapshotStore.update(items: items)
        await ReminderScheduler.shared.refillQueue(items: items)
    }
}
