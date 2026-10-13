import Foundation
import SwiftData

extension Notification.Name {
    /// 订阅数据变了：提醒队列、小组件、iCloud 自动同步都靠这一拍。
    static let sauryDataChanged = Notification.Name("saury.dataChanged")
}

/// 扣费周期。EON 式订阅管理的一切统计都建立在「折算到月」上，
/// 一次性是特殊成员：不参与月均，只在发生日计入累计。
enum BillingCycle: String, CaseIterable, Codable {
    case weekly
    case monthly
    case quarterly
    case semiannual
    case yearly
    case custom
    case oneTime

    var title: String {
        switch self {
        case .weekly: return "每周"
        case .monthly: return "每月"
        case .quarterly: return "每季度"
        case .semiannual: return "每半年"
        case .yearly: return "每年"
        case .custom: return "自定义"
        case .oneTime: return "一次性"
        }
    }

    var symbol: String {
        switch self {
        case .weekly: return "7.circle"
        case .monthly: return "calendar"
        case .quarterly: return "square.grid.2x2"
        case .semiannual: return "moonhalf.fill"
        case .yearly: return "globe.asia.australia"
        case .custom: return "slider.horizontal.3"
        case .oneTime: return "infinity"
        }
    }

    /// 折算到月的除数；一次性没有月均概念，返回 nil。
    var monthsPerCycle: Int? {
        switch self {
        case .weekly: return nil
        case .monthly: return 1
        case .quarterly: return 3
        case .semiannual: return 6
        case .yearly: return 12
        case .custom: return nil
        case .oneTime: return nil
        }
    }

    var isRecurring: Bool { self != .oneTime }
}

/// 订阅状态。已停用的不再产生下一次扣费，但保留在列表里（打上标记）。
enum SubscriptionState: String, CaseIterable, Codable {
    case autoRenew
    case manualRenew
    case inactive

    var title: String {
        switch self {
        case .autoRenew: return "自动续费"
        case .manualRenew: return "手动续费"
        case .inactive: return "已停用"
        }
    }
}

/// 拼车分摊方式。均摊按人数平分；自定义直接填自己那份。
enum ShareMode: String, CaseIterable, Codable {
    case even
    case custom

    var title: String {
        switch self {
        case .even: return "均摊"
        case .custom: return "自定义我的份额"
        }
    }
}

/// 卡片配色。`hexes` 为空表示「自动」：优先用图标色，图片图标取主色，黑白取灰。
struct CardColorSpec: Codable, Equatable {
    var hexes: [String]

    static let automatic = CardColorSpec(hexes: [])
    var isAutomatic: Bool { hexes.isEmpty }
    /// 1 个是单色，2-3 个按顺序做渐变（1 是主色）。
    var orderedHexes: [String] { hexes }
}

/// 一条订阅。金额填账单上的总额；开了分摊后，统计只计入自己那份。
@Model
final class Subscription {
    @Attribute(.unique) var id: UUID

    var name: String
    var plan: String

    // 图标：SF 符号名或落盘的图片文件名，二选一；都没有就用首字母块。
    var iconSymbolName: String?
    var iconImageFile: String?
    /// 图标库里点过的颜色（十六进制）。既用于渲染符号，也是「自动」卡色的来源。
    var iconColorHex: String?

    var colorSpecData: Data

    // 金额
    var priceMinorUnits: Int
    var currencyCode: String
    var cycleRawValue: String
    /// 自定义周期 = N 个月。
    var customMonths: Int

    var categoryRawValue: String
    var stateRawValue: String

    // 时间
    var startDate: Date
    var endDate: Date?
    /// 要不要为这条订阅排扣费提醒。任务书 §5.1：这件事必须由这个开关说，
    /// 不许再拿 `reminderDays == 0` 兼职表达「不提醒」——0 的语义是「当天提醒」。
    ///
    /// `= true` 不是摆设：CoreData 的自动轻量迁移只肯补「可空或有默认值」的列，
    /// NOT NULL 又没默认值它就不肯替老库猜一个值。这个默认只活一瞬 ——
    /// 老库那几行紧接着由 `ReminderIntentBackfill` 按当初界面上的说法重算。
    var remindersEnabled: Bool = true
    /// 提前几天提醒；0 = 扣费当天。
    var reminderDays: Int

    // 分摊
    var shareEnabled: Bool
    var shareHeadcount: Int
    var shareModeRawValue: String
    /// 自定义份额，以订阅币种的最小单位计。
    var shareMyMinorUnits: Int

    var paymentMethod: String
    var notes: String

