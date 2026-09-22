import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

struct QJWidgetSnapshot: Codable {
    let name: String
    let nextRenewalDate: Date
    let amountText: String
    let days: Int
}

enum WidgetSnapshotStore {
    private static let suiteName = "group.com.guofeng.saury"
    private static let key = "qijian.widgetSnapshot"

    static func update(items: [RenewalItem]) {
        let snapshot: QJWidgetSnapshot
        if let next = items.filter({ $0.status == .active }).min(by: { $0.nextRenewalDate < $1.nextRenewalDate }) {
            snapshot = QJWidgetSnapshot(name: next.name, nextRenewalDate: next.nextRenewalDate, amountText: next.formattedAmount, days: RenewalDateCalculator.daysUntil(next.nextRenewalDate))
        } else {
            snapshot = QJWidgetSnapshot(name: "还没有活跃订阅", nextRenewalDate: Date(), amountText: "添加一个提醒", days: 0)
        }
        guard let data = try? JSONEncoder().encode(snapshot), let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.set(data, forKey: key)
        #if canImport(WidgetKit)
        WidgetKit.WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
