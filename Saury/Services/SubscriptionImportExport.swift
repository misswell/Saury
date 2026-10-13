import Foundation
import SwiftData

/// 订阅的导入导出。JSON 是全量（含事件）；CSV 是最小形状，
/// 方便从别的账本搬过来。导出只写本地临时文件，交给系统分享。
enum SubscriptionImportExport {
    /// 导入结果。跳过的行必须一起带回去：只报「成功几条」就是把失败藏了。
    /// 事件单独计数：CSV 那种最小形状一条事件都带不来，报「导了 N 条」时得能看出历史没进来。
    struct Outcome {
        var imported: Int
        var eventsImported: Int = 0
        var skipped: [String]

        var summaryText: String {
            var head = "已导入 \(imported) 条订阅"
            if eventsImported > 0 { head += "、\(eventsImported) 条历史事件" }
            guard !skipped.isEmpty else { return head }
            let detail = skipped.prefix(3).joined(separator: "；")
            let more = skipped.count > 3 ? " 等 \(skipped.count) 条" : ""
            return "\(head)，跳过 \(skipped.count) 条：\(detail)\(more)"
        }
    }

    // MARK: - 导出

    /// 一份旧版（V1）JSON 导出的正文。
    ///
    /// 这个形状已经发出去了，字段一个都不能删、不能改名：外面有人拿它当订阅台账。
    /// 只允许加可选字段，读的时候缺省就是「这份文件那年还没有这个概念」。
    struct ExportPayload: Codable {
        var schemaVersion: Int = 1
        var exportedAt: Date
        var subscriptions: [ExportedSubscription]
        var events: [ExportedEvent]
    }

    /// V1 里一条订阅的导出形状（CloudKit 同步也复用这份）。
    struct ExportedSubscription: Codable {
        /// 稳定编号。老文件里没这个键，所以可选；带上了导入才能按 UUID 去重，
        /// 而不是靠名字猜「这是不是同一条」。
        var id: UUID?
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
        /// 要不要提醒。V1 文件和那几年的云端载荷里都没有这一列，所以可选：
        /// 缺了就按当时界面说的话解释 —— 那一版的 0 天写的是「不提醒」。
        var remindersEnabled: Bool?
        var shareEnabled: Bool
        var shareHeadcount: Int
        var shareMode: String
        var shareMyMinorUnits: Int
        var paymentMethod: String
        var notes: String
        var createdAt: Date

        /// 这一条到底提不提醒。缺这一列的老文件按当年界面的说法解释：
        /// 0 天写的是「不提醒」。和老库那趟补算（`ReminderIntentBackfill`）、备份恢复用的是同一条规矩 ——
        /// 同一份数据从三条路进来给出两种结论，用户迟早会撞上。
        var resolvedRemindersEnabled: Bool { remindersEnabled ?? (reminderDays > 0) }
    }

    /// 一条事件记录。归属靠 `subscriptionName` 认领（V1 的做法），
    /// 编号是后来加的可选字段：有就按编号连，没有才退回按名字找。
    struct ExportedEvent: Codable {
        var id: UUID?
        var subscriptionID: UUID?
        var subscriptionName: String
        var type: String
        var amountMinorUnits: Int
        var currencyCode: String
        var note: String
        var happenedAt: Date
    }

    /// V1 JSON 导出。事件必须一起走：只导订阅等于把「已经付过多少」这段历史丢掉，
    /// 而恢复回来的人看到的是账本凭空少了一半。
    static func exportJSON(subscriptions: [Subscription], events: [SubscriptionEvent]) -> Data {
        let nameByID = Dictionary(uniqueKeysWithValues: subscriptions.map { ($0.id, $0.name) })
        let payload = ExportPayload(
            exportedAt: Date(),
            subscriptions: subscriptions.map(exportedSubscription),
            events: events.compactMap { event in
                guard let name = nameByID[event.subscriptionID] else { return nil }
                return ExportedEvent(id: event.id,
                                     subscriptionID: event.subscriptionID,
                                     subscriptionName: name,
                                     type: event.typeRawValue,
                                     amountMinorUnits: event.amountMinorUnits,
                                     currencyCode: event.currencyCode,
                                     note: event.note,
                                     happenedAt: event.happenedAt)
            }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(payload)) ?? Data()
    }


