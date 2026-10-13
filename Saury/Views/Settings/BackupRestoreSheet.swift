import SwiftUI
import SwiftData

/// 「从备份恢复」这一趟的两屏：先看包里有什么并决定同一条怎么处置，恢复完再看实际结果。
///
/// 结果那一屏报的是**库里的真实数字**（校验过的那种），不是备份文件里写的期望值 ——
/// 半途失败、图标写不进去、事件找不到主人，都必须在这一屏上看得见。
struct BackupRestoreSheet: View {
    let contents: BackupService.Contents

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var preferences: SubPreferences

    @State private var mode = SubscriptionRepository.RestoreMode.overwrite
    @State private var report: BackupService.Report?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let report { BackupReportView(report: report) } else { preview }
            }
            .navigationTitle(report == nil ? "从备份恢复" : "恢复结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                if report == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(restoreButtonTitle, action: restore)
                            .bold()
                            .disabled(failure != nil)
                    }
                }
            }
        }
    }

    // MARK: - 恢复前

    private var restoreButtonTitle: String {
        contents.manifest.subscriptionCount > 0 ? "开始恢复" : "仍然恢复"
    }

    private var preview: some View {
        List {
            Section {
                row("备份时间", QJFormat.longDate(contents.manifest.createdAt))
                row("来自版本", contents.manifest.appVersion)
                row("订阅", "\(contents.manifest.subscriptionCount) 条")
                row("历史事件", "\(contents.manifest.eventCount) 条")
                row("图标", "\(contents.manifest.iconCount) 张")
                row("分类", "\(contents.payload.categories.count) 个")
                row("支付方式", "\(contents.payload.paymentMethods.count) 种")
            } header: {
                Text(contents.manifest.schemaVersion == BackupPayload.schemaVersion ? "这份备份" : "旧版备份")
            } footer: {
                if contents.manifest.schemaVersion == 1 {
                    Text("这是旧版 JSON 导出：里面没有稳定编号，重复恢复时按名字、金额、币种、周期和创建时间判重；图标图片本来就不在那份文件里。")
                }
            }

            if let warning = emptyWarning {
                Section { Text(warning).foregroundStyle(.orange) }
            }

            Section {
                ForEach(SubscriptionRepository.RestoreMode.allCases) { option in
                    Button {
                        mode = option
                    } label: {
                        HStack(alignment: .top) {
                            Image(systemName: mode == option ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(mode == option ? Color(hex: preferences.accentHex) ?? .accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.title)
                                Text(option.detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("本机已经有的那几条")
            } footer: {
                Text("两种都不会删除本机独有的数据。分类和支付方式一律合并：备份里没有的照旧留着，免得那些订阅被甩进「其他」。")
            }

            if !contents.payload.validate().isEmpty {
                Section("备份里可疑的地方") {
                    ForEach(Array(contents.payload.validate().enumerated()), id: \.offset) { _, issue in
                        Text(issue.text)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if let failure {
                Section {
                    Text(failure).foregroundStyle(.red).font(.footnote)
                } header: {
                    Text("没能开始恢复")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(SauryTheme.background)
    }

    private var emptyWarning: String? {
        guard contents.manifest.subscriptionCount == 0 else { return nil }
        return "这份备份里一条订阅都没有，恢复进去只会改设置，不会带来任何订阅。"
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func restore() {
        do {
            report = try BackupService.restore(data: contents.data,
                                               into: modelContext,
                                               preferences: preferences,
                                               mode: mode)
            SelectionHaptics.success()
        } catch {
            // 一条都没写进去才敢说「没成功」：库里保持原样，界面留在这一屏让人换个选择再试。
            failure = error.localizedDescription
            SelectionHaptics.warning()
        }
    }
}

/// 恢复完的实况报告。
private struct BackupReportView: View {
    let report: BackupService.Report

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: report.isClean ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(report.isClean ? Color(hex: "#30D158") ?? .green : .orange)
                    Text(report.isClean ? "恢复完成，校验通过" : "恢复结束了，但有几处要人工看一眼")
                        .font(.headline)
                }
                Text(report.summaryText)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !report.issues.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("备份体检出的问题").font(.subheadline.weight(.semibold))
                        ForEach(Array(report.issues.enumerated()), id: \.offset) { _, issue in
                            Text("· \(issue.text)").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(SauryTheme.background)
    }
}
