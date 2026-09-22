import AppIntents
import Foundation

struct AddRenewalIntent: AppIntent {
    static var title: LocalizedStringResource = "添加到期提醒"
    static var description = IntentDescription("在期见中创建一个新的订阅提醒。")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "订阅名称")
    var name: String

    @Parameter(title: "多少天后到期", default: 30)
    var days: Int

    init() {
        name = ""
        days = 30
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let safeDays = min(max(days, 0), 3650)
        ExternalInputStore.store(ExternalRenewalDraft(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新订阅" : name,
            amountMinorUnits: nil,
            currencyCode: "CNY",
            renewalDate: Calendar.current.date(byAdding: .day, value: safeDays, to: Date()),
            cycle: .monthly,
            source: "快捷指令"
        ))
        return .result(dialog: "已准备好添加「\(name)」，请确认金额和提醒时间。")
    }
}

struct QJShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddRenewalIntent(), phrases: [
            "在 \(.applicationName) 添加订阅提醒",
            "用 \(.applicationName) 记录续费"
        ], shortTitle: "添加到期提醒", systemImageName: "bell.badge")
    }
}
