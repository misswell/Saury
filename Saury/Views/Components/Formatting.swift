import Foundation

enum QJFormatters {
    static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日"
        return formatter
    }()

    static let weekdayDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日 · EEEE"
        return formatter
    }()

    static let shortDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日 HH:mm"
        return formatter
    }()
}

extension Date {
    var qjDateText: String { QJFormatters.date.string(from: self) }
    var qjWeekdayDateText: String { QJFormatters.weekdayDate.string(from: self) }
    var qjShortDateTimeText: String { QJFormatters.shortDateTime.string(from: self) }
}

extension Int {
    var qjCurrencyText: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "CNY"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: NSNumber(value: Double(self) / 100)) ?? "¥0"
    }
}
