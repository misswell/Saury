import Foundation
import SwiftUI

/// 全部用户偏好的唯一出口。订阅只存名字和 id，分类清单、支付方式、
/// 主题色这些「设置层」的状态都住在这里（UserDefaults）。
@MainActor
final class SubPreferences: ObservableObject {
    static let shared = SubPreferences()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Keys

    private enum Key {
        static let onboarded = "saury.onboarded"
        static let accentHex = "saury.accentHex"
        static let appearanceRaw = "saury.appearance"
        static let coloredCards = "saury.coloredCards"
        static let defaultCurrency = "saury.defaultCurrency"
        static let commonCurrencies = "saury.commonCurrencies"
        static let onlyCommonCurrencies = "saury.onlyCommonCurrencies"
        static let showOriginalCurrency = "saury.showOriginalCurrency"
        static let defaultReminderDays = "saury.defaultReminderDays"
        static let reminderHour = "saury.reminderHour"
        static let categories = "saury.categories"
        static let paymentMethods = "saury.paymentMethods"
        static let hiddenPanels = "saury.hiddenPanels"
        static let compactStats = "saury.compactStats"
        static let lastShownVersion = "saury.lastWhatsNewVersion"
        static let notificationsEnabled = "saury.notificationsEnabled"
        static let subscriptionsViewMode = "saury.subscriptionsViewMode"
        static let subscriptionsSort = "saury.subscriptionsSort"
        static let trendChartStyle = "saury.trendChartStyle"
        static let listFilters = "saury.listFilters"
    }

    // MARK: - 引导

    var hasOnboarded: Bool {
        get { defaults.bool(forKey: Key.onboarded) }
        set { defaults.set(newValue, forKey: Key.onboarded) }
    }

    // MARK: - 外观

    enum AppearanceMode: String, CaseIterable {
        case system, light, dark

        var title: String {
            switch self {
            case .system: return "跟随系统"
            case .light: return "浅色"
            case .dark: return "深色"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    /// 八个主题色，对应设置-外观里的八个圆点。
    static let accentChoices: [String] = [
        "#0A84FF", "#5E5CE6", "#BF5AF2", "#FF375F",
        "#FF453A", "#FF9F0A", "#30D158", "#63E6E2"
    ]

    var accentHex: String {
        get { defaults.string(forKey: Key.accentHex) ?? Self.accentChoices[0] }
        set { defaults.set(newValue, forKey: Key.accentHex) }
    }

    var appearance: AppearanceMode {
        get { AppearanceMode(rawValue: defaults.string(forKey: Key.appearanceRaw) ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Key.appearanceRaw) }
    }

    var coloredCards: Bool {
        get { defaults.object(forKey: Key.coloredCards) == nil ? true : defaults.bool(forKey: Key.coloredCards) }
        set { defaults.set(newValue, forKey: Key.coloredCards) }
    }

    // MARK: - 货币

    var defaultCurrency: String {
        get { defaults.string(forKey: Key.defaultCurrency) ?? "CNY" }
        set { defaults.set(newValue, forKey: Key.defaultCurrency) }
    }

    var commonCurrencies: [String] {
        get { defaults.stringArray(forKey: Key.commonCurrencies) ?? ["CNY", "USD"] }
        set { defaults.set(newValue, forKey: Key.commonCurrencies) }
    }

    var onlyCommonCurrencies: Bool {
        get { defaults.bool(forKey: Key.onlyCommonCurrencies) }
        set { defaults.set(newValue, forKey: Key.onlyCommonCurrencies) }
    }

    var showOriginalCurrency: Bool {
        get { defaults.bool(forKey: Key.showOriginalCurrency) }
        set { defaults.set(newValue, forKey: Key.showOriginalCurrency) }
    }

    // MARK: - 提醒

    var defaultReminderDays: Int {
        get {
            let value = defaults.integer(forKey: Key.defaultReminderDays)
            return value > 0 ? value : 3
        }
        set { defaults.set(newValue, forKey: Key.defaultReminderDays) }
    }

    var reminderHour: Int {
        get {
            let stored = defaults.object(forKey: Key.reminderHour) as? Int
            return stored.map { min(max($0, 0), 23) } ?? 9
        }
        set { defaults.set(min(max(newValue, 0), 23), forKey: Key.reminderHour) }
    }

    var notificationsEnabled: Bool {
        get { defaults.bool(forKey: Key.notificationsEnabled) }
        set { defaults.set(newValue, forKey: Key.notificationsEnabled) }
    }

    // MARK: - 分类与支付方式

    var categories: [SubscriptionCategory] {
        get {
            guard let data = defaults.data(forKey: Key.categories),
                  let decoded = try? JSONDecoder().decode([SubscriptionCategory].self, from: data), !decoded.isEmpty else {
                return DefaultCategories.items
            }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.categories)
            }
        }
    }

    func category(withID id: String) -> SubscriptionCategory {
        categories.first { $0.id == id } ?? DefaultCategories.fallback
    }

