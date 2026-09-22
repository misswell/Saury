import Foundation

/// 列表的查询条件（方案 §16–§18）。首页、物品页和测试判断的是同一件事，
/// 分成三份写就会在某个角落对不上。
struct ItemQuery: Equatable {
    var searchText = ""
    var categories: Set<ExpiryCategory> = []
    var locations: Set<String> = []
    var urgencies: Set<ExpiryUrgency> = []
    /// 空集在筛选面板里表示「全部」，取数据时按 §14 退回只看跟踪中的物品。
    var states: Set<ExpiryState> = []
    var hasImageOnly = false
    var hasBarcodeOnly = false
    var sort: ItemSort = .earliestExpiry

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 是否偏离了默认视图，用于决定「清除筛选」按钮要不要出现。
    var isFiltering: Bool {
        !trimmedSearch.isEmpty || !categories.isEmpty || !locations.isEmpty
            || !urgencies.isEmpty || !states.isEmpty || hasImageOnly || hasBarcodeOnly
    }

    var activeStateFilter: Set<ExpiryState> { states.isEmpty ? [.active] : states }

    func matches(_ item: ExpiryItem, now: Date = Date()) -> Bool {
        guard activeStateFilter.contains(item.state) else { return false }
        if !categories.isEmpty, !categories.contains(item.category) { return false }
        if !urgencies.isEmpty, !urgencies.contains(ExpiryEngine.urgency(for: item, from: now)) { return false }
        if hasBarcodeOnly, item.barcode?.isEmpty != false { return false }
        if hasImageOnly, item.imageIdentifier?.isEmpty != false { return false }
        if !locations.isEmpty {
            guard let location = item.location, !location.isEmpty, locations.contains(location) else { return false }
        }
        guard !trimmedSearch.isEmpty else { return true }
        return matchesText(item, trimmedSearch)
    }

    /// §16 要求一次输入同时命中名称、品牌、条码、批次、位置、备注和分类。
    private func matchesText(_ item: ExpiryItem, _ query: String) -> Bool {
        if item.name.localizedCaseInsensitiveContains(query) { return true }
        if item.brand?.localizedCaseInsensitiveContains(query) == true { return true }
        if item.location?.localizedCaseInsensitiveContains(query) == true { return true }
        if item.batchNumber?.localizedCaseInsensitiveContains(query) == true { return true }
        if item.notes.localizedCaseInsensitiveContains(query) { return true }
        if item.category.title.localizedCaseInsensitiveContains(query) { return true }
        if item.barcode?.localizedCaseInsensitiveContains(query) == true { return true }
        return false
    }

    func results(in items: [ExpiryItem], now: Date = Date()) -> [ExpiryItem] {
        items.filter { matches($0, now: now) }.sorted { sort.isOrdered($0, $1) }
    }
}

/// 排序口径（方案 §18）。默认「最快过期」同时满足 §14 的
/// 已过期 → 今天 → 到期日升序：已过期的那几天本来就排在最前面。
enum ItemSort: String, CaseIterable, Identifiable {
    case earliestExpiry
    case latestExpiry
    case recentlyAdded
    case recentlyModified
    case name
    case quantity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .earliestExpiry: return "最快过期"
        case .latestExpiry: return "最晚过期"
        case .recentlyAdded: return "最近添加"
        case .recentlyModified: return "最近修改"
        case .name: return "名称"
        case .quantity: return "数量"
        }
    }

    var symbolName: String {
        switch self {
        case .earliestExpiry: return "calendar.badge.clock"
        case .latestExpiry: return "calendar"
        case .recentlyAdded: return "plus.square.on.square.1"
        case .recentlyModified: return "arrow.triangle.2.circlepath"
        case .name: return "textformat.abc"
        case .quantity: return "number"
        }
    }

    func isOrdered(_ lhs: ExpiryItem, _ rhs: ExpiryItem) -> Bool {
        switch self {
        case .earliestExpiry:
            return compare(lhs, rhs) { $0.effectiveExpiryDate < $1.effectiveExpiryDate }
        case .latestExpiry:
            return compare(lhs, rhs) { $0.effectiveExpiryDate > $1.effectiveExpiryDate }
        case .recentlyAdded:
            return compare(lhs, rhs) { $0.createdAt > $1.createdAt }
        case .recentlyModified:
            return compare(lhs, rhs) { $0.updatedAt > $1.updatedAt }
        case .name:
            return compare(lhs, rhs) {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .quantity:
            return compare(lhs, rhs) { $0.quantity > $1.quantity }
        }
    }

    /// 同值时按 id 收口，否则 SwiftUI 每次刷新都可能重排同一个列表。
    private func compare(_ lhs: ExpiryItem, _ rhs: ExpiryItem, _ by: (ExpiryItem, ExpiryItem) -> Bool) -> Bool {
        if by(lhs, rhs) { return true }
        if by(rhs, lhs) { return false }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
