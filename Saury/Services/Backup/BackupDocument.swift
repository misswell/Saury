import Foundation
import SwiftUI

/// 备份清单：这份包里有哪些块、每块多大、摘要多少，以及有多少条数据。
///
/// 记条数不只是好看：恢复完要拿它跟库里的实际条数对一遍，
/// 对不上就是「说恢复成功了其实少了几条」的那类 bug。
struct BackupManifest: Codable, Equatable {
    static let partName = "manifest.json"
    static let documentPartName = "document.json"
    static let iconPartPrefix = "icons/"

    /// 备份**内容**的版本，和容器格式版本分开：V1 是当年那个纯 JSON 文件。
    var schemaVersion: Int
    var createdAt: Date
    /// 打备份时的 App 版本，出问题时能定位到具体那次发布。
    var appVersion: String
    var subscriptionCount: Int
    var eventCount: Int
    var iconCount: Int
    var parts: [Part]

    struct Part: Codable, Equatable {
        var name: String
        var sha256: String
        var byteLength: Int
        var kind: Kind

        enum Kind: String, Codable {
            case document
            case icon
        }
    }

    var documentPart: Part? { parts.first { $0.kind == .document } }
    var iconParts: [Part] { parts.filter { $0.kind == .icon } }

    /// 图标文件名和清单里的块名之间就差一个前缀：库外面看包能一眼分清哪块是图。
    static func iconPartName(forFile file: String) -> String { iconPartPrefix + file }

    static func iconFile(forPart name: String) -> String? {
        guard name.hasPrefix(iconPartPrefix) else { return nil }
        return String(name.dropFirst(iconPartPrefix.count))
    }
}

/// 备份 V2 的正文（放在 `document.json` 那一块里）。
///
/// 订阅带稳定 UUID 和全部业务字段、时间戳；事件带自己的 UUID 和所属订阅的 UUID，
/// 恢复完能按这两个键对上，不是靠名字猜。
struct BackupPayload: Codable, Equatable {
    static let schemaVersion = 2

    var exportedAt: Date
    var subscriptions: [BackupSubscription]
    var events: [BackupEvent]
    var categories: [SubscriptionCategory]
    var paymentMethods: [String]
    var preferences: BackupPreferences

    /// 包里带了哪几张图。恢复时和订阅身上的 `iconImageFile` 对照：
    /// 订阅要用的图不在这里，就要如实报「图标缺失」而不是留个空位。
    var iconFileNames: [String]

    /// 这份备份有没有任何东西值得恢复。「没有订阅但带着分类和设置」是合法的
    /// （换机时先把偏好搬过去），所以判的是「全都空」；
    /// 那种文件多半是拿错了，直接说清楚，别恢复完让用户以为数据没了。
    var hasNothingToRestore: Bool {
        subscriptions.isEmpty && events.isEmpty && categories.isEmpty
            && paymentMethods.isEmpty && preferences == BackupPreferences()
    }

    // MARK: - 校验

    /// 恢复前的一次性体检。发现问题不修、只报：修数据必须由人决定，
    /// 悄悄「帮用户补全」就是把猜出来的值写进账本。
    enum Issue: Equatable {
        case duplicateSubscriptionID(UUID, name: String)
        case duplicateEventID(UUID)
        case missingName(index: Int)
        case orphanEvent(eventID: UUID, subscriptionID: UUID)
        case negativeAmount(subscriptionID: UUID)

        var text: String {
            switch self {
            case .duplicateSubscriptionID(let id, let name):
                return "备份里有两条订阅共用同一个编号（\(id.uuidString.prefix(8))，「\(name)」），第二条会被当成重复"
            case .duplicateEventID(let id):
                return "备份里有两条事件记录共用同一个编号（\(id.uuidString.prefix(8))）"
            case .missingName(let index):
                return "备份里第 \(index + 1) 条订阅没有名字，这条没导"
            case .orphanEvent(let eventID, let subscriptionID):
                return "事件 \(eventID.uuidString.prefix(8)) 指向的订阅 \(subscriptionID.uuidString.prefix(8)) 不在这份备份里"
            case .negativeAmount(let id):
                return "订阅 \(id.uuidString.prefix(8)) 的金额是负数，已按 0 处理"
            }
        }
    }

