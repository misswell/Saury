import SwiftUI
import SwiftData
import CloudKit

/// 「iCloud 与数据」：同步状态与开关、修复图标、以本机数据为准，
/// 加上导出 / 导入 / 清空。所有云端操作失败都只是页脚一句话，不打断人。
struct ICloudDataView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var preferences: SubPreferences
    @EnvironmentObject private var sync: SyncCoordinator
    @Query private var subscriptions: [Subscription]
    @Query private var events: [SubscriptionEvent]

    /// 这一页的三张 sheet（系统分享、备份预览、导入预览）收成一条：同层只认一张。
    /// 两个 `fileImporter` 留在各自的 Bool 上 —— 系统文件面板是全屏模态的，
    /// 它开着的时候这一页的按钮一个都点不到，本来就互斥；
    /// 硬并进来要靠派生 Binding 去猜它什么时候关，那是拿假设换风险。
    private enum Layer: Identifiable {
        case share
        case backup(BackupService.Contents)
        case importPreview(ImportParser.Table)

        var id: String {
            switch self {
            case .share: return "share"
            case .backup(let contents): return "backup:\(contents.id)"
            case .importPreview(let table): return "import:\(table.id)"
            }
        }
    }

    @State private var shareItems: [Any]?
    @State private var layer: Layer?
    @State private var showingImportPicker = false
    @State private var showingBackupPicker = false
    @State private var confirmClear = false
    @State private var confirmForcePush = false
    @State private var toast: String?
    @State private var integrityReport: StoreIntegrityReport?
    /// 这一份只给本页用：`PersistenceController.lastRecovery` 是静态值，
    /// 点了「我看过了」之后光清它不会让这页重画，得有个能被 SwiftUI 观察到的状态。
    @State private var recoveryNote: StoreRecovery? = PersistenceController.lastRecovery

    var body: some View {
        List {
            // 库出过事就必须一直写在这页上：用户有权知道自己现在存的是不是临时库。
            if let recovery = recoveryNote {
                Section {
                    Label(recovery.reason.userText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(recovery.message).font(.footnote)
                    ForEach(recovery.keptAside.map(\.lastPathComponent), id: \.self) { name in
                        HStack {
                            Text(name).font(.caption2.monospaced())
                            Spacer()
                            Text("原样留着").foregroundStyle(.secondary).font(.caption)
                        }
                    }
                    Button("我看过了，不再提示") {
                        PersistenceController.acknowledgeRecovery()
                        toast = "留底的文件还在原目录，只是不再每次启动都提示"
                    }
                } header: {
                    Text(recoveryHeader(recovery))
                } footer: {
                    Text("旧文件只是改了名字，仍在原来的目录里，没有被删除。用「从备份恢复」或「导入订阅」可以把数据找回来；手上没有备份的话，把这些文件发给能读懂旧版本的设备也还有机会。这件事在你说「看过了」之前会一直写在这里。")
                }
            }
            if let failure = PersistenceController.lastOpenFailure {
                Section {
                    Label(failure.userText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(failure.advice).font(.footnote)
                } header: {
                    Text("现在跑在临时库上")
                } footer: {
                    Text("这一趟里写的东西，关掉 App 就没了，所以原来的库一个字节都没动。修好之后再打开，数据还在原处。")
                }
            }

            Section {
                Button {
                    runIntegrityCheck()
                } label: {
                    HStack {
                        Label("检查现在的库", systemImage: "stethoscope")
                        Spacer()
                        if let report = integrityReport {
                            Text(integrityResultText(report))
                                .foregroundStyle(report.isClean ? Color.secondary : Color.orange)
                                .font(.footnote)
                        }
                    }
                }
                if let report = integrityReport {
                    ForEach(report.issues) { issue in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(issue.kind.title).font(.footnote.weight(.semibold))
                            Text(issue.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("数据体检")
            } footer: {
                Text(integrityFooter)
            }

            Section {
                // 能力没通的时候，这一整组只留开关和那句话说清楚：
                // 不显示「上次同步」「云端条数」，因为那些数根本没来源。
                Toggle("自动同步", isOn: Binding(
                    get: { sync.autoSyncEnabled },
                    set: { sync.autoSyncEnabled = $0 }
                ))
                HStack {
                    Label("iCloud 能力", systemImage: "checkmark.icloud")
                    Spacer()
                    Text(sync.access.displayText)
                        .foregroundStyle(sync.access.isReady ? Color.secondary : Color.orange)
                        .multilineTextAlignment(.trailing)
                }
                if let mismatch = sync.access.containerMismatch {
                    HStack {
                        Label("容器对不上", systemImage: "exclamationmark.triangle.fill")
                        Spacer()
                        Text(mismatch).foregroundStyle(.orange).font(.caption.monospaced())
                    }
                }
                if sync.access.isReady {
                    HStack {
                        Label("iCloud 账户", systemImage: "person.icloud")
                        Spacer()
                        Text(sync.account.title)
                            .foregroundStyle(sync.account.isAvailable ? Color.secondary : Color.orange)
                    }
                    HStack {
                        Label("当前阶段", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if sync.phase.isBusy { ProgressView() }
                        Text(sync.phase.title).foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("上次同步完成", systemImage: "clock.arrow.circlepath")
                        Spacer()
                        Text(lastSyncText).foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("云端", systemImage: "cloud")
                        Spacer()
                        Text(remoteCountText).foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await sync.requestSync(reason: .manual) }
                    } label: {
                        HStack {
                            Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if sync.phase.isBusy { ProgressView() }
                        }
                    }
                    .disabled(sync.phase.isBusy)
                    Button {
                        Task { await sync.repairIcons() }
                    } label: {
                        Label("修复图标", systemImage: "photo.badge.arrow.down")
                    }
                    Button {
                        confirmForcePush = true
                    } label: {
                        Label("以本机数据为准", systemImage: "iphone.and.arrow.right")
                    }
                }
                // 失败和结果都平铺在这一页上，不弹打断人的窗。
                if let failure = sync.phase.failure {
                    Label(failure, systemImage: "xmark.icloud")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
                if let report = sync.phase.report {
                    Text(report.summaryText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Label("本机图标文件", systemImage: "photo.on.rectangle")
                    Spacer()
                    // 只报磁盘上真实存在的张数。「已全部同步」这种话没有凭据，不能说。
                    Text("\(subscriptions.compactMap(\.iconImageFile).count) 张在本机")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text(cloudFooter)
            }

            if sync.conflicts.isEmpty == false {
                Section {
                    ForEach(sync.conflicts) { conflict in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(conflict.subject.rawValue)·\(conflict.name.prefix(8))")
                                    .font(.footnote.weight(.semibold))
                                Spacer()
                                Text(conflict.remoteUpdatedAt.formatted(date: .omitted, time: .shortened))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(conflict.note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("清掉这些留档") { sync.clearConflictLog() }
                } header: {
                    Text("两边都不动的地方（\(sync.conflicts.count) 处）")
                } footer: {
                    Text("判不出哪一份更新的时候，谁都不覆盖：云端那一份原样留着在这里。本机数据没有被动过，你也没有丢东西 —— 想保留哪一边，就在对应设备上改成想要的内容，再点「以本机数据为准」。")
                }
            }

            Section {
                Button {
                    makeFullBackup()
                } label: {
                    Label("完整备份（含图标、分类与设置）", systemImage: "archivebox.fill")
                }
                Button {
                    showingBackupPicker = true
                } label: {
                    Label("从备份恢复", systemImage: "square.and.arrow.down.on.square")
                }
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
                Text("""
                完整备份是一份带清单的压缩包：订阅、历史事件、图标原图、自定义分类、支付方式和设置都在里面，每一块都有自己的校验码，坏在哪一块会说出来。
                JSON 和 Markdown 只是给人看的数据交换格式，里面不含图标图片，别当备份用。
                导出的文件只写在本机临时目录，由你决定发给谁；期见不会把它上传到任何服务器。
                """)
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
        .task { await sync.refreshAccountStatus() }
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
        .sheet(item: $layer) { layer in
            switch layer {
            case .share:
                ActivityShareSheet(items: shareItems ?? [])
            case .backup(let contents):
                BackupRestoreSheet(contents: contents)
                    .environmentObject(preferences)
            case .importPreview(let table):
                ImportPreviewView(table: table, local: subscriptions.map { BackupSubscription($0).draft })
                    .environmentObject(preferences)
            }
        }
        .fileImporter(isPresented: $showingImportPicker, allowedContentTypes: [.json, .commaSeparatedText, .plainText]) { result in
            switch result {
            case .success(let url): prepareImport(url)
            case .failure(let error): toast = "选文件失败：\(error.localizedDescription)"
            }
        }
        .fileImporter(isPresented: $showingBackupPicker,
                      allowedContentTypes: [BackupService.documentType, .json, .data]) { result in
            switch result {
            case .success(let url): loadBackup(url)
            case .failure(let error): toast = "选文件失败：\(error.localizedDescription)"
            }
        }
        .alert("以本机数据为准？", isPresented: $confirmForcePush) {
            Button("取消", role: .cancel) {}
            Button("确定", role: .destructive) {
                Task { await sync.pushLocalAsSource() }
            }
        } message: {
            Text("会把这台设备上的每一条订阅、每一条记录和四组设置（分类、支付方式、基础货币、提醒）都盖上这一刻的时间整包上传，归档和删除状态也照本机的写。其他设备上同一条订阅的不同版本会被本机这一份覆盖；只存在于其他设备的订阅不受影响，仍会同步过来。本机彻底删除过的订阅会带着删除凭据推上去，别的设备上那一条会进回收站，不会被硬删。不会删除本机任何数据。")
        }
        .alert("清空所有数据？", isPresented: $confirmClear) {
            Button("取消", role: .cancel) {}
            Button("继续", role: .destructive) { clearAll() }
        } message: {
            // 图标这一句必须跟着真正会发生的事改：清空现在会把只属于被删那些订阅的图标文件
            // 一起释放（`SubscriptionRepository.releaseIconFiles`），几条共用一张图的那张留下。
            // 「存储管理」里剩下的清的是换过图标之后的历史文件，不是这一脚漏下的。
            Text("会永久删除全部订阅（包括已归档和回收站里的）。每条订阅独占的图标文件跟着一起删掉，几条订阅共用一张图时那张会留下；换过图标留下的旧文件可以在「存储管理」里清。分类、支付方式等设置会保留。")
        }
    }

    private var remoteCountText: String {
        guard let remote = sync.remote else { return "这台设备还没读过云端" }
        return "\(remote.subscriptions) 条订阅 · \(remote.events) 条记录 · \(remote.tombstones) 张删除凭据"
    }

    private var integrityFooter: String {
        if let report = integrityReport, !report.isClean {
            return "体检只列出问题，不会自己改数据：没有你确认过的删除或覆盖，这一页一次都不会做。"
        }
        return "对着现在的库数一遍：每条事件认不认得出自己的订阅、编号有没有重复、金额和周期成不成样子、图标文件还在不在、分类还认不认得。查出来只列给你看，不会自动改动任何一条。"
    }

    private func integrityResultText(_ report: StoreIntegrityReport) -> String {
        report.isClean ? "没问题" : "\(report.issues.count) 处对不上"
    }

    private func recoveryHeader(_ recovery: StoreRecovery) -> String {
        "本地库被重建过 · \(recovery.happenedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    /// 数据体检：读的是当前这个容器里的行，所以临时库也一样能查。
    private func runIntegrityCheck() {
        let report = StoreIntegrityReport.check(subscriptions: subscriptions,
                                                events: events,
                                                categories: preferences.categories)
        integrityReport = report
        toast = report.summaryText
        if report.isClean { SelectionHaptics.success() } else { SelectionHaptics.error() }
    }

    private var lastSyncText: String {
        guard let lastSync = sync.lastSuccess else { return "从未同步完成" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter.string(from: lastSync)
    }

    private var cloudFooter: String {
        // 能力没通的时候不能再写一段「开启后就会同步」——那一句话在描述一件
        // 这个包根本做不到的事。这里把缺的那一样原样端出来。
        guard sync.access.isReady else {
            return """
            这台设备上的这个包还没有 iCloud（CloudKit）能力：\(sync.access.displayText)。
            所以同步一条都没有发生，页面上也没有「上次同步」时间可以给你 —— 那个时间只有在真的完成一次同步之后才会写。

            能力是在 Apple 开发者后台给 App ID 勾上 iCloud、建好容器 \(CloudAccess.expectedContainerIdentifier) 和四类记录，再重新签名打包之后才有的。
            在那之前，「完整备份」和「从备份恢复」是唯一能把数据带到另一台设备的路。
            """
        }
        if let mismatch = sync.access.containerMismatch {
            return "签名里给的容器是 \(mismatch)，和这个 App 预期的 \(CloudAccess.expectedContainerIdentifier) 不是同一个：能用，但数据可能同步进了另一个库，这件事必须先说出来。"
        }
        return """
        开启后，订阅、历史事件、图标，以及自定义分类、支付方式、基础货币和默认提醒设置都会通过 iCloud 走到登录同一 Apple 账户的其他设备。删除也在这份范围里：一台删掉的，另一台会收进回收站，不会作为活记录再传回去。

        「自动同步」要在每台设备上分别打开。两台设备上面「云端」那一行的三个数一样，才说明这一次真的通了；对不上就在少的那台点「立即同步」。

        同一条订阅两边在同一时刻各写了一份、或者记录内容对不上时，谁都不会被盖掉：云端那份会原样留在下面的「两边都不动的地方」里，等你决定。
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
            do {
                try SubscriptionImportExport.exportJSON(subscriptions: subscriptions, events: events)
                    .write(to: temp, options: .atomic)
            } catch {
                toast = "导出失败：\(error.localizedDescription)"
                return
            }
        }
        shareItems = [temp]
        layer = .share
    }

    /// 完整备份：写进临时目录再交给系统分享，App 自己不留第二份副本。
    private func makeFullBackup() {
        do {
            let bundle = try BackupService.build(context: modelContext, preferences: preferences)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(bundle.fileName)
            try bundle.data.write(to: url, options: .atomic)
            shareItems = [url]
            layer = .share
            toast = bundle.summaryText
        } catch {
            // 没打包成功就不能顶着一句「备份好了」打开分享面板。
            toast = "备份失败：\(error.localizedDescription)"
        }
    }

    /// 导入的第一步：只把文件读成解析结果并打开预览页，一条都不写。
    /// 写库要等预览页上那一下「导入」—— §3.2 要求取消之后数据库不变。
    private func prepareImport(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            layer = .importPreview(try SubscriptionImportExport.parseTable(data: try Data(contentsOf: url),
                                                                             fileName: url.lastPathComponent))
        } catch {
            toast = "读不了这份文件：\(error.localizedDescription)"
        }
    }

    private func loadBackup(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            layer = .backup(try BackupService.read(Data(contentsOf: url)))
        } catch {
            toast = "读不了这份备份：\(error.localizedDescription)"
        }
    }

    private func copyWithPrompt() {
        UIPasteboard.general.string = markdownText()
        toast = "已复制到剪贴板"
    }

    private func clearAll() {
        do {
            try SubscriptionRepository(context: modelContext).wipeAll()
        } catch {
            // 清空没成也要说清楚，不能顶着一句「已清空」把数据留在库里。
            toast = error.localizedDescription
            return
        }
        Task {
            await SubscriptionScheduler.shared.refill(
                subscriptions: [],
                hour: preferences.reminderHour,
                enabled: preferences.notificationsEnabled
            )
            toast = "已清空全部订阅"
        }
    }
}