    // 列表管理
    var pinnedAt: Date?
    var archivedAt: Date?
    var deletedAt: Date?
    var sortOrder: Int

    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        plan: String = "",
        iconSymbolName: String? = nil,
        iconImageFile: String? = nil,
        iconColorHex: String? = nil,
        colorSpec: CardColorSpec = .automatic,
        priceMinorUnits: Int = 0,
        currencyCode: String = "CNY",
        cycle: BillingCycle = .monthly,
        customMonths: Int = 2,
        category: String = "other",
        state: SubscriptionState = .autoRenew,
        startDate: Date = Date(),
        endDate: Date? = nil,
        remindersEnabled: Bool = true,
        reminderDays: Int = 3,
        shareEnabled: Bool = false,
        shareHeadcount: Int = 2,
        shareMode: ShareMode = .even,
        shareMyMinorUnits: Int = 0,
        paymentMethod: String = "",
        notes: String = "",
        sortOrder: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.plan = plan
        self.iconSymbolName = iconSymbolName
        self.iconImageFile = iconImageFile
        self.iconColorHex = iconColorHex
        self.colorSpecData = (try? JSONEncoder().encode(colorSpec)) ?? Data()
        self.priceMinorUnits = max(priceMinorUnits, 0)
        self.currencyCode = currencyCode
        self.cycleRawValue = cycle.rawValue
        self.customMonths = max(customMonths, 1)
        self.categoryRawValue = category
        self.stateRawValue = state.rawValue
        self.startDate = startDate
        self.endDate = endDate
        self.remindersEnabled = remindersEnabled
        self.reminderDays = max(reminderDays, 0)
        self.shareEnabled = shareEnabled
        self.shareHeadcount = max(shareHeadcount, 1)
        self.shareModeRawValue = shareMode.rawValue
        self.shareMyMinorUnits = max(shareMyMinorUnits, 0)
        self.paymentMethod = paymentMethod
        self.notes = notes
        self.pinnedAt = nil
        self.archivedAt = nil
        self.deletedAt = nil
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    // MARK: - 计算属性

    var cycle: BillingCycle {
        get { BillingCycle(rawValue: cycleRawValue) ?? .monthly }
        set { cycleRawValue = newValue.rawValue; updatedAt = Date() }
    }

    var state: SubscriptionState {
        get { SubscriptionState(rawValue: stateRawValue) ?? .autoRenew }
        set { stateRawValue = newValue.rawValue; updatedAt = Date() }
    }

    var shareMode: ShareMode {
        get { ShareMode(rawValue: shareModeRawValue) ?? .even }
        set { shareModeRawValue = newValue.rawValue; updatedAt = Date() }
    }

    var colorSpec: CardColorSpec {
        get { (try? JSONDecoder().decode(CardColorSpec.self, from: colorSpecData)) ?? .automatic }
        set { colorSpecData = (try? JSONEncoder().encode(newValue)) ?? Data(); updatedAt = Date() }
    }

    var isTracked: Bool { deletedAt == nil && archivedAt == nil && state != .inactive }
    var isPinned: Bool { pinnedAt != nil }

    /// 只打时间戳。「通知各消费方」归 `SubscriptionRepository.commit`：
    /// 一次批量操作广播一遍就够，逐条广播会把提醒重排和小组件快照打成连环重绘。
    func markUpdated() {
        updatedAt = Date()
    }

    /// 账单总额的展示金额（未分摊）。
    var billAmount: Money { Money(minorUnits: priceMinorUnits, currencyCode: currencyCode) }

    /// 我实际承担的那份。均摊把总额除以人数（整数半进位，见 `Money.evenShare`），
    /// 自定义用填的数字。
    var myAmount: Money {
        guard shareEnabled else { return billAmount }
        switch shareMode {
        case .even:
            return Money(minorUnits: Money.evenShare(totalMinorUnits: priceMinorUnits,
                                                     headcount: shareHeadcount),
                         currencyCode: currencyCode)
        case .custom:
            return Money(minorUnits: shareMyMinorUnits, currencyCode: currencyCode)
        }
    }

    /// 其余每人（均摊时）；自定义份额下没有「其余每人」。
    var othersAmount: Money? {
        guard shareEnabled, shareMode == .even else { return nil }
        return myAmount
    }

    var cycleTitle: String {
        if case .custom = cycle { return "每 \(customMonths) 月" }
        return cycle.title
    }

    /// 周期推进的锚点日 = 开始日是几号。被钳到月底的期数过去后仍回到这一天。
    var anchorDay: Int { BillingMath.calendar.component(.day, from: startDate) }
}
