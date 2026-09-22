import Foundation
import SwiftData

/// 一次动作留下的可撤销记录（方案 §37）。撤销要回到动作发生前的那条数据，
/// 所以动作之前的状态、日期、锚点日和这次写下的事件 id 必须一起带出来。
struct ExpiryUndoRecord: Identifiable {
    let itemID: UUID
    let itemName: String
    let action: ExpiryAction
    /// 动作当时显示给用户的那句话（「吃完」而不是「已用完」）。
    let actionTitle: String
    let previousState: ExpiryState
    let previousExpiryDate: Date
    let previousAnchorDay: Int
    let eventID: UUID

    var id: UUID { eventID }
}

/// 改动物品和留下事件的唯一入口。二者必须成对发生：
/// 只改状态不记事件，统计页就看不见用户做过什么；只记事件不改状态，
/// 物品会一直回到「待处理」列表里。
@MainActor
struct ExpiryRepository {
    let context: ModelContext

    /// 返回 nil 表示这个动作没有可推进的下一个周期，数据未改动。
    @discardableResult
    func perform(_ action: ExpiryAction, on item: ExpiryItem) -> ExpiryUndoRecord? {
        let previousState = item.state
        let previousExpiryDate = item.expiryDate
        let previousAnchorDay = item.anchorDay

        if action.advancesExpiryDate {
            guard let next = item.nextOccurrence else { return nil }
            item.expiryDate = next
            item.state = .active
        } else if let state = action.resultingState {
            item.state = state
        }

        let event = ExpiryEvent(eventType: action.eventType, for: item)
        context.insert(event)
        item.markUpdated()
        context.saveOrLog("处理动作")
        return snapshot(for: item, action: action, state: previousState,
                        expiryDate: previousExpiryDate, anchorDay: previousAnchorDay,
                        eventID: event.id)
    }

    /// 没有周期的东西（护照、保修卡）算不出「下一次」，续期只能问一个新日期。
    @discardableResult
    func renew(_ item: ExpiryItem, to date: Date) -> ExpiryUndoRecord {
        let previousState = item.state
        let previousExpiryDate = item.expiryDate
        let previousAnchorDay = item.anchorDay

        item.expiryDate = date
        item.anchorDay = ExpiryEngine.calendar.component(.day, from: date) ?? item.anchorDay
        item.state = .active

        let event = ExpiryEvent(eventType: .renewed, for: item)
        context.insert(event)
        item.markUpdated()
        context.saveOrLog("续期")
        return snapshot(for: item, action: .renewed, state: previousState,
                        expiryDate: previousExpiryDate, anchorDay: previousAnchorDay,
                        eventID: event.id)
    }

    /// 撤销 = 把物品放回动作之前，并抹掉那次操作留下的事件。
    /// 事件不删的话，统计页会记着一次从未发生过的「用完」。
    func undo(_ record: ExpiryUndoRecord) {
        guard let item = (try? context.fetch(FetchDescriptor<ExpiryItem>()))?
            .first(where: { $0.id == record.itemID }) else { return }
        item.state = record.previousState
        item.expiryDate = record.previousExpiryDate
        item.anchorDay = record.previousAnchorDay
        if let event = (try? context.fetch(FetchDescriptor<ExpiryEvent>()))?
            .first(where: { $0.id == record.eventID }) {
            context.delete(event)
        }
        item.markUpdated()
        context.saveOrLog("撤销")
    }

    private func snapshot(for item: ExpiryItem, action: ExpiryAction, state: ExpiryState,
                          expiryDate: Date, anchorDay: Int, eventID: UUID) -> ExpiryUndoRecord {
        ExpiryUndoRecord(itemID: item.id, itemName: item.name, action: action,
                         actionTitle: action.title(for: item),
                         previousState: state, previousExpiryDate: expiryDate,
                         previousAnchorDay: anchorDay, eventID: eventID)
    }
}
