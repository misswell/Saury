import Foundation
import SwiftData

/// 订阅的导入导出。JSON 是全量（含事件）；CSV 是最小形状，
/// 方便从别的账本搬过来。导出只写本地临时文件，交给系统分享。
enum SubscriptionImportExport {
    // MARK: - 导出

    struct ExportPayload: Codable {
        var schemaVersion: Int = 1
        var exportedAt: Date
        var subscriptions: [ExportedSubscription]
        var events: [ExportedEvent]
    }

    struct ExportedSubscription: Codable {
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
        var reminderDays: Int
        var shareEnabled: Bool
        var shareHeadcount: Int
        var shareMode: String
        var shareMyMinorUnits: Int
        var paymentMethod: String
        var notes: String
        var createdAt: Date
    }

    struct ExportedEvent: Codable {
        var subscriptionName: String
        var type: String
        var amountMinorUnits: Int
        var currencyCode: String
        var note: String
        var happenedAt: Date
    }

    static func exportJSON(subscriptions: [Subscription]) -> Data {
        let payload = ExportPayload(
            exportedAt: Date(),
            subscriptions: subscriptions.map(exportedSubscription),
            events: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(payload)) ?? Data()
    }


    /// 单条订阅的导出形状（CloudKit 同步也用这份）。
    static func exportedSubscription(_ subscription: Subscription) -> ExportedSubscription {
        ExportedSubscription(
            name: subscription.name,
            plan: subscription.plan,
            iconSymbolName: subscription.iconSymbolName,
            iconImageFile: subscription.iconImageFile,
            iconColorHex: subscription.iconColorHex,
            colorHexes: subscription.colorSpec.orderedHexes,
            priceMinorUnits: subscription.priceMinorUnits,
            currencyCode: subscription.currencyCode,
            cycle: subscription.cycleRawValue,
            customMonths: subscription.customMonths,
            category: subscription.categoryRawValue,
            state: subscription.stateRawValue,
            startDate: subscription.startDate,
            endDate: subscription.endDate,
            reminderDays: subscription.reminderDays,
            shareEnabled: subscription.shareEnabled,
            shareHeadcount: subscription.shareHeadcount,
            shareMode: subscription.shareModeRawValue,
            shareMyMinorUnits: subscription.shareMyMinorUnits,
            paymentMethod: subscription.paymentMethod,
            notes: subscription.notes,
            createdAt: subscription.createdAt
        )
    }

    static func exportMarkdown(
        subscriptions: [Subscription],
        defaultCurrency: String,
        categories: [SubscriptionCategory],
        includeAIPrompt: Bool
    ) -> String {
        let rates = MainActor.assumeIsolated { ExchangeRateStore.shared.rates }
        var lines: [String] = ["# 我的订阅清单", ""]
        var monthlyTotal = 0
        for subscription in subscriptions.sorted(by: { $0.name < $1.name }) {
            let category = categories.first { $0.id == subscription.categoryRawValue }?.name ?? "其他"
            let monthly = BillingMath.monthlyNormalized(subscription)?
                .converting(to: defaultCurrency, rates: rates).minorUnits ?? 0
            monthlyTotal += monthly
            let share = subscription.shareEnabled ? "（拼车 \(subscription.shareHeadcount) 人，自己那份）" : ""
            lines.append("- **\(subscription.name)**：\(subscription.myAmount.formatted)/\(subscription.cycleTitle)\(share) · 分类：\(category)")
            if !subscription.plan.isEmpty { lines.append("  - 套餐：\(subscription.plan)") }
            if !subscription.paymentMethod.isEmpty { lines.append("  - 支付方式：\(subscription.paymentMethod)") }
            if let next = BillingMath.nextChargeDate(for: subscription) {
                lines.append("  - 下次扣费：\(QJFormat.longDate(next))")
            }
            if !subscription.notes.isEmpty { lines.append("  - 备注：\(subscription.notes)") }
        }
        lines.append("")
        lines.append("折算到 \(defaultCurrency) 的月均：约 \(Money(minorUnits: monthlyTotal, currencyCode: defaultCurrency).formatted)/月")
        if includeAIPrompt {
            lines.append("")
            lines.append("---")
            lines.append("以上是我的订阅清单。请帮我分析：1）哪些订阅我可能用不上或可以换成更便宜的方案；2）按月均支出给我省钱的建议；3）指出金额异常或重复的订阅。")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 导入

    /// 返回导入条数。JSON 和 CSV 都试一遍，谁像读谁。
    static func importFile(at url: URL, into context: ModelContext) throws -> Int {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)

        if let payload = try? Self.decodeJSON(data) {
            var count = 0
            for exported in payload.subscriptions {
                let subscription = Subscription(
                    name: exported.name,
                    plan: exported.plan,
                    iconSymbolName: exported.iconSymbolName,
                    iconImageFile: exported.iconImageFile,
                    iconColorHex: exported.iconColorHex,
                    colorSpec: CardColorSpec(hexes: exported.colorHexes),
                    priceMinorUnits: exported.priceMinorUnits,
                    currencyCode: exported.currencyCode,
                    cycle: BillingCycle(rawValue: exported.cycle) ?? .monthly,
                    customMonths: exported.customMonths,
                    category: exported.category,
                    state: SubscriptionState(rawValue: exported.state) ?? .autoRenew,
                    startDate: exported.startDate,
                    endDate: exported.endDate,
                    reminderDays: exported.reminderDays,
                    shareEnabled: exported.shareEnabled,
                    shareHeadcount: exported.shareHeadcount,
                    shareMode: ShareMode(rawValue: exported.shareMode) ?? .even,
                    shareMyMinorUnits: exported.shareMyMinorUnits,
                    paymentMethod: exported.paymentMethod,
                    notes: exported.notes,
                    createdAt: exported.createdAt
                )
                context.insert(subscription)
                count += 1
            }
            try? context.save()
            return count
        }

        if let text = String(data: data, encoding: .utf8) {
            return try importCSV(text, into: context)
        }
        return 0
    }

    private static func decodeJSON(_ data: Data) throws -> ExportPayload? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ExportPayload.self, from: data)
    }

    /// CSV：名称,金额,币种,周期（monthly/yearly/…或中文）。表头可省。
    static func importCSV(_ text: String, into context: ModelContext) throws -> Int {
        var count = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count >= 2, columns[0].lowercased() != "名称", columns[0].lowercased() != "name" else { continue }
            let name = columns[0]
            let priceMinor = Int(((Double(columns[1].replacingOccurrences(of: ",", with: ".")) ?? 0) * 100).rounded())
            let currency = columns.count > 2 ? columns[2] : "CNY"
            let cycle = columns.count > 3 ? (BillingCycle(rawValue: columns[3]) ?? Self.chineseCycle(columns[3])) : .monthly
            let subscription = Subscription(
                name: name,
                priceMinorUnits: priceMinor,
                currencyCode: currency,
                cycle: cycle
            )
            context.insert(subscription)
            count += 1
        }
        try? context.save()
        return count
    }

    private static func chineseCycle(_ text: String) -> BillingCycle {
        switch text {
        case "每周": return .weekly
        case "每月": return .monthly
        case "每季度", "每季": return .quarterly
        case "每半年": return .semiannual
        case "每年": return .yearly
        case "一次性": return .oneTime
        default: return .monthly
        }
    }
}
