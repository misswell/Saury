import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// 小组件读的是这份快照而不是数据库：小尺寸只回答「下一件要处理的是什么」。
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

    static func update(items: [ExpiryItem]) {
        let snapshot: QJWidgetSnapshot
        if let next = items.filter(\.isActive).min(by: { $0.effectiveExpiryDate < $1.effectiveExpiryDate }) {
            snapshot = QJWidgetSnapshot(
                name: next.name,
                expiryDate: next.effectiveExpiryDate,
                amountText: next.hasPrice ? next.formattedPrice : nil,
                days: next.daysRemaining,
                countdownText: ExpiryUrgency.label(daysRemaining: next.daysRemaining)
            )
        } else {
            snapshot = QJWidgetSnapshot(name: "还没有需要提醒的物品", expiryDate: Date(), amountText: nil, days: 0, countdownText: "添加第一件物品")
        }
        guard let data = try? JSONEncoder().encode(snapshot), let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.set(data, forKey: key)
        #if canImport(WidgetKit)
        WidgetKit.WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    private static func trackedItems(_ items: [ExpiryItem]) -> [ExpiryItem] {
        items.filter(\.isActive)
    }
}
