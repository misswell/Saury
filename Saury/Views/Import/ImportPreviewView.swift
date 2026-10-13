import SwiftUI
import SwiftData

/// 「导入订阅」这一趟的两屏：先看清楚这份文件打算怎么改本机数据，导完再看实际写进去多少。
///
/// 任务书 §3.2 的规矩在这一屏落成三个具体行为：
/// 1. 疑似重复默认跳过，要人在这一行上点一下才算确认；
/// 2. 改一个字段只重算那一行，另外那些行的勾选原样留着；
/// 3. 只有按下「导入」那一下才碰库 —— 中途关掉，库里一条都不会变。
struct ImportPreviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var preferences: SubPreferences

    /// 文件刚解析完那一份，只用来显示「文件里本来写了什么」，不参与编辑。
    private let fileTable: ImportParser.Table
    /// 比对本机数据用的快照：进来一次就固定，免得导入后列表变化引起重算。
    private let local: [SubscriptionDraft]

    @State private var table: ImportParser.Table
    @State private var plan: ImportConflictResolver.Plan
    @State private var editingTarget: EditTarget?
    @State private var report: ImportReport?
    @State private var failure: String?
    @State private var confirmingOverwrite = false

    init(table: ImportParser.Table, local: [SubscriptionDraft]) {
        fileTable = table
        self.local = local
        _table = State(initialValue: table)
        _plan = State(initialValue: ImportConflictResolver.resolve(table: table, local: local))
    }

    /// 纠错面板跟着某一行走：行 id 就是它的身份。
    private struct EditTarget: Identifiable { let id: UUID }

    var body: some View {
        NavigationStack {
            Group {
                if let report {
                    ReportView(report: report)
                } else {
                    preview
                }
            }
            .navigationTitle(report == nil ? "导入预览" : "导入结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                if report == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(confirmTitle, action: confirmImport)
                            .bold()
                            .disabled(plan.projection.isNothingSelected || failure != nil)
                    }
                }
            }
        }
        .sheet(item: $editingTarget) { target in
            if let index = table.rows.firstIndex(where: { $0.id == target.id }),
               let fileRow = fileTable.rows.first(where: { $0.id == target.id }),
               let item = plan.items.first(where: { $0.id == target.id }) {
                ImportRowEditor(table: $table,
                                rowIndex: index,
                                fileRow: fileRow,
                                local: item.local)
                    .environmentObject(preferences)
            }
        }
        // 纠错写回的是同一份解析结果：行数、勾选、统计都从它重新算，界面就不会各说各话。
        .onChange(of: table.rows) { _, _ in
            plan = ImportConflictResolver.reresolve(table: table, local: local, previous: plan)
        }
        .alert(overwritingCount == 1 ? "确认按文件里的值覆盖本机那 1 条？" : "确认按文件里的值覆盖本机 \(overwritingCount) 条？",
               isPresented: $confirmingOverwrite) {
            Button("再检查一下", role: .cancel) {}
            Button("确认覆盖", role: .destructive, action: commit)
        } message: {
            Text("这几行只按名字对上了本机的订阅，金额、周期或日期跟本机记的不一样。覆盖之后本机那几条以文件里的值为准，原来的数字找不回来。其余勾选的行只是新增，不动本机数据。")
        }
    }

    // MARK: - 预览那一屏

    /// 单独一个逗号在行尾看着像被截断了，说成名字才认得出这是分隔符还是漏了字。
    private var delimiterText: String {
        switch table.delimiter {
        case ",": return "逗号（,）"
        case ";": return "分号（;）"
        case "\t": return "制表符"
        default: return "「\(table.delimiter)」"
        }
    }

    private var preview: some View {
        List {
            Section {
                infoRow("文件", table.fileName)
                infoRow("格式", "\(table.format.rawValue) · \(table.rows.count) 行")
                infoRow("编码", table.encodingName)
                if table.format == .csv { infoRow("分隔符", delimiterText) }
                ForEach(Array(plan.notes.enumerated()), id: \.offset) { _, note in
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("这份文件")
            }

            Section {
                counters
                Button(plan.isEverythingSelected ? "取消全选" : "全选可导入的行") {
                    withAnimation(Motion.ui) { plan = plan.settingAll(plan.isEverythingSelected == false) }
                    SelectionHaptics.tick()
                }
            } header: {
                Text("会怎么写")
            } footer: {
                Text(failureText)
            }

            ForEach(plan.previewSections) { section in
                Section {
                    ForEach(Array(section.items.enumerated()), id: \.element.id) { offset, item in
                        row(item)
                            .staged(min(offset, 7), enabled: offset < 8)
                    }
                } header: {
                    Text("\(section.kind.rawValue)（\(section.items.count)）")
                } footer: {
                    Text(section.kind.footnote)
                }
            }

            if let loss = table.eventLossSummary {
                Section {
                    Text(loss).font(.footnote).foregroundStyle(.orange)
                } header: {
                    Text("历史记录")
                } footer: {
                    Text("文件里有历史记录写了订阅名，但那份订阅不在这次的写入里。想连历史一起恢复，请用「从备份恢复」打开完整备份包。")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(SauryTheme.background)
        .animation(Motion.ui, value: plan.projection)
    }

    private var counters: some View {
        let projection = plan.projection
        return HStack(spacing: 8) {
            counter("新增", projection.creates, Color(hex: "#30D158") ?? .green)
            counter("更新", projection.updates, accent)
            counter("跳过", projection.skips, .secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func counter(_ title: String, _ value: Int, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(SauryTheme.amountFont(size: 24))
                .contentTransition(.numericText())
                .foregroundStyle(value > 0 ? tint : Color.secondary)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: SauryTheme.cardRadius, style: .continuous)
            .fill(SauryTheme.surface))
    }

    @ViewBuilder
    private func row(_ item: ImportConflictResolver.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                selectionMark(item)
                SubscriptionIconView(subscription: item.row.draft.iconPreviewSubject(), size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.row.displayName.isEmpty ? "（没有名字）" : item.row.displayName)
                        .font(.body.weight(.medium))
                    Text(valueLine(item))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(item.headline)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(item.isBlocked ? .orange : .secondary)
                }
                Spacer(minLength: 4)
                decisionControl(item)
                editButton(item)
            }

            ForEach(Array(item.row.issues.enumerated()), id: \.offset) { _, issue in
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(Array(item.reasons.enumerated()), id: \.offset) { _, reason in
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(item.diffs) { diff in
                Text(diff.text)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(item.decision == .update ? .primary : .secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func selectionMark(_ item: ImportConflictResolver.Item) -> some View {
        if item.isBlocked {
            Image(systemName: "circle.dashed")
                .font(.body)
                .foregroundStyle(.orange)
                .accessibilityLabel("这一行要先纠错")
        } else {
            Button { toggle(item) } label: {
                Image(systemName: item.isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.body)
                    .foregroundStyle(item.isSelected ? accent : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isSelected ? "这一行会导，点一下跳过" : "这一行不导，点一下选上")
        }
    }

    /// 只有一种走法时不给一个空菜单：新增 / 更新能选的才做成菜单。
    @ViewBuilder
    private func decisionControl(_ item: ImportConflictResolver.Item) -> some View {
        let label = capsule(item.decision.shortTitle, selected: item.isSelected)
        if item.isBlocked || item.allowedDecisions.count < 2 {
            label
        } else {
            Menu {
                ForEach(item.allowedDecisions) { option in
                    Button { choose(option, for: item) } label: {
                        Label(option.title,
                              systemImage: option == item.decision ? "checkmark.circle.fill" : option.symbol)
                    }
                }
            } label: {
                label
            }
        }
    }

    private func capsule(_ text: String, selected: Bool) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(selected ? accent : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous)
                .fill(selected ? accent.opacity(0.16) : SauryTheme.surfaceElevated))
    }

    private func editButton(_ item: ImportConflictResolver.Item) -> some View {
        Button {
            editingTarget = EditTarget(id: item.id)
            SelectionHaptics.tick()
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.footnote)
                .foregroundStyle(item.isBlocked ? accent : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("修改这一行的字段")
    }

    private func valueLine(_ item: ImportConflictResolver.Item) -> String {
        let draft = item.row.draft
        // 读不出来的那列宁可空着：金额没 parse 出来时 draft 里躺着一个 0，
        // 印成「0.00」就像文件里真写了 0 一样。
        let money = item.row.failedFields.contains(.amount) ? "—"
            : Money(minorUnits: draft.priceMinorUnits, currencyCode: draft.currencyCode).amountText
        let cycle: String
        if item.row.failedFields.contains(.cycle) {
            cycle = "—"
        } else {
            cycle = draft.cycle == .custom ? "每 \(max(draft.customMonths, 1)) 个月" : draft.cycle.title
        }
        return "\(money)/\(cycle) · \(item.row.sourceLabel)"
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private var failureText: String {
        if let failure {
            return "这次没写进去：\(failure)\n按「关闭」离开，本机还是原样。"
        }
        return "现在按「关闭」离开，本机一条都不会变。"
    }

    // MARK: - 操作

    private func toggle(_ item: ImportConflictResolver.Item) {
        let shouldImport = item.isSelected == false
        withAnimation(Motion.ui) { plan = plan.setting(rows: [item.id], shouldImport) }
        shouldImport ? SelectionHaptics.tick() : SelectionHaptics.impact(.light)
    }

    private func choose(_ decision: ImportConflictResolver.Decision, for item: ImportConflictResolver.Item) {
        withAnimation(Motion.ui) { plan = plan.setting(rowID: item.id, decision: decision) }
        SelectionHaptics.tick()
    }

    private var confirmTitle: String { "导入 \(plan.projection.creates + plan.projection.updates) 条" }

    /// 会把本机已有的数改掉的那些行：确认前专门问一遍。判据在解析器那边，有测试守着。
    private var overwritingCount: Int {
        plan.items.filter { ImportConflictResolver.willChangeLocalValues($0) }.count
    }

    private func confirmImport() {
        if overwritingCount > 0 { confirmingOverwrite = true } else { commit() }
    }

    private func commit() {
        do {
            let counts = try SubscriptionRepository(context: modelContext).importRows(plan.writes)
            let made = ImportReport(
                counts: counts,
                skipped: plan.items.filter { $0.decision == .skip }
                    .map { "\($0.row.sourceLabel)「\($0.row.displayName)」— \($0.headline)" },
                eventLoss: table.eventLossSummary,
                libraryTotal: try? modelContext.fetchCount(FetchDescriptor<Subscription>()),
                eventsTotal: try? modelContext.fetchCount(FetchDescriptor<SubscriptionEvent>()))
            withAnimation(Motion.page) { report = made }
            SelectionHaptics.success()
        } catch {
            // 一条都没写才敢说「没成功」：`importRows` 整批校验通过才落盘，库还是原样。
            failure = error.localizedDescription
            SelectionHaptics.error()
        }
    }

    private var accent: Color { Color(hex: preferences.accentHex) ?? .accentColor }
}

// MARK: - 结果

/// 导入完的实况。数字来自写入通道返回的计数和库里的真实条数，
/// 不是预览里那份「预计会写」的投影。
struct ImportReport {
    let counts: SubscriptionRepository.RestoreCounts
    let skipped: [String]
    let eventLoss: String?
    let libraryTotal: Int?
    let eventsTotal: Int?

    var written: Int { counts.subscriptionsInserted + counts.subscriptionsUpdated }

    var headline: String { written == 0 ? "一条都没写进去" : "已写入 \(written) 条订阅" }

    var detail: String {
        var parts: [String] = ["新增 \(counts.subscriptionsInserted) 条",
                               "更新 \(counts.subscriptionsUpdated) 条"]
        let events = counts.eventsInserted + counts.eventsUpdated
        if events > 0 { parts.append("历史记录 \(events) 条") }
        if counts.eventsSkipped > 0 { parts.append("\(counts.eventsSkipped) 条历史找不到主人，没写") }
        if let libraryTotal { parts.append("库里现在共 \(libraryTotal) 条订阅") }
        return parts.joined(separator: "，")
    }
}

struct ReportView: View {
    let report: ImportReport

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: report.written > 0 ? "checkmark.seal.fill" : "tray.fill")
                        .font(.title2)
                        .foregroundStyle(report.written > 0 ? Color(hex: "#30D158") ?? .green : Color.secondary)
                    Text(report.headline)
                        .font(.headline)
                }
                Text(report.detail)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let loss = report.eventLoss {
                    Text(loss).font(.footnote).foregroundStyle(.orange)
                }

                if report.skipped.isEmpty == false {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("这次没导的 \(report.skipped.count) 行")
                            .font(.subheadline.weight(.semibold))
                        ForEach(Array(report.skipped.enumerated()), id: \.offset) { _, line in
                            Text("· \(line)").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
        .background(SauryTheme.background)
    }
}

extension SubscriptionDraft {
    /// 预览借用统一的图标渲染，不需要一条真的订阅：造一条游离对象，不插进任何上下文。
    func iconPreviewSubject() -> Subscription {
        Subscription(id: id,
                     name: trimmedName.isEmpty ? "未命名" : trimmedName,
                     plan: plan,
                     iconSymbolName: iconSymbolName,
                     iconImageFile: iconImageFile,
                     iconColorHex: iconColorHex,
                     colorSpec: colorSpec)
    }
}
