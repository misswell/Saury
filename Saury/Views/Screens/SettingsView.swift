import SwiftUI
import SwiftData
import UserNotifications
import UniformTypeIdentifiers
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ExpiryItem.expiryDate) private var items: [ExpiryItem]
    @Query(sort: \ExpiryEvent.happenedAt, order: .reverse) private var events: [ExpiryEvent]
    @Query(sort: \ProductTemplate.createdAt) private var templates: [ProductTemplate]
    @AppStorage(QJPreferences.defaultReminderDaysKey) private var defaultReminderDays = 3
    @AppStorage(QJPreferences.reminderHourKey) private var reminderHour = 9
    @AppStorage(QJPreferences.defaultCurrencyCodeKey) private var defaultCurrencyCode = "CNY"
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var showingPaywall = false
    @State private var showingImporter = false
    @State private var importAlert: SettingsAlert?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    notificationRow
                    HStack {
                        SettingsRow(symbol: "calendar.badge.clock", title: "提前提醒天数", detail: "并入每个分类的默认提醒计划")
                        Picker("提前提醒天数", selection: $defaultReminderDays) {
                            ForEach(ReminderPolicy.defaultDayChoices, id: \.self) { days in
                                Text(String(format: "%d 天前", days)).tag(days)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .tint(QJTheme.accent)
                    }
                    HStack {
                        SettingsRow(symbol: "clock", title: "默认提醒时间", detail: "提前整天数的通知落在这一小时")
                        Picker("默认提醒时间", selection: $reminderHour) {
                            ForEach([6, 7, 8, 9, 10, 12, 14, 16, 18, 20, 21], id: \.self) { hour in
                                Text(String(format: "%02d:00", hour)).tag(hour)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .tint(QJTheme.accent)
                    }
                    HStack {
                        SettingsRow(symbol: "yensign.circle", title: "默认币种", detail: "新建物品时使用的默认值")
                        Picker("默认币种", selection: $defaultCurrencyCode) {
                            Text("人民币 ¥").tag("CNY")
                            Text("美元 $").tag("USD")
                            Text("港币 HK$").tag("HKD")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .tint(QJTheme.accent)
                    }
                    NavigationLink { LocationManagementView() } label: {
                        SettingsRow(symbol: "signpost.right", title: "位置管理", detail: "编辑添加物品时的位置建议")
                    }
                    Button { openAppleSubscriptions() } label: {
                        SettingsRow(symbol: "apple.logo", title: "管理 Apple 订阅", detail: "打开系统订阅页面")
                    }
                } header: { Text("提醒与默认值") }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("默认值只影响之后新建的物品")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(QJTheme.ink)
                        Text("已经保存的物品会继续使用它自己的提醒计划。")
                            .font(.caption)
                            .foregroundStyle(QJTheme.subtle)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    ShareLink(item: DataExportService.jsonText(items: items, events: events, templates: templates), subject: Text("期见数据备份")) {
                        SettingsRow(symbol: "square.and.arrow.up", title: "导出数据", detail: "生成一份本机 JSON 备份")
                    }
                    Button { showingImporter = true } label: {
                        SettingsRow(symbol: "square.and.arrow.down", title: "导入数据", detail: "从 JSON 备份恢复物品、历史、商品模板和位置")
                    }
                    Button { showingPaywall = true } label: {
                        SettingsRow(symbol: "sparkles", title: "期见终身版", detail: "一次购买，解锁无限物品和扫描识别")
                    }
                } header: { Text("数据与功能") }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("隐私优先")
                            .font(.subheadline.weight(.medium))
                        Text("物品记录、提醒计划和扫描结果都保存在这台设备上。期见不会读取银行、邮件或其他 App 的数据。")
                            .font(.caption)
                            .foregroundStyle(QJTheme.subtle)
                    }
                    .padding(.vertical, 5)
                } header: { Text("关于期见") }

                Section {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(appVersion).foregroundStyle(QJTheme.subtle)
                    }
                    Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
                        SettingsRow(symbol: "questionmark.circle", title: "使用帮助", detail: "如何添加和处理提醒")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(QJTheme.canvas)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }
        .task { notificationStatus = await ReminderScheduler.shared.authorizationStatus() }
        .sheet(isPresented: $showingPaywall) { PaywallView().presentationDetents([.medium]) }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .alert(item: $importAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("好的")))
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return version + " (" + build + ")"
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: url)
            let summary = try DataExportService.importJSON(data, into: modelContext)
            Task { await ExpiryActionCenter.shared.refresh(in: modelContext) }
            importAlert = SettingsAlert(title: "导入完成", message: summary.message)
        } catch {
            importAlert = SettingsAlert(title: "导入失败", message: error.localizedDescription)
        }
    }

    private var notificationRow: some View {
        Button {
            if notificationStatus == .notDetermined {
                Task { notificationStatus = (await ReminderScheduler.shared.requestAuthorization()) ? .authorized : .denied }
            } else {
                openSystemSettings()
            }
        } label: {
            SettingsRow(symbol: "bell.badge", title: "通知权限", detail: notificationDetail)
        }
    }

    private var notificationDetail: String {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: return "已开启"
        case .denied: return "已关闭 · 点此打开系统设置"
        default: return "添加第一件物品后开启"
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func openAppleSubscriptions() {
        guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else { return }
        UIApplication.shared.open(url)
    }
}

private struct SettingsAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct SettingsRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(QJTheme.accent)
                .frame(width: 32, height: 32)
                .background(QJTheme.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(QJTheme.ink)
                Text(detail).font(.caption).foregroundStyle(QJTheme.subtle)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(QJTheme.subtle)
        }
        .padding(.vertical, 4)
    }
}

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = PurchaseStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(QJTheme.accent)
                Text("期见终身版").font(.title2.weight(.medium))
                Spacer()
                Button("关闭") { dismiss() }.foregroundStyle(QJTheme.subtle)
            }
            Text("一次购买，长期安心。")
                .font(.title3.weight(.medium))
            VStack(alignment: .leading, spacing: 11) {
                Label("无限物品记录", systemImage: "checkmark.circle.fill")
                Label("扫描包装自动填写", systemImage: "checkmark.circle.fill")
                Label("桌面小组件与快捷指令", systemImage: "checkmark.circle.fill")
                Label("完整数据导出", systemImage: "checkmark.circle.fill")
            }
            .foregroundStyle(QJTheme.calm)
            Spacer()
            if let product = store.product {
                Button {
                    Task { await store.purchase(product) }
                } label: {
                    Text("解锁 · \(product.displayPrice)")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(QJTheme.ink)
                        .foregroundStyle(QJTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            } else {
                Text("购买项目将在 App Store Connect 配置后显示。")
                    .font(.caption)
                    .foregroundStyle(QJTheme.subtle)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(22)
        .background(QJTheme.canvas)
        .task { await store.load() }
    }
}
