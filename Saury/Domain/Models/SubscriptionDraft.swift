import Foundation

/// 表单的产物：一条订阅「应该长什么样」的完整快照。
///
/// `id` 在表单打开时生成一次、之后不变，`SubscriptionRepository` 按它做 upsert ——
/// 所以连点两次保存改的是同一行，不会出现两份订阅（任务书 §2.3）。
struct SubscriptionDraft: Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var plan: String = ""
    var iconSymbolName: String?
    var iconImageFile: String?
    var iconColorHex: String?
    var colorSpec: CardColorSpec = .automatic
    var priceMinorUnits: Int = 0
    var currencyCode: String = "CNY"
    var cycle: BillingCycle = .monthly
    var customMonths: Int = 2
    var category: String = "other"
    var state: SubscriptionState = .autoRenew
    var startDate: Date = Date()
    var endDate: Date?
    /// 要不要提醒（§5.1 的显式开关）。`reminderDays` 只回答「提前几天」。
    var remindersEnabled: Bool = true
    var reminderDays: Int = 3
    var shareEnabled: Bool = false
    var shareHeadcount: Int = 2
    var shareMode: ShareMode = .even
    var shareMyMinorUnits: Int = 0
    var paymentMethod: String = ""
    var notes: String = ""

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedPlan: String { plan.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedNotes: String { notes.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// 事件表单的产物。同样带稳定 id：重复提交只会补同一笔记录。
struct SubscriptionEventDraft: Equatable {
    var id: UUID = UUID()
    var subscriptionID: UUID
    var type: SubscriptionEventType
    var amountMinorUnits: Int = 0
    var currencyCode: String = ""
    var note: String = ""
    var happenedAt: Date = Date()

    var trimmedNote: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }
}