    /// 单条订阅的导出形状（CloudKit 同步也用这份）。
    static func exportedSubscription(_ subscription: Subscription) -> ExportedSubscription {
        ExportedSubscription(
            id: subscription.id,
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
            remindersEnabled: subscription.remindersEnabled,
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
        // 月均从统计服务取：导出的数字必须和总览、列表看到的是同一个，
        // 所以这里不再自己把各行金额加一遍（自己加会把归档、停用的算进去）。
        let monthlyTotal = SubscriptionStats(subscriptions: subscriptions,
                                             events: [],
                                             defaultCurrency: defaultCurrency,
                                             rates: rates).recurringTotal()
        var lines: [String] = ["# 我的订阅清单", ""]
        for subscription in subscriptions.sorted(by: { $0.name < $1.name }) {
            let category = categories.first { $0.id == subscription.categoryRawValue }?.name ?? "其他"
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
        lines.append("折算到 \(defaultCurrency) 的月均：约 \(monthlyTotal.formatted)/月")
        if includeAIPrompt {
            lines.append("")
            lines.append("---")
            lines.append("以上是我的订阅清单。请帮我分析：1）哪些订阅我可能用不上或可以换成更便宜的方案；2）按月均支出给我省钱的建议；3）指出金额异常或重复的订阅。")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 导入（按默认建议，只写确定是新增的行）

    /// 一步式导入。§3.2 的完整路径是「选文件 → 解析 → 预览 → 纠错 → 确认 → 写入」，
    /// 这里是没开预览界面时的快捷版：只写「本机肯定没有」的那些行，
    /// 疑似重复、需要覆盖本机的，一律原样报回去让人去预览里定夺 ——
    /// 拿一份外部文件悄悄改掉已存在的订阅，是任务书明令禁止的。
    @MainActor
    static func importFile(at url: URL, into context: ModelContext) throws -> Outcome {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let table = try parseTable(data: data, fileName: url.lastPathComponent)
        return try importAutomatically(table: table, into: context)
    }

    /// CSV：名称,金额,币种,周期（monthly/yearly/…或中文）。表头可省。
    /// 金额走统一的 `MoneyParsing`：认千分位、按币种精度校验，
    /// 读不出来的行不导入，原因带回给调用方。
    @MainActor
    static func importCSV(_ text: String, into context: ModelContext) throws -> Outcome {
        let table = try parseTable(data: Data(text.utf8), fileName: "CSV")
        return try importAutomatically(table: table, into: context)
    }

    /// 解析用的分类表和默认币种来自本机设置：同一个文件在改了设置的设备上要读出同样的结果。
    @MainActor
    static func parseTable(data: Data, fileName: String) throws -> ImportParser.Table {
        try ImportParser.parse(data: data,
                               fileName: fileName,
                               categories: SubPreferences.shared.categories,
                               defaultCurrency: SubPreferences.shared.defaultCurrency)
    }

    /// 解析结果 → 冲突判定 → 只写入可自动决定的那些行。整批一次落盘。
    @MainActor
    static func importAutomatically(table: ImportParser.Table, into context: ModelContext) throws -> Outcome {
        let local = ((try? context.fetch(FetchDescriptor<Subscription>())) ?? []).map { BackupSubscription($0).draft }
        let plan = ImportConflictResolver.resolve(table: table, local: local)

        var writes: [SubscriptionRepository.ImportWrite] = []
        var skipped: [String] = []
        for item in plan.items {
            if item.isBlocked {
                skipped.append("\(item.row.sourceLabel)「\(item.row.displayName)」读不出来：\(item.row.issues.joined(separator: "；"))")
                continue
            }
            if let existing = item.local {
                skipped.append("\(item.row.sourceLabel)「\(item.row.displayName)」和本机的一条订阅对上了（\(item.matchKind?.rawValue ?? "内容相近")：\(existing.name)）。疑似重复不能未经确认就覆盖本机数据，这次没动本机那条")
                continue
            }
            writes.append(SubscriptionRepository.ImportWrite(draft: item.row.draft,
                                                             createdAt: item.row.createdAt,
                                                             events: item.row.events))
        }

        let counts = try SubscriptionRepository(context: context).importRows(writes)
        if let loss = table.eventLossSummary { skipped.append(loss) }
        return Outcome(imported: counts.subscriptionsInserted + counts.subscriptionsUpdated,
                       eventsImported: counts.eventsInserted + counts.eventsUpdated,
                       skipped: skipped)
    }
}