    func validate() -> [Issue] {
        var issues: [Issue] = []
        var seenSubscriptionIDs = Set<UUID>()
        for (index, subscription) in subscriptions.enumerated() {
            if !seenSubscriptionIDs.insert(subscription.id).inserted {
                issues.append(.duplicateSubscriptionID(subscription.id, name: subscription.name))
            }
            if subscription.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.missingName(index: index))
            }
            if subscription.priceMinorUnits < 0 {
                issues.append(.negativeAmount(subscriptionID: subscription.id))
            }
        }
        var seenEventIDs = Set<UUID>()
        for event in events {
            if !seenEventIDs.insert(event.id).inserted {
                issues.append(.duplicateEventID(event.id))
            }
            if !seenSubscriptionIDs.contains(event.subscriptionID) {
                issues.append(.orphanEvent(eventID: event.id, subscriptionID: event.subscriptionID))
            }
        }
        return issues
    }

    /// 恢复时真正能写进去的订阅：把体检里判定的坏行剔掉，剩下的好行不受牵连。
    func recoverableSubscriptions() -> [BackupSubscription] {
        var seen = Set<UUID>()
        return subscriptions.filter { item in
            guard !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return seen.insert(item.id).inserted
        }
    }

    /// 编号不重复的事件。指向谁存不存在不在这里管：那是 `SubscriptionRepository`
    /// 落库时判的，它才能把「跳过了几条」如实报出来。
    func deduplicatedEvents() -> [BackupEvent] {
        var seen = Set<UUID>()
        return events.filter { seen.insert($0.id).inserted }
    }
}

/// 一条订阅的完整备份形状。`Subscription` 是 `@Model`，不能直接 Codable，
/// 所以这里逐个字段抄一份 —— 顺带把「哪些字段必须跟着备份走」写死在明面上。
struct BackupSubscription: Codable, Equatable {
    var id: UUID
    var name: String
    var plan: String
    var iconSymbolName: String?
    var iconImageFile: String?
    var iconColorHex: String?
    var colorHexes: [String]
    var priceMinorUnits: Int
    var currencyCode: String
    var cycle: String
    var customMonths: Int
    var category: String
    var state: String
    var startDate: Date
    var endDate: Date?
    /// 可选：§5.1 之前的备份和云端载荷里没有这一列。
    var remindersEnabled: Bool?
    var reminderDays: Int
    var shareEnabled: Bool
    var shareHeadcount: Int
    var shareMode: String
    var shareMyMinorUnits: Int
    var paymentMethod: String
    var notes: String

    // 状态与排序：置顶、归档、进回收站都是数据的一部分，不能只备份「在用的」。
    var pinnedAt: Date?
    var archivedAt: Date?
    var deletedAt: Date?
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date

    init(_ subscription: Subscription) {
        id = subscription.id
        name = subscription.name
        plan = subscription.plan
        iconSymbolName = subscription.iconSymbolName
        iconImageFile = subscription.iconImageFile
        iconColorHex = subscription.iconColorHex
        colorHexes = subscription.colorSpec.orderedHexes
        priceMinorUnits = subscription.priceMinorUnits
        currencyCode = subscription.currencyCode
        cycle = subscription.cycleRawValue
        customMonths = subscription.customMonths
        category = subscription.categoryRawValue
        state = subscription.stateRawValue
        startDate = subscription.startDate
        endDate = subscription.endDate
        remindersEnabled = subscription.remindersEnabled
        reminderDays = subscription.reminderDays
        shareEnabled = subscription.shareEnabled
        shareHeadcount = subscription.shareHeadcount
        shareMode = subscription.shareModeRawValue
        shareMyMinorUnits = subscription.shareMyMinorUnits
        paymentMethod = subscription.paymentMethod
        notes = subscription.notes
        pinnedAt = subscription.pinnedAt
        archivedAt = subscription.archivedAt
        deletedAt = subscription.deletedAt
        sortOrder = subscription.sortOrder
        createdAt = subscription.createdAt
        updatedAt = subscription.updatedAt
    }

