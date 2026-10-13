import Foundation

//
//  库能打开 ≠ 数据是好的。
//  迁移、iCloud 合并、备份恢复任何一环出错，留下的都是「看起来正常、
//  实际上算不平」的行：事件找不到订阅、图标指向已经不存在的文件、
//  分类被换成了本机没有的编号。
//  这里只把问题列出来，一个字节都不改 —— 没有人确认过的「自动修数据」
//  只是另一种破坏。
//

struct StoreIntegrityReport: Equatable {
    enum Kind: String, CaseIterable {
        case orphanEvent
        case duplicateID
        case blankName
        case badCurrency
        case badCycle
        case missingIcon
        case unknownCategory

        var title: String {
            switch self {
            case .orphanEvent: return "事件数量对不上"
            case .duplicateID: return "订阅编号重复"
            case .blankName: return "名字是空的"
            case .badCurrency: return "币种不对"
            case .badCycle: return "周期不成样子"
            case .missingIcon: return "图标文件不见了"
            case .unknownCategory: return "分类认不出来"
            }
        }
    }

    struct Issue: Identifiable, Equatable {
        let kind: Kind
        let detail: String
        var id: String { "\(kind.rawValue)|\(detail)" }
    }

    let subscriptionCount: Int
    let eventCount: Int
    let issues: [Issue]

    var isClean: Bool { issues.isEmpty }

    /// 页眉那一行：先报数量，再报问题数。
    var summaryText: String {
        if isClean {
            return "\(subscriptionCount) 条订阅、\(eventCount) 条事件，没查出问题。"
        }
        return "\(subscriptionCount) 条订阅、\(eventCount) 条事件，查出 \(issues.count) 处对不上。"
    }

    /// 一次检查。`iconExists` 和 `categories` 都要能注入，
    /// 否则测试里没法伪造「文件不见了」这种情况。
    static func check(
        subscriptions: [Subscription],
        events: [SubscriptionEvent],
        categories: [SubscriptionCategory],
        iconExists: (String) -> Bool = { IconImageStore.shared.exists($0) }
    ) -> StoreIntegrityReport {
        var issues: [Issue] = []
        let alive = Set(subscriptions.map(\.id))

        // 事件数量：每一条都得认得自己的订阅。
        let orphans = events.filter { !alive.contains($0.subscriptionID) }
        if !orphans.isEmpty {
            issues.append(Issue(kind: .orphanEvent,
                                detail: "\(orphans.count) 条事件找不到对应的订阅（编号 \(orphanSample(orphans))）。这些事件还在库里，统计不会被它们骗过去，但要清掉得你点头。"))
        }

        // UUID：@Attribute(.unique) 挡得住同一台，挡不住合并回来的两份。
        let grouped = Dictionary(grouping: subscriptions, by: \.id)
        for (id, rows) in grouped where rows.count > 1 {
            issues.append(Issue(kind: .duplicateID,
                                detail: "编号 \(id.uuidString) 有 \(rows.count) 条订阅在用（\(rows.map(\.name).joined(separator: "、"))）。"))
        }

        for subscription in subscriptions {
            if subscription.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(Issue(kind: .blankName,
                                    detail: "有一条订阅名字是空的（编号 \(subscription.id.uuidString)）。"))
            }
            let currency = subscription.currencyCode.trimmingCharacters(in: .whitespaces)
            if currency.count != 3 {
                issues.append(Issue(kind: .badCurrency,
                                    detail: "「\(displayName(subscription))」的币种写的是「\(subscription.currencyCode)」，不是三位代码。"))
            }
            if subscription.cycle == .custom && subscription.customMonths < 1 {
                issues.append(Issue(kind: .badCycle,
                                    detail: "「\(displayName(subscription))」是自定义周期，但月数是 \(subscription.customMonths)。"))
            }
            if subscription.endDate != nil, let end = subscription.endDate, end < subscription.startDate {
                issues.append(Issue(kind: .badCycle,
                                    detail: "「\(displayName(subscription))」的结束日期比开始日期还早。"))
            }
            if let file = subscription.iconImageFile, !file.isEmpty, !iconExists(file) {
                issues.append(Issue(kind: .missingIcon,
                                    detail: "「\(displayName(subscription))」的图标文件 \(file) 不在磁盘上了。"))
            }
            if !subscription.categoryRawValue.isEmpty,
               !categories.contains(where: { $0.id == subscription.categoryRawValue }) {
                issues.append(Issue(kind: .unknownCategory,
                                    detail: "「\(displayName(subscription))」的分类编号是「\(subscription.categoryRawValue)」，这台机器的分类表里没有，列表里会显示成「\(DefaultCategories.fallback.name)」。"))
            }
        }

        return StoreIntegrityReport(subscriptionCount: subscriptions.count,
                                    eventCount: events.count,
                                    issues: issues.sorted { $0.kind.rawValue < $1.kind.rawValue })
    }

    private static func displayName(_ subscription: Subscription) -> String {
        subscription.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "（没名字的订阅）" : subscription.name
    }

    /// 孤儿事件太多时只报前三个编号，一屏放不下 200 个 UUID。
    private static func orphanSample(_ orphans: [SubscriptionEvent]) -> String {
        let sample = orphans.prefix(3).map { String($0.subscriptionID.uuidString.prefix(8)) }
        return sample.joined(separator: "、") + (orphans.count > 3 ? " 等" : "")
    }
}
