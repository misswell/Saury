import SwiftUI
import SwiftData
import CloudKit

/// 「iCloud 与数据」：同步状态与开关、修复图标、以本机数据为准，
/// 加上导出 / 导入 / 清空。所有云端操作失败都只是页脚一句话，不打断人。
struct ICloudDataView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var preferences: SubPreferences
    @EnvironmentObject private var cloud: CloudSyncEngine
    @Query private var subscriptions: [Subscription]
    @Query private var events: [SubscriptionEvent]

    @State private var shareItems: [Any]?
    @State private var showingShare = false
    @State private var showingImportPicker = false
    @State private var confirmClear = false
    @State private var confirmForcePush = false
    @State private var toast: String?

    var body: some View {
        List {
            Section {
                // iCloud 同步组
                Toggle("自动同步", isOn: Binding(
                    get: { cloud.autoSyncEnabled },
                    set: { cloud.autoSyncEnabled = $0 }
                ))
                HStack {
                    Label("iCloud 账户", systemImage: "person.icloud")
                    Spacer()
                    Text(CloudSyncEngine.cloudKitCompiledIn ? cloud.accountTitle : "未配置能力")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Label("上次同步", systemImage: "clock.arrow.circlepath")
                    Spacer()
                    Text(lastSyncText).foregroundStyle(.secondary)
                }
                HStack {
                    Label("云端订阅", systemImage: "cloud")
                    Spacer()
                    Text(remoteCountText)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await cloud.syncNow(context: modelContext) }
                } label: {
                    HStack {
                        Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if cloud.isSyncing { ProgressView() }
                    }
                }
                Button {
                    Task { await cloud.repairIcons(context: modelContext) }
                } label: {
                    Label("修复图标", systemImage: "photo.badge.arrow.down")
                }
                Button {
                    confirmForcePush = true
                } label: {
                    Label("以本机数据为准", systemImage: "iphone.and.arrow.right")
                }
                HStack {
                    Label("图标已全部同步", systemImage: "checkmark.icloud")
                    Spacer()
                    Text("\(subscriptions.compactMap(\.iconImageFile).count)")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text(cloudFooter)
            }

            Section {
                Button {
                    share(markdown: true)
                } label: {
                    Label("分享为 Markdown（适合 AI）", systemImage: "doc.text")
                }
                Button {
                    share(markdown: false)
                } label: {
                    Label("分享为 JSON", systemImage: "curlybraces")
                }
                Button {
                    copyWithPrompt()
                } label: {
                    Label("复制（含 AI 提示词）", systemImage: "doc.on.doc")
                }
            } header: {
                Text("导出")
            } footer: {
                Text("数据只发到你选择的 App，期见不会上传到任何服务器。Markdown 末尾带了一段提示词，粘到豆包 / Kimi 等 AI 就能直接分析你的订阅。")
            }

            Section {
                Button {
                    showingImportPicker = true
                } label: {
                    Label("导入订阅", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("导入")
            } footer: {
                Text("支持通用 CSV，以及期见导出的 JSON。导入前可在预览页勾选、改错，跳过疑似重复。")
            }

            Section {
                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Label("清空所有数据", systemImage: "trash")
                }
            } header: {
                Text("清空数据")
            } footer: {
                Text("永久删除全部订阅，包括已归档和回收站里的。分类、支付方式等设置会保留。此操作不可撤销。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(SauryTheme.background)
        .navigationTitle("iCloud 与数据")
        .navigationBarTitleDisplayMode(.inline)
        .task { await cloud.refreshAccountStatus() }
        .overlay(alignment: .top) {
            // 动画只归这棵子树：挂到整页上会覆盖掉页面自己的动画事务。
            Group {
                if let toast {
                    Text(toast)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color(white: 0.15).opacity(0.95)))
                        .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
                        .task {
                            try? await Task.sleep(for: .seconds(2))
                            withAnimation(Motion.ui) { self.toast = nil }
                        }
                }
            }
            .animation(Motion.pop, value: toast)
        }
        .onChange(of: toast) { _, newValue in
            if newValue != nil { SelectionHaptics.success() }
        }
        .sheet(isPresented: $showingShare) {
            if let shareItems {
                ActivityShareSheet(items: shareItems)
            }
        }
        .fileImporter(isPresented: $showingImportPicker, allowedContentTypes: [.json, .commaSeparatedText, .plainText]) { result in
            if case .success(let url) = result {
                Task {
                    let count = try? SubscriptionImportExport.importFile(at: url, into: modelContext)
                    if let count {
                        toast = "已导入 \(count) 条订阅"
                    }
                }
            }
        }
        .alert("以本机数据为准？", isPresented: $confirmForcePush) {
            Button("取消", role: .cancel) {}
            Button("确定", role: .destructive) {
                Task { await cloud.pushLocalAsSource(context: modelContext) }
            }
        } message: {
            Text("会把这台设备上的每一条订阅都标记为最新版本并上传。其他设备上同一条订阅的不同版本会被本机这一份覆盖；只存在于其他设备的订阅不受影响，仍会同步过来。不会删除任何数据。")
        }
        .alert("清空所有数据？", isPresented: $confirmClear) {
            Button("取消", role: .cancel) {}
            Button("继续", role: .destructive) { clearAll() }
        } message: {
            Text("会永久删除全部订阅（包括已归档和回收站里的）以及它们的图标。分类、支付方式等设置会保留。")
        }
    }

    private var remoteCountText: String {
        guard let count = cloud.remoteCount else { return "这台设备还没收到" }
        return String(count)
    }

    private var lastSyncText: String {
        guard let lastSync = cloud.lastSync else { return "从未同步" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter.string(from: lastSync)
    }

    private var cloudFooter: String {
        if let message = cloud.lastMessage {
            return message
        }
        return """
        开启后，订阅数据以及自定义分类、支付方式、基础货币、默认提醒天数，都会通过 iCloud 同步到登录同一 Apple 账户的其他设备。图标会在后台逐张从 iCloud 下载；若长时间没动静，点「修复图标」重新拉取。

        「自动同步」要在每台设备上分别打开。两台设备的「云端订阅」条数一样，才说明同步真的通了；对不上就在条数少的那台点一次「立即同步」。

        如果两台设备上的同一条订阅内容不一样、怎么同步都不变，在你认为正确的那台设备上点「以本机数据为准」。
        """
    }

    // MARK: - 导出

    private func markdownText() -> String {
        SubscriptionImportExport.exportMarkdown(
            subscriptions: subscriptions,
            defaultCurrency: preferences.defaultCurrency,
            categories: preferences.categories,
            includeAIPrompt: true
        )
    }

    private func share(markdown: Bool) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(markdown ? "期见订阅.md" : "期见订阅.json")
        if markdown {
            try? markdownText().write(to: temp, atomically: true, encoding: .utf8)
        } else {
            try? SubscriptionImportExport.exportJSON(subscriptions: subscriptions)
                .write(to: temp, options: .atomic)
        }
        shareItems = [temp]
        showingShare = true
    }

    private func copyWithPrompt() {
        UIPasteboard.general.string = markdownText()
        toast = "已复制到剪贴板"
    }

    private func clearAll() {
        for subscription in subscriptions { modelContext.delete(subscription) }
        for event in events { modelContext.delete(event) }
        try? modelContext.save()
        Task {
            await SubscriptionScheduler.shared.refill(
                subscriptions: [],
                defaultReminderDays: preferences.defaultReminderDays,
                hour: preferences.reminderHour,
                enabled: preferences.notificationsEnabled
            )
            toast = "已清空全部订阅"
        }
    }
}
