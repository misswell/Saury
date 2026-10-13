import Foundation
import SwiftUI

/// 全部用户偏好的唯一出口。订阅只存名字和 id，分类清单、支付方式、
/// 主题色这些「设置层」的状态都住在这里（UserDefaults）。
///
/// # 变更是怎么发出去的
///
/// 属性都是「算属性」—— 读写直接落在 UserDefaults 上，本机没有第二份缓存，
/// 所以不存在「读到的和磁盘上的不一致」这种窗口。代价是 SwiftUI 看不见
/// 这种写入：必须显式喊 `objectWillChange`，也就是下面的 `publishChange`。
/// 三条规矩：
///
/// 1. **值真的换了才喊。** setter 先跟当前值比一次，没变就直接返回。
///    同步「收下云端那一份」经常收下的是本机本来就有的值，
///    少这一道比较就是一次同步一屏重绘。
/// 2. **一次操作里多个属性，只喊一次。** 见 `batch(_:)`：备份恢复、
///    云端偏好下发这种连写十几个键的路径包起来，收尾统一发一遍。
/// 3. **记账写入不算变更。** `recordSettingRevision` 盖的是「这组偏好
///    什么时候被动过」的时间戳，界面不读它，跟着它喊会让每次真实改动
///    都变成两次通知。
@MainActor
final class SubPreferences: ObservableObject {
    static let shared = SubPreferences()

