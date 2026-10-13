import Foundation
import SwiftData

/// 预览和测试用的示例数据。正式运行不种子数据：
/// 空列表本身就是「从零记账」的正确第一屏。
@MainActor
enum DemoDataSeeder {
    static func sampleSubscriptions(reference: Date = Date()) -> [Subscription] {
        func day(_ offset: Int) -> Date {
            BillingMath.calendar.date(byAdding: .day, value: offset, to: reference) ?? reference
        }
        return [
            Subscription(
                name: "ChatGPT Plus",
                plan: "Plus",
                iconSymbolName: "sparkles",
                iconColorHex: "#0FBFBF",
                priceMinorUnits: 2000,
                currencyCode: "USD",
                cycle: .monthly,
                category: "ai",
                startDate: day(0)
            ),
            Subscription(
                name: "iCloud",
                iconSymbolName: "cloud.fill",
                iconColorHex: "#0A84FF",
                priceMinorUnits: 6800,
                currencyCode: "CNY",
                cycle: .monthly,
                category: "cloud",
                startDate: day(1)
            ),
            Subscription(
                name: "视频会员",
                iconSymbolName: "play.tv.fill",
                iconColorHex: "#FF375F",
                priceMinorUnits: 2500,
                currencyCode: "CNY",
                cycle: .monthly,
                category: "video",
                startDate: day(9)
            )
        ]
    }
}
