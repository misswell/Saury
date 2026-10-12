import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// 小组件读的是这份快照而不是数据库：小尺寸只回答「下一次扣费是什么」。
/// SauryWidget 是独立 target，同名字段在它自己的文件里再声明一次，两边必须一致。
struct QJWidgetSnapshot: Codable {
    let name: String
    let expiryDate: Date
    let amountText: String?
    let days: Int
    let countdownText: String
}

enum WidgetSnapshotStore {
    private static let suiteName = "group.com.guofeng.saury"
    private static let key = "qijian.widgetSnapshot"

    static func update(subscriptions: [Subscription], defaultCurrency: String) {
        let snapshot: QJWidgetSnapshot
        let tracked = subscriptions.filter { $0.isTracked && $0.cycle.isRecurring }
        if let next = tracked
            .compactMap({ subscription -> (Subscription, Date)? in
                guard let date = BillingMath.nextChargeDate(for: subscription) else { return nil }
                return (subscription, date)
            })
            .min(by: { $0.1 < $1.1 }) {
            let amount = next.0.myAmount.converting(to: defaultCurrency, rates: MainActor.assumeIsolated { ExchangeRateStore.shared.rates })
            snapshot = QJWidgetSnapshot(
                name: next.0.name,
                expiryDate: next.1,
                amountText: amount.formatted,
                days: BillingMath.daysUntil(next.1),
                countdownText: "还有 \(BillingMath.daysUntil(next.1)) 天扣费"
            )
        } else {
            snapshot = QJWidgetSnapshot(
                name: "还没有订阅",
                expiryDate: Date(),
                amountText: nil,
                days: 0,
                countdownText: "添加第一笔订阅"
            )
        }
        guard let data = try? JSONEncoder().encode(snapshot), let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.set(data, forKey: key)
        #if canImport(WidgetKit)
        WidgetKit.WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
