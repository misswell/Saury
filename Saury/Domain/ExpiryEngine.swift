import Foundation

/// 旧到期域仅存的计算入口。V4 已经换成订阅模型，这份文件的存在理由
/// 只有两个：V2/V3 迁移的 schema 还引用着 ExpiryItem/ExpiryEvent，
/// 而模型初始化用到了这里的 calendar 和天数差。其余算法不再增长。
enum ExpiryEngine {
    /// 业务日期一律按「日历天」比较：同一天的早晚不改变剩余天数。
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    static func daysRemaining(to date: Date, from referenceDate: Date = Date(), calendar: Calendar = ExpiryEngine.calendar) -> Int {
        let start = calendar.startOfDay(for: referenceDate)
        let end = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }
}
