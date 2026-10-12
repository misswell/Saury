import AppIntents
import Foundation

/// 快捷指令：一句话把一笔订阅带进添加页，剩下的细节让用户确认。
struct AddSubscriptionIntent: AppIntent {
    static var title: LocalizedStringResource = "添加订阅"
    static var description = IntentDescription("在期见中创建一笔新订阅。")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "订阅名称")
    var name: String

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        ExternalInputStore.store(.text(trimmed.isEmpty ? "新订阅" : trimmed), source: "快捷指令")
        return .result(dialog: "已准备好添加「\(trimmed.isEmpty ? "新订阅" : trimmed)」，补上金额就能保存。")
    }
}

struct QJShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddSubscriptionIntent(), phrases: [
            "在 \(.applicationName) 添加订阅",
            "用 \(.applicationName) 记一笔订阅"
        ], shortTitle: "添加订阅", systemImageName: "creditcard.badge.clock")
    }
}
