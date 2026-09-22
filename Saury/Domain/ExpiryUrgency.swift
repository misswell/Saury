import SwiftUI

/// 到期紧迫度。由剩余天数实时计算，绝不写回数据库：
/// 今天还是 active，明天就已经过期，存储层没有机会自己改状态。
/// 所有页面都从这里取颜色和文案，禁止各自实现一套日期分级。
enum ExpiryUrgency: String, CaseIterable, Identifiable {
    case expired
    case today
    case critical
    case soon
    case upcoming
    case normal

    var id: String { rawValue }

    init(daysRemaining: Int) {
        switch daysRemaining {
        case Int.min..<0: self = .expired
        case 0: self = .today
        case 1...3: self = .critical
        case 4...7: self = .soon
        case 8...30: self = .upcoming
        default: self = .normal
        }
    }

    var title: String {
        switch self {
        case .expired: return "已过期"
        case .today: return "今天"
        case .critical: return "3 天内"
        case .soon: return "7 天内"
        case .upcoming: return "30 天内"
        case .normal: return "以后"
        }
    }

    /// 系统语义色：红=已过期，橙=今天和 3 天内，黄=7 天内，
    /// 次要色=还早，绿=已处理。不给每个分类另配一套底色。
    var tint: Color {
        switch self {
        case .expired: return .red
        case .today, .critical: return .orange
        case .soon: return .yellow
        case .upcoming, .normal: return QJTheme.subtle
        }
    }

    /// 正文用的状态色。systemYellow 在白底上对比度不到 2:1，
    /// 所以「7 天内」的文字退到同色系的琥珀色，圆点和分组仍用 `tint`。
    var textTint: Color {
        switch self {
        case .soon:
            return Color(light: Color(red: 0.62, green: 0.42, blue: 0.02), dark: Color(red: 0.94, green: 0.74, blue: 0.24))
        default:
            return tint
        }
    }

    /// 列表分组顺序，越紧急越靠前。
    var sortWeight: Int {
        switch self {
        case .expired: return 0
        case .today: return 1
        case .critical: return 2
        case .soon: return 3
        case .upcoming: return 4
        case .normal: return 5
        }
    }

    /// 单行右侧的状态文案。
    static func label(daysRemaining: Int) -> String {
        switch daysRemaining {
        case ..<0: return "已过期 \(abs(daysRemaining)) 天"
        case 0: return "今天到期"
        case 1: return "明天到期"
        default: return "还有 \(daysRemaining) 天"
        }
    }
}
