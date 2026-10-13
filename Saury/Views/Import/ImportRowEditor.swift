import SwiftUI

/// 单行纠错：改哪个字段就只重算那一行，文件原文留在旁边给人对照。
///
/// 这里刻意不做「一键修好所有问题」：字段读不出来多半是文件本身的写法问题，
/// 替用户猜一个值，比让他自己点一下更容易把错的数字导进库。
/// 每次改动都写回同一份 `table`，预览页的勾选和统计由它重新算出来 —— 两处看到的是同一个真相。
struct ImportRowEditor: View {
    @Binding var table: ImportParser.Table
    let rowIndex: Int
    /// 文件刚解析完的那一份：`raw` 不会被编辑改动，用它显示「文件里本来写了什么」。
    let fileRow: ImportParser.Row
    /// 本机对得上的那一条（没有就是新增）。改了字段要立刻看见会不会覆盖它的数字。
    let local: SubscriptionDraft?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var preferences: SubPreferences

    /// 币种和周期两个选择器共用这一层的一张 sheet：同层挂两张，
    /// 前一张刚收起时点后一张就是「点了没反应」（任务书 §6.3）。
    private enum Layer: Identifiable {
        case currency, cycle

        var id: Self { self }
    }

    @State private var layer: Layer?

    private var row: ImportParser.Row { table.rows[rowIndex] }
    private var categories: [SubscriptionCategory] { table.categories }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(statusLine)
                            .font(.body.weight(.medium))
                        Text(row.sourceLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(row.issues.enumerated()), id: \.offset) { _, issue in
                        Label(issue, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    ForEach(Array(row.advisories.enumerated()), id: \.offset) { _, tip in
                        Text(tip).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("现在这一条")
                }

                Section {
                    ForEach(ImportParser.Field.editorOrder, id: \.self) { field in
                        fieldBlock(field)
                    }
                } footer: {
                    Text("改哪一列，导入时就带哪一列；没动的按文件里的原样。套餐、备注、支付方式、状态这几列不参与纠错，文件里写了就照搬。")
                }

                if let local {
                    Section {
                        infoLine("本机名字", local.name)
                        infoLine("本机金额", Money(minorUnits: local.priceMinorUnits,
                                                   currencyCode: local.currencyCode).amountText)
                        infoLine("本机周期", cycleText(local.cycle, months: local.customMonths))
                        infoLine("本机起始日", QJFormat.longDate(local.startDate))
                        ForEach(ImportConflictResolver.diffs(of: row, against: local,
                                                             categories: categories)) { diff in
                            Text(diff.text)
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.primary)
                        }
                    } header: {
                        Text("本机对得上的那条")
                    } footer: {
                        Text(row.carriesWholeRecord
                                ? "这是 App 自己导出的旧版 JSON，本来就是那条订阅的完整快照：确认后会整条覆盖本机这一条（编号不变）。"
                                : "只有文件里写了的那几列会覆盖本机，其余（提醒天数、拼车、图标、备注）保持本机原样。")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(SauryTheme.background)
            .navigationTitle("改这一条")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.bold()
                }
            }
            .sheet(item: $layer) { layer in
                switch layer {
                case .currency:
                    CurrencyPickerSheet(selection: currencySelection)
                        .environmentObject(preferences)
                case .cycle:
                    CyclePickerSheet(cycle: cycleSelection, customMonths: monthsSelection)
                }
            }
        }
    }

    // MARK: - 单个字段

    @ViewBuilder
    private func fieldBlock(_ field: ImportParser.Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(field.rawValue).font(.subheadline.weight(.medium))
                Spacer()
                if fileRow.raw[field] != nil {
                    Button("当作没写") { apply(field, nil, haptic: true) }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("文件里没这一列").font(.caption).foregroundStyle(.secondary)
                }
            }
            control(field)
            if let original = fileRow.raw[field], original != row.raw[field] {
                Text("文件里写的是「\(original)」")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .animation(Motion.ui, value: row.raw[field])
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func control(_ field: ImportParser.Field) -> some View {
        switch field {
        case .name:
            typedField(TextField("订阅名称", text: textBinding(.name))
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never))
        case .amount:
            typedField(TextField("金额", text: textBinding(.amount))
                .keyboardType(.decimalPad))
        case .currency:
            valueButton("\(row.draft.currencyCode) · \(CurrencyCatalog.symbol(for: row.draft.currencyCode))") {
                layer = .currency
            }
        case .cycle:
            valueButton(cycleText(row.draft.cycle, months: row.draft.customMonths)) {
                layer = .cycle
            }
        case .startDate:
            DatePicker(selection: dateSelection, displayedComponents: .date) { Text("起始日期") }
                .datePickerStyle(.compact)
                // 上面已经有「起始日期」这一列的标题了，控件自己别再喊一遍。
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(SauryTheme.surfaceElevated))
        case .category:
            Menu {
                ForEach(categories) { category in
                    Button { apply(.category, category.name, haptic: true) } label: {
                        Label(category.name,
                              systemImage: category.id == chosenCategoryID ? "checkmark.circle.fill" : "circle")
                    }
                }
            } label: {
                controlLabel(chosenCategoryName)
            }
            .buttonStyle(.plain)
        }
    }

    private func typedField(_ field: some View) -> some View {
        field
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(SauryTheme.surfaceElevated))
    }

    private func valueButton(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { controlLabel(text) }
            .buttonStyle(.plain)
    }

    /// 三个「从一列里挑一个」的字段共用这一种长相：币种、周期、分类不该长得不一样。
    private func controlLabel(_ text: String) -> some View {
        HStack {
            Text(text).foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(SauryTheme.surfaceElevated))
    }

    private func infoLine(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    // MARK: - 绑定

    private func textBinding(_ field: ImportParser.Field) -> Binding<String> {
        Binding(get: { row.raw[field] ?? "" }, set: { apply(field, $0) })
    }

    private var currencySelection: Binding<String> {
        Binding(get: { row.draft.currencyCode }, set: { apply(.currency, $0, haptic: true) })
    }

    private var cycleSelection: Binding<BillingCycle> {
        Binding(get: { row.draft.cycle },
                set: { apply(.cycle, cycleText($0, months: row.draft.customMonths), haptic: true) })
    }

    private var monthsSelection: Binding<Int> {
        Binding(get: { max(row.draft.customMonths, 1) },
                set: { apply(.cycle, cycleText(row.draft.cycle, months: $0)) })
    }

    private var dateSelection: Binding<Date> {
        Binding(get: { row.draft.startDate }, set: { apply(.startDate, QJFormat.longDate($0)) })
    }

    /// 文件里的分类 id 在本机已经不存在时，界面显示的是导入后真正会落的「其他」，
    /// 而不是一个本机根本没有的编号。
    private var chosenCategoryID: String {
        categories.contains(where: { $0.id == row.draft.category })
            ? row.draft.category : DefaultCategories.fallback.id
    }

    private var chosenCategoryName: String {
        categories.first(where: { $0.id == chosenCategoryID })?.name ?? DefaultCategories.fallback.name
    }

    private func apply(_ field: ImportParser.Field, _ text: String?, haptic: Bool = false) {
        table = table.editing(rowID: row.id, field: field, to: text)
        if haptic { SelectionHaptics.tick() }
    }

    private func cycleText(_ cycle: BillingCycle, months: Int) -> String {
        cycle == .custom ? "每 \(max(months, 1)) 个月" : cycle.title
    }

    /// 顶部那一句跟着改动实时变：改好了它自己会说「能导了」，没说就是还没修好。
    /// 读不出来的具体是哪一列，由下面那排橙色提示逐条说，这里不重复一遍。
    private var statusLine: String {
        if row.isBlocked {
            return row.issues.count > 1 ? "有 \(row.issues.count) 处读不出来，先改下面的字段"
                                       : "还导不进去，先改下面的字段"
        }
        let money = Money(minorUnits: row.draft.priceMinorUnits, currencyCode: row.draft.currencyCode).amountText
        return "\(row.draft.trimmedName) · \(money)/\(cycleText(row.draft.cycle, months: row.draft.customMonths))"
    }
}