    var paymentMethods: [String] {
        get { defaults.stringArray(forKey: Key.paymentMethods) ?? PaymentCatalog.builtIn }
        set { defaults.set(newValue, forKey: Key.paymentMethods) }
    }

    // MARK: - 总览布局

    /// 总览面板的显示顺序；隐藏的放 hiddenPanels。
    static let allPanels: [OverviewPanel] = OverviewPanel.allCases

    var hiddenPanels: Set<OverviewPanel> {
        get {
            let raw = defaults.stringArray(forKey: Key.hiddenPanels) ?? []
            return Set(raw.compactMap(OverviewPanel.init(rawValue:)))
        }
        set { defaults.set(newValue.map(\.rawValue), forKey: Key.hiddenPanels) }
    }

    /// 面板显示顺序；没存过就按默认顺序。
    var panelOrder: [OverviewPanel] {
        get {
            guard let raw = defaults.stringArray(forKey: "saury.panelOrder") else {
                return SubPreferences.allPanels
            }
            let stored = raw.compactMap(OverviewPanel.init(rawValue:))
            let missing = SubPreferences.allPanels.filter { !stored.contains($0) }
            return stored + missing
        }
        set { defaults.set(newValue.map(\.rawValue), forKey: "saury.panelOrder") }
    }

    /// 文字模式：月均/平均每个变成总额下的一行小字。
    var compactStats: Bool {
        get { defaults.bool(forKey: Key.compactStats) }
        set { defaults.set(newValue, forKey: Key.compactStats) }
    }

    // MARK: - 订阅列表

    var subscriptionsViewMode: SubscriptionListViewMode {
        get { SubscriptionListViewMode(rawValue: defaults.string(forKey: Key.subscriptionsViewMode) ?? "") ?? .card }
        set { defaults.set(newValue.rawValue, forKey: Key.subscriptionsViewMode) }
    }

    var subscriptionsSort: SubscriptionSort {
        get { SubscriptionSort(rawValue: defaults.string(forKey: Key.subscriptionsSort) ?? "") ?? .nextCharge }
        set { defaults.set(newValue.rawValue, forKey: Key.subscriptionsSort) }
    }

    enum TrendChartStyle: String, CaseIterable {
        case bars, line
    }

    var trendChartStyle: TrendChartStyle {
        get { TrendChartStyle(rawValue: defaults.string(forKey: Key.trendChartStyle) ?? "") ?? .bars }
        set { defaults.set(newValue.rawValue, forKey: Key.trendChartStyle) }
    }

    /// 列表筛选（分类 id / 状态 / 支付方式）。空集合 = 不过滤。
    struct ListFilters: Codable, Equatable {
        var categoryIDs: [String] = []
        var states: [SubscriptionState] = []
        var paymentMethods: [String] = []
        var currencies: [String] = []

        var isActive: Bool {
            !categoryIDs.isEmpty || !states.isEmpty || !paymentMethods.isEmpty || !currencies.isEmpty
        }
    }

    var listFilters: ListFilters {
        get {
            guard let data = defaults.data(forKey: Key.listFilters),
                  let decoded = try? JSONDecoder().decode(ListFilters.self, from: data) else { return ListFilters() }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.listFilters)
            }
        }
    }

    // MARK: - 新功能

    var lastWhatsNewVersion: String {
        get { defaults.string(forKey: Key.lastShownVersion) ?? "" }
        set { defaults.set(newValue, forKey: Key.lastShownVersion) }
    }
}

enum OverviewPanel: String, CaseIterable, Identifiable {
    case upcoming
    case categoryBreakdown
    case calendar
    case trend
    case totalPaid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .upcoming: return "即将扣费"
        case .categoryBreakdown: return "分类支出"
        case .calendar: return "扣费日历"
        case .trend: return "支出趋势"
        case .totalPaid: return "累计花费"
        }
    }

    var symbol: String {
        switch self {
        case .upcoming: return "clock"
        case .categoryBreakdown: return "chart.pie"
        case .calendar: return "calendar"
        case .trend: return "chart.line.uptrend.xyaxis"
        case .totalPaid: return "creditcard"
        }
    }
}

enum SubscriptionListViewMode: String, CaseIterable {
    case list
    case compactList
    case card
    case compact

    var title: String {
        switch self {
        case .list: return "列表"
        case .compactList: return "紧凑列表"
        case .card: return "卡片"
        case .compact: return "紧凑卡片"
        }
    }
}

enum SubscriptionSort: String, CaseIterable {
    case nextCharge
    case duration
    case addedDate
    case priceDescending
    case priceAscending
    case name
    case random
    case grouped

    var title: String {
        switch self {
        case .nextCharge: return "按续费时间"
        case .duration: return "按订阅时长"
        case .addedDate: return "按添加时间"
        case .priceDescending: return "费用从高到低"
        case .priceAscending: return "费用从低到高"
        case .name: return "按名称"
        case .random: return "随机"
        case .grouped: return "按周期/买断分组"
        }
    }

    /// grouped 之外都是平铺一组。
    var groupsItems: Bool { self == .grouped }
}