    private let defaults: UserDefaults
    /// `batch` 的嵌套层数：大于 0 时通知先攒着，最外层那批写完再发。
    private var batchDepth = 0
    private var pendingPublish = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateReminderSemantics()
    }

    // MARK: - 发布

    /// 一次真实的偏好改动。不在批量里就先通知再写盘 —— `ObservableObject`
    /// 的约定是「将要变」，先喊一声，正在做动画的视图才拿得到改前的那一份。
    /// 在批量里反过来：先写完，通知攒着，最外层那批结束统一发一次。
    private func publishChange(_ apply: () -> Void) {
        guard batchDepth > 0 else {
            objectWillChange.send()
            apply()
            return
        }
        apply()
        pendingPublish = true
    }

    /// 把一组连着做的改动合并成一次通知。嵌套调用只发最外层那一次。
    func batch(_ body: () -> Void) {
        batchDepth += 1
        body()
        batchDepth -= 1
        guard batchDepth == 0 else { return }
        if pendingPublish {
            pendingPublish = false
            objectWillChange.send()
        }
    }

    // MARK: - 旧值的提醒语义（任务书 §5.1）

    /// 旧设置页那句「新建订阅不提醒」是挂在 `defaultReminderDays == 0` 上的，
    /// 可 getter 又把 0 读回 3。也就是说：存进 0 的人，是在明确表达「不提醒」，
    /// 只是界面没承认。升级时按他当初看到的话接住：默认改成「不提醒」，
    /// 天数还回「提前 3 天」这个旧默认值。
    /// 没存过这个键（新装）什么都不动。
    /// 这笔账只做一次：认一个哨兵键。不认的话新装用户日后真把天数调成 0
    /// （那是「当天提醒」），下次启动会被当成旧值「修」成不提醒 —— 修掉用户刚做的选择。
    private func migrateReminderSemantics() {
        let done = Self.reminderSemanticsMigratedKey
        guard defaults.object(forKey: done) == nil else { return }
        if defaults.object(forKey: Key.defaultReminderDays) != nil,
           defaults.integer(forKey: Key.defaultReminderDays) == 0 {
            let intent = Self.legacyReminderDefault(days: 0)
            defaults.set(intent.enabled, forKey: Key.defaultRemindersEnabled)
            defaults.set(intent.days, forKey: Key.defaultReminderDays)
            recordSettingRevision(.reminders)
        }
        defaults.set(Date().timeIntervalSince1970, forKey: done)
    }

    /// 上面那笔迁移做过的凭据。测试要能把它擦掉，重演一次「老用户第一次装上这一版」。
    static let reminderSemanticsMigratedKey = "saury.reminderSemantics.v5"

    /// 没存过「提前几天」时的默认值。
    static let fallbackDefaultReminderDays = 3

    /// 旧载荷（这一版之前没有「要不要提醒」这一列）里的天数怎么解释。
    /// 备份恢复和云端偏好下发都走这里：两处对同一个旧值给出两种说法，
    /// 用户就会看到「同一份备份在 A 机器上让他别提醒、在 B 机器上让他天天提醒」。
    static func legacyReminderDefault(days: Int) -> (enabled: Bool, days: Int) {
        days == 0 ? (false, fallbackDefaultReminderDays) : (true, days)
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
        static let defaultRemindersEnabled = "saury.defaultRemindersEnabled"
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
        set {
            guard newValue != hasOnboarded else { return }
            publishChange { defaults.set(newValue, forKey: Key.onboarded) }
        }
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
        set {
            guard newValue != accentHex else { return }
            publishChange { defaults.set(newValue, forKey: Key.accentHex) }
        }
    }

    var appearance: AppearanceMode {
        get { AppearanceMode(rawValue: defaults.string(forKey: Key.appearanceRaw) ?? "") ?? .system }
        set {
            guard newValue != appearance else { return }
            publishChange { defaults.set(newValue.rawValue, forKey: Key.appearanceRaw) }
        }
    }

    var coloredCards: Bool {
        get { defaults.object(forKey: Key.coloredCards) == nil ? true : defaults.bool(forKey: Key.coloredCards) }
        set {
            guard newValue != coloredCards else { return }
            publishChange { defaults.set(newValue, forKey: Key.coloredCards) }
        }
    }

    // MARK: - 货币

    var defaultCurrency: String {
        get { defaults.string(forKey: Key.defaultCurrency) ?? "CNY" }
        set {
            guard newValue != defaultCurrency else { return }
            publishChange { defaults.set(newValue, forKey: Key.defaultCurrency) }
            markSettingChanged(.currency)
        }
    }

    var commonCurrencies: [String] {
        get { defaults.stringArray(forKey: Key.commonCurrencies) ?? ["CNY", "USD"] }
        set {
            guard newValue != commonCurrencies else { return }
            publishChange { defaults.set(newValue, forKey: Key.commonCurrencies) }
            markSettingChanged(.currency)
        }
    }

    var onlyCommonCurrencies: Bool {
        get { defaults.bool(forKey: Key.onlyCommonCurrencies) }
        set {
            guard newValue != onlyCommonCurrencies else { return }
            publishChange { defaults.set(newValue, forKey: Key.onlyCommonCurrencies) }
            markSettingChanged(.currency)
        }
    }

    var showOriginalCurrency: Bool {
        get { defaults.bool(forKey: Key.showOriginalCurrency) }
        set {
            guard newValue != showOriginalCurrency else { return }
            publishChange { defaults.set(newValue, forKey: Key.showOriginalCurrency) }
            markSettingChanged(.currency)
        }
    }

    // MARK: - 提醒

    /// 新建订阅默认要不要提醒。任务书 §5.1：这件事由开关说，
    /// `defaultReminderDays` 只回答「提前几天」，0 的意思永远是「当天」。
    var defaultRemindersEnabled: Bool {
        get {
            defaults.object(forKey: Key.defaultRemindersEnabled) == nil
                ? true
                : defaults.bool(forKey: Key.defaultRemindersEnabled)
        }
        set {
            guard newValue != defaultRemindersEnabled else { return }
            publishChange { defaults.set(newValue, forKey: Key.defaultRemindersEnabled) }
            markSettingChanged(.reminders)
        }
    }

    /// 提前几天。没存过 = 3；存过 0 就是 0（当天提醒）。
    ///
    /// 旧版这里写的是「取出来不大于 0 就返回 3」：于是设置页那句「新建订阅不提醒」
    /// 永远显示不出来 —— 把步进器调到 0，存进去 0，读回来 3，说明又跳回「提前 3 天」。
    var defaultReminderDays: Int {
        get {
            guard defaults.object(forKey: Key.defaultReminderDays) != nil else {
                return Self.fallbackDefaultReminderDays
            }
            return min(max(defaults.integer(forKey: Key.defaultReminderDays), 0), 30)
        }
        set {
            let clamped = min(max(newValue, 0), 30)
            guard clamped != defaultReminderDays else { return }
            publishChange { defaults.set(clamped, forKey: Key.defaultReminderDays) }
            markSettingChanged(.reminders)
        }
    }

    var reminderHour: Int {
        get {
            let stored = defaults.object(forKey: Key.reminderHour) as? Int
            return stored.map { min(max($0, 0), 23) } ?? 9
        }
        set {
            guard newValue != reminderHour else { return }
            publishChange { defaults.set(min(max(newValue, 0), 23), forKey: Key.reminderHour) }
            markSettingChanged(.reminders)
        }
    }

    /// 总开关：关掉之后一条通知都不排（`ReminderPlan` 那边是这个语义）。
    var notificationsEnabled: Bool {
        get { defaults.bool(forKey: Key.notificationsEnabled) }
        set {
            guard newValue != notificationsEnabled else { return }
            publishChange { defaults.set(newValue, forKey: Key.notificationsEnabled) }
        }
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
            guard newValue != categories else { return }
            guard let data = try? JSONEncoder().encode(newValue) else {
                SauryLog.preferencesFailed("保存自定义分类", String(describing: newValue.count))
                return
            }
            publishChange { defaults.set(data, forKey: Key.categories) }
            markSettingChanged(.categories)
        }
    }

    func category(withID id: String) -> SubscriptionCategory {
        categories.first { $0.id == id } ?? DefaultCategories.fallback
    }

    var paymentMethods: [String] {
        get { defaults.stringArray(forKey: Key.paymentMethods) ?? PaymentCatalog.builtIn }
        set {
            guard newValue != paymentMethods else { return }
            publishChange { defaults.set(newValue, forKey: Key.paymentMethods) }
            markSettingChanged(.paymentMethods)
        }
    }

    // MARK: - 同步要用的「这组偏好什么时候被动过」

    /// iCloud 同步按组比时间戳（见 `SyncedSettingGroup`），所以写这些键的时候必须
    /// 同时把「动过」这件事记下来。没有这个记录，同步只能拿内容猜谁新，
    /// 猜错一次就把用户另一台设备上的设置盖掉了。
    /// 没盖过戳的组（装机前就存在的旧值）在同步里算「不可信」：
    /// 只允许把空着的云端填上，不许覆盖云端已有的那一份。
    func settingRevision(_ group: SyncedSettingGroup) -> Date? {
        (defaults.object(forKey: revisionKey(group)) as? TimeInterval).map(Date.init(timeIntervalSince1970:))
    }

    /// 记下这一组的改动时间。`at` 只在「收下云端那一份」时给：
    /// 收下之后本机的时间必须等于云端的时间，否则下一轮会把自己刚收下的东西
    /// 当成本机新改动再推回去。
    func recordSettingRevision(_ group: SyncedSettingGroup, at: Date = Date()) {
        defaults.set(at.timeIntervalSince1970, forKey: revisionKey(group))
    }

    private func markSettingChanged(_ group: SyncedSettingGroup) { recordSettingRevision(group) }

    private func revisionKey(_ group: SyncedSettingGroup) -> String { "saury.settings.revision.\(group.rawValue)" }

    // MARK: - 总览布局

    /// 总览面板的显示顺序；隐藏的放 hiddenPanels。
    static let allPanels: [OverviewPanel] = OverviewPanel.allCases

    var hiddenPanels: Set<OverviewPanel> {
        get {
            let raw = defaults.stringArray(forKey: Key.hiddenPanels) ?? []
            return Set(raw.compactMap(OverviewPanel.init(rawValue:)))
        }
        set {
            guard newValue != hiddenPanels else { return }
            publishChange { defaults.set(newValue.map(\.rawValue), forKey: Key.hiddenPanels) }
        }
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
        set {
            guard newValue != panelOrder else { return }
            publishChange { defaults.set(newValue.map(\.rawValue), forKey: "saury.panelOrder") }
        }
    }

    /// 文字模式：月均/平均每个变成总额下的一行小字。
    var compactStats: Bool {
        get { defaults.bool(forKey: Key.compactStats) }
        set {
            guard newValue != compactStats else { return }
            publishChange { defaults.set(newValue, forKey: Key.compactStats) }
        }
    }

    // MARK: - 订阅列表

    var subscriptionsViewMode: SubscriptionListViewMode {
        get { SubscriptionListViewMode(rawValue: defaults.string(forKey: Key.subscriptionsViewMode) ?? "") ?? .card }
        set {
            guard newValue != subscriptionsViewMode else { return }
            publishChange { defaults.set(newValue.rawValue, forKey: Key.subscriptionsViewMode) }
        }
    }

    var subscriptionsSort: SubscriptionSort {
        get { SubscriptionSort(rawValue: defaults.string(forKey: Key.subscriptionsSort) ?? "") ?? .nextCharge }
        set {
            guard newValue != subscriptionsSort else { return }
            publishChange { defaults.set(newValue.rawValue, forKey: Key.subscriptionsSort) }
        }
    }

    enum TrendChartStyle: String, CaseIterable {
        case bars, line
    }

    var trendChartStyle: TrendChartStyle {
        get { TrendChartStyle(rawValue: defaults.string(forKey: Key.trendChartStyle) ?? "") ?? .bars }
        set {
            guard newValue != trendChartStyle else { return }
            publishChange { defaults.set(newValue.rawValue, forKey: Key.trendChartStyle) }
        }
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

        /// 一共选了几项。筛选面板上那句「已选 N 项」用它 —— 数法只有一处，
        /// 面板和列表不会一个说三项、一个说两项。
        var selectedCount: Int {
            categoryIDs.count + states.count + paymentMethods.count + currencies.count
        }
    }

    var listFilters: ListFilters {
        get {
            guard let data = defaults.data(forKey: Key.listFilters),
                  let decoded = try? JSONDecoder().decode(ListFilters.self, from: data) else { return ListFilters() }
            return decoded
        }
        set {
            guard newValue != listFilters else { return }
            guard let data = try? JSONEncoder().encode(newValue) else {
                SauryLog.preferencesFailed("保存列表筛选", "编码失败")
                return
            }
            publishChange { defaults.set(data, forKey: Key.listFilters) }
        }
    }

    // MARK: - 新功能

    var lastWhatsNewVersion: String {
        get { defaults.string(forKey: Key.lastShownVersion) ?? "" }
        set {
            guard newValue != lastWhatsNewVersion else { return }
            publishChange { defaults.set(newValue, forKey: Key.lastShownVersion) }
        }
    }
}

enum OverviewPanel: String, CaseIterable, Identifiable {
    case pendingPayment
    case upcoming
    case trial
    case categoryBreakdown
    case calendar
    case trend
    case totalPaid
    case quickView

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pendingPayment: return "待付款"
        case .upcoming: return "即将扣费"
        case .trial: return "试用中"
        case .categoryBreakdown: return "分类支出"
        case .calendar: return "扣费日历"
        case .trend: return "支出趋势"
        case .totalPaid: return "累计花费"
        case .quickView: return "快览"
        }
    }

    var symbol: String {
        switch self {
        case .pendingPayment: return "clock.badge.exclamationmark"
        case .upcoming: return "clock"
        case .trial: return "hourglass"
        case .categoryBreakdown: return "chart.pie"
        case .calendar: return "calendar"
        case .trend: return "chart.line.uptrend.xyaxis"
        case .totalPaid: return "creditcard"
        case .quickView: return "eye"
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
