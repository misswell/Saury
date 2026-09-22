import Foundation
import SwiftData

@MainActor
enum NotificationActionHandler {
    private static let pendingKey = "qijian.pendingNotificationAction"

    static func store(_ payload: NotificationActionPayload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: pendingKey)
    }

    static func consumePendingAction() -> NotificationActionPayload? {
        guard let data = UserDefaults.standard.data(forKey: pendingKey),
              let payload = try? JSONDecoder().decode(NotificationActionPayload.self, from: data) else { return nil }
        UserDefaults.standard.removeObject(forKey: pendingKey)
        return payload
    }

    static func apply(_ payload: NotificationActionPayload, in context: ModelContext) async {
        let items = (try? context.fetch(FetchDescriptor<RenewalItem>())) ?? []
        guard let item = items.first(where: { $0.id == payload.renewalItemID }) else { return }

        switch payload.action {
        case .cancelled:
            item.status = .cancelled
            item.isAutoRenewing = false
        case .continued:
            if let next = RenewalDateCalculator.nextDate(for: item) {
                item.nextRenewalDate = next
                item.status = .active
                item.isAutoRenewing = true
            }
        case .paused:
            item.status = .paused
        case .snoozed:
            await ReminderScheduler.shared.scheduleSnooze(for: item)
        }

        context.insert(DecisionRecord(
            renewalItemID: item.id,
            itemName: item.name,
            action: payload.action,
            amountMinorUnits: item.amountMinorUnits,
            currencyCode: item.currencyCode
        ))
        item.markUpdated()
        try? context.save()
        WidgetSnapshotStore.update(items: items)
        await ReminderScheduler.shared.rescheduleAll(items: items)
    }
}
