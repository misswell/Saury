import Foundation

/// 「稍后再提醒」的档位（方案 §45）。每一档都必须能算出确切时刻，
/// 界面上把时刻写出来——晚上十点还能选「今晚」是一句空话。
enum SnoozeChoice: Hashable {
    case inOneHour
    case tonight
    case tomorrow
    case inThreeDays
    case custom(Date)

    static let presets: [SnoozeChoice] = [.inOneHour, .tonight, .tomorrow, .inThreeDays]

    var title: String {
        switch self {
        case .inOneHour: return "1 小时后"
        case .tonight: return "今晚"
        case .tomorrow: return "明天"
        case .inThreeDays: return "3 天后"
        case .custom: return "自定义"
        }
    }

    func fireDate(
        now: Date = Date(),
        preferredHour: Int = ReminderPolicy.reminderHour,
        calendar: Calendar = ExpiryEngine.calendar
    ) -> Date {
        switch self {
        case .inOneHour:
            return ReminderQueue.rounded(now.addingTimeInterval(60 * 60), calendar: calendar)
        case .tonight:
            return eveningSlot(20, reference: now, calendar: calendar)
        case .tomorrow:
            return daySlot(preferredHour, offset: 1, reference: now, calendar: calendar)
        case .inThreeDays:
            return daySlot(preferredHour, offset: 3, reference: now, calendar: calendar)
        case .custom(let date):
            return date > now ? ReminderQueue.rounded(date, calendar: calendar)
                              : ReminderQueue.rounded(now.addingTimeInterval(60), calendar: calendar)
        }
    }

    /// 今晚；20:00 已经过了就顺延到明晚。推迟永远不能推到一个过去的时刻，
    /// 否则这条提醒再也不会响。
    private func eveningSlot(_ hour: Int, reference: Date, calendar: Calendar) -> Date {
        let today = daySlot(hour, offset: 0, reference: reference, calendar: calendar)
        return today > reference ? today : daySlot(hour, offset: 1, reference: reference, calendar: calendar)
    }

    private func daySlot(_ hour: Int, offset: Int, reference: Date, calendar: Calendar) -> Date {
        let base = calendar.date(byAdding: .day, value: offset, to: reference) ?? reference
        var components = calendar.dateComponents([.year, .month, .day], from: base)
        components.hour = min(max(hour, 0), 23)
        components.minute = 0
        return calendar.date(from: components) ?? base
    }
}
