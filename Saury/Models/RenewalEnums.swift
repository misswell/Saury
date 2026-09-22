import Foundation

enum RenewalCycle: String, Codable, CaseIterable, Identifiable {
    case monthly
    case yearly
    case customMonths
    case oneTime
    case freeTrial

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monthly: return "每月"
        case .yearly: return "每年"
        case .customMonths: return "自定义"
        case .oneTime: return "仅一次"
        case .freeTrial: return "免费试用"
        }
    }

    var defaultReminderOffsets: [Int] {
        switch self {
        case .monthly: return [7 * 24 * 60, 3 * 24 * 60, 24 * 60, 0]
        case .yearly: return [30 * 24 * 60, 7 * 24 * 60, 24 * 60, 0]
        case .freeTrial: return [3 * 24 * 60, 24 * 60, 3 * 60]
        case .oneTime: return [7 * 24 * 60, 0]
        case .customMonths: return [7 * 24 * 60, 3 * 24 * 60, 24 * 60, 0]
        }
    }

    var isRecurring: Bool { self != .oneTime }
}

enum RenewalStatus: String, Codable, CaseIterable, Identifiable {
    case active
    case paused
    case cancelled
    case expired

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: return "进行中"
        case .paused: return "已暂停"
        case .cancelled: return "已取消"
        case .expired: return "已到期"
        }
    }
}

enum DecisionAction: String, Codable, CaseIterable, Identifiable {
    case cancelled
    case continued
    case paused
    case snoozed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cancelled: return "已取消续费"
        case .continued: return "继续订阅"
        case .paused: return "已暂停"
        case .snoozed: return "明天再提醒"
        }
    }
}

enum RenewalCategory: String, Codable, CaseIterable, Identifiable {
    case productivity
    case entertainment
    case storage
    case learning
    case wellness
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .productivity: return "效率"
        case .entertainment: return "娱乐"
        case .storage: return "存储"
        case .learning: return "学习"
        case .wellness: return "生活"
        case .other: return "其他"
        }
    }

    var symbolName: String {
        switch self {
        case .productivity: return "square.and.pencil"
        case .entertainment: return "play.rectangle.fill"
        case .storage: return "icloud.fill"
        case .learning: return "book.closed.fill"
        case .wellness: return "leaf.fill"
        case .other: return "circle.grid.2x2.fill"
        }
    }
}

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