    var draft: SubscriptionDraft {
        var draft = SubscriptionDraft()
        draft.id = id
        draft.name = name
        draft.plan = plan
        draft.iconSymbolName = iconSymbolName
        draft.iconImageFile = iconImageFile
        draft.iconColorHex = iconColorHex
        draft.colorSpec = CardColorSpec(hexes: colorHexes)
        draft.priceMinorUnits = max(priceMinorUnits, 0)
        draft.currencyCode = currencyCode
        draft.cycle = BillingCycle(rawValue: cycle) ?? .monthly
        draft.customMonths = max(customMonths, 1)
        draft.category = category
        draft.state = SubscriptionState(rawValue: state) ?? .autoRenew
        draft.startDate = startDate
        draft.endDate = endDate
        draft.remindersEnabled = resolvedRemindersEnabled
        draft.reminderDays = reminderDays
        draft.shareEnabled = shareEnabled
        draft.shareHeadcount = max(shareHeadcount, 1)
        draft.shareMode = ShareMode(rawValue: shareMode) ?? .even
        draft.shareMyMinorUnits = max(shareMyMinorUnits, 0)
        draft.paymentMethod = paymentMethod
        draft.notes = notes
        return draft
    }

    var status: BackupRow {
        BackupRow(pinnedAt: pinnedAt, archivedAt: archivedAt, deletedAt: deletedAt,
                  sortOrder: sortOrder, createdAt: createdAt, updatedAt: updatedAt)
    }

    /// 旧备份 / 旧云端载荷里没有「要不要提醒」这一列。
    /// 按当时界面说的话解释：那一版的详情和表单都把 0 天写成「不提醒」，
    /// 所以 `reminderDays == 0` 的那一条恢复回来仍然是不提醒 —— 和老库那趟
    /// 补算（`ReminderIntentBackfill`）同一个口径，两条路不会给同一条订阅判出相反的结果。
    var resolvedRemindersEnabled: Bool { remindersEnabled ?? (reminderDays > 0) }
}

/// 备份里的一行只写「状态与时间戳」这一半。
///
/// 业务字段走表单同一份 `SubscriptionDraft`（新增、编辑、导入、恢复四条路共用一张
/// 字段表，不会这里补了那里漏），置顶 / 归档 / 回收站时间和排序、创建时间却是备份和
/// 迁移特有的：用户没在界面上填过它们，也不该出现在表单里。恢复时两半合并成一行。
struct BackupRow: Equatable {
    var pinnedAt: Date?
    var archivedAt: Date?
    var deletedAt: Date?
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date
}

struct BackupEvent: Codable, Equatable {
    var id: UUID
    var subscriptionID: UUID
    var type: String
    var amountMinorUnits: Int
    var currencyCode: String
    var note: String
    var happenedAt: Date

    init(_ event: SubscriptionEvent) {
        id = event.id
        subscriptionID = event.subscriptionID
        type = event.typeRawValue
        amountMinorUnits = event.amountMinorUnits
        currencyCode = event.currencyCode
        note = event.note
        happenedAt = event.happenedAt
    }

    var draft: SubscriptionEventDraft {
        SubscriptionEventDraft(id: id,
                               subscriptionID: subscriptionID,
                               type: SubscriptionEventType(rawValue: type) ?? .note,
                               amountMinorUnits: max(amountMinorUnits, 0),
                               currencyCode: currencyCode,
                               note: note,
                               happenedAt: happenedAt)
    }
}

/// 备份里的用户偏好。全部可选：老备份少几个键是常态，
/// 键不在就保持本机现在的值，而不是把用户的主题色重置成默认。
struct BackupPreferences: Codable, Equatable {
    var appearance: String?
    var accentHex: String?
    var coloredCards: Bool?
    var defaultCurrency: String?
    var commonCurrencies: [String]?
    var onlyCommonCurrencies: Bool?
    var showOriginalCurrency: Bool?
    var defaultRemindersEnabled: Bool?
    var defaultReminderDays: Int?
    var reminderHour: Int?
    var notificationsEnabled: Bool?
    var hiddenPanels: [String]?
    var panelOrder: [String]?
    var compactStats: Bool?
    var subscriptionsViewMode: String?
    var subscriptionsSort: String?
    var trendChartStyle: String?
    var hasOnboarded: Bool?
    var lastWhatsNewVersion: String?

