import Foundation

/// 物品分类（方案 §12）。分类决定的是「默认提醒模板」，不是颜色：
/// 状态色一律来自 ExpiryUrgency，否则同一个物品会在不同页面显示成不同紧急度。
enum ExpiryCategory: String, Codable, CaseIterable, Identifiable {
    case food
    case medicine
    case supplement
    case skincare
    case cosmetic
    case household
    case document
    case subscription
    case warranty
    case filter
    case pet
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .food: return "食品"
        case .medicine: return "药品"
        case .supplement: return "保健品"
        case .skincare: return "护肤品"
        case .cosmetic: return "化妆品"
        case .household: return "日用品"
        case .document: return "证件"
        case .subscription: return "订阅"
        case .warranty: return "保修"
        case .filter: return "滤芯 / 耗材"
        case .pet: return "宠物用品"
        case .other: return "其他"
        }
    }

    var symbolName: String {
        switch self {
        case .food: return "leaf.fill"
        case .medicine: return "cross.case.fill"
        case .supplement: return "pills.fill"
        case .skincare: return "drop.fill"
        case .cosmetic: return "paintpalette.fill"
        case .household: return "basket.fill"
        case .document: return "doc.text.fill"
        case .subscription: return "arrow.triangle.2.circlepath"
        case .warranty: return "checkmark.seal.fill"
        case .filter: return "funnel.fill"
        case .pet: return "pawprints.fill"
        case .other: return "circle.grid.2x2.fill"
        }
    }

    /// 处理这个分类的过期物时，用户需要多长的反应时间。
    var handlingNote: String {
        switch self {
        case .food, .medicine, .supplement, .cosmetic, .skincare: return "过期后建议丢弃，不要继续使用。"
        case .document, .warranty: return "需要在到期前办理续期或更换。"
        case .subscription, .filter, .pet, .household, .other: return "决定是续期、更换还是不再需要。"
        }
    }

    /// 用完就没了的东西问「用完了吗」；其余问「还要不要」。
    var isConsumable: Bool {
        switch self {
        case .food, .medicine, .supplement, .skincare, .cosmetic, .household, .filter, .pet: return true
        case .document, .warranty, .subscription, .other: return false
        }
    }

    /// 到期之后要去「办」而不是「扔」（方案 §35）。
    var needsRenewal: Bool {
        switch self {
        case .document, .warranty, .subscription: return true
        default: return false
        }
    }
}

/// 用户显式做出的处理结果（方案 §9）。这里没有 expired：
/// 过期程度是时间的函数，存储层写不下它，只能实时算。
enum ExpiryState: String, Codable, CaseIterable, Identifiable {
    case active
    case consumed
    case discarded
    case renewed
    case cancelled
    case archived

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: return "未处理"
        case .consumed: return "已用完"
        case .discarded: return "已丢弃"
        case .renewed: return "已续期"
        case .cancelled: return "已取消"
        case .archived: return "已归档"
        }
    }

    /// 只有 active 会占提醒额度、进入首页和日历。
    var isTracked: Bool { self == .active }

    var symbolName: String {
        switch self {
        case .active: return "bell.fill"
        case .consumed: return "checkmark.circle.fill"
        case .discarded: return "trash.fill"
        case .renewed: return "arrow.clockwise"
        case .cancelled: return "xmark.circle.fill"
        case .archived: return "archivebox.fill"
        }
    }
}

/// 到期之后是否会再发生一次（方案 §8）。周期用「月」做基本单位，
/// 这样月付、季付、年付可以共用同一套锚点日钳制逻辑。
enum ExpiryRecurrence: String, Codable, CaseIterable, Identifiable {
    case none
    case weekly
    case monthly
    case quarterly
    case everySixMonths
    case yearly
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "不重复"
        case .weekly: return "每周"
        case .monthly: return "每月"
        case .quarterly: return "每季度"
        case .everySixMonths: return "每半年"
        case .yearly: return "每年"
        case .custom: return "自定义"
        }
    }

    var isRecurring: Bool { self != .none }

    /// 间隔月数；weekly 走天，其余按这个月数推进锚点日。
    var intervalMonths: Int? {
        switch self {
        case .none: return nil
        case .weekly: return nil
        case .monthly: return 1
        case .quarterly: return 3
        case .everySixMonths: return 6
        case .yearly: return 12
        case .custom: return 1
        }
    }

    var isMeasuredInWeeks: Bool { self == .weekly }
}

/// 「提前 N 分钟」的展示写法。提醒计划在本机只存分钟数。
struct ReminderPreset: Identifiable, Hashable {
    let minutesBefore: Int
    var id: Int { minutesBefore }

    var title: String {
        switch minutesBefore {
        case 0: return "当天"
        case 60..<24 * 60: return "提前 \(minutesBefore / 60) 小时"
        case 1440...: return "提前 \(minutesBefore / (24 * 60)) 天"
        default: return "提前 \(minutesBefore) 分钟"
        }
    }
}
