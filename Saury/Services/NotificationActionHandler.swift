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
        let items = (try? context.fetch(FetchDescriptor<ExpiryItem>())) ?? []
        guard let item = items.first(where: { $0.id == payload.itemID }) else { return }
        await ExpiryActionCenter.shared.perform(payload.action, on: item, in: context)
    }
}