    /// 列表筛选故意不进备份：把「只看视频」这种临时状态带回来，
    /// 恢复完看到的是一张空列表，像极了数据没了。
    @MainActor
    static func current(from preferences: SubPreferences) -> BackupPreferences {
        BackupPreferences(appearance: preferences.appearance.rawValue,
                          accentHex: preferences.accentHex,
                          coloredCards: preferences.coloredCards,
                          defaultCurrency: preferences.defaultCurrency,
                          commonCurrencies: preferences.commonCurrencies,
                          onlyCommonCurrencies: preferences.onlyCommonCurrencies,
                          showOriginalCurrency: preferences.showOriginalCurrency,
                          defaultRemindersEnabled: preferences.defaultRemindersEnabled,
                          defaultReminderDays: preferences.defaultReminderDays,
                          reminderHour: preferences.reminderHour,
                          notificationsEnabled: preferences.notificationsEnabled,
                          hiddenPanels: preferences.hiddenPanels.map(\.rawValue),
                          panelOrder: preferences.panelOrder.map(\.rawValue),
                          compactStats: preferences.compactStats,
                          subscriptionsViewMode: preferences.subscriptionsViewMode.rawValue,
                          subscriptionsSort: preferences.subscriptionsSort.rawValue,
                          trendChartStyle: preferences.trendChartStyle.rawValue,
                          hasOnboarded: preferences.hasOnboarded,
                          lastWhatsNewVersion: preferences.lastWhatsNewVersion)
    }

    /// 只写这份备份里带来的键：老文件缺了的项保持本机现状，
    /// 不拿默认值去盖用户自己挑过的设置。
    /// 整包写回收成一次通知（`batch`）：恢复十几个键不该变成十几轮重绘。
    @MainActor
    func apply(to preferences: SubPreferences) {
        preferences.batch {
            applyEach(to: preferences)
        }
    }

    @MainActor
    private func applyEach(to preferences: SubPreferences) {
        if let appearance, let mode = SubPreferences.AppearanceMode(rawValue: appearance) {
            preferences.appearance = mode
        }
        if let accentHex, Color(hex: accentHex) != nil { preferences.accentHex = accentHex }
        if let coloredCards { preferences.coloredCards = coloredCards }
        if let defaultCurrency, !defaultCurrency.isEmpty { preferences.defaultCurrency = defaultCurrency }
        if let commonCurrencies, !commonCurrencies.isEmpty { preferences.commonCurrencies = commonCurrencies }
        if let onlyCommonCurrencies { preferences.onlyCommonCurrencies = onlyCommonCurrencies }
        if let showOriginalCurrency { preferences.showOriginalCurrency = showOriginalCurrency }
        if let defaultRemindersEnabled { preferences.defaultRemindersEnabled = defaultRemindersEnabled }
        if let defaultReminderDays {
            // 旧备份没有「要不要提醒」这一列，那时候的 0 在界面上写的是「新建订阅不提醒」，
            // 而 getter 又把 0 读回 3。照字面收成今天的 0（= 扣费当天提醒）就把用户
            // 当初那句话改了。缺这一列就按他看到的话接住：关掉开关，天数还回 3。
            if self.defaultRemindersEnabled == nil {
                let intent = SubPreferences.legacyReminderDefault(days: defaultReminderDays)
                preferences.defaultRemindersEnabled = intent.enabled
                preferences.defaultReminderDays = intent.days
            } else {
                preferences.defaultReminderDays = defaultReminderDays
            }
        }
        if let reminderHour { preferences.reminderHour = reminderHour }
        if let notificationsEnabled { preferences.notificationsEnabled = notificationsEnabled }
        if let hiddenPanels {
            preferences.hiddenPanels = Set(hiddenPanels.compactMap(OverviewPanel.init(rawValue:)))
        }
        if let panelOrder {
            let restored = panelOrder.compactMap(OverviewPanel.init(rawValue:))
            // 备份里没有的面板不能丢：排在后面，总览上照样在。
            preferences.panelOrder = restored + SubPreferences.allPanels.filter { !restored.contains($0) }
        }
        if let compactStats { preferences.compactStats = compactStats }
        if let subscriptionsViewMode, let mode = SubscriptionListViewMode(rawValue: subscriptionsViewMode) {
            preferences.subscriptionsViewMode = mode
        }
        if let subscriptionsSort, let sort = SubscriptionSort(rawValue: subscriptionsSort) {
            preferences.subscriptionsSort = sort
        }
        if let trendChartStyle, let style = SubPreferences.TrendChartStyle(rawValue: trendChartStyle) {
            preferences.trendChartStyle = style
        }
        if let hasOnboarded { preferences.hasOnboarded = hasOnboarded }
        if let lastWhatsNewVersion { preferences.lastWhatsNewVersion = lastWhatsNewVersion }
    }
}
