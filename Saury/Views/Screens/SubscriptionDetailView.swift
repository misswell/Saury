import SwiftUI
import SwiftData

struct SubscriptionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allItems: [ExpiryItem]

    let item: ExpiryItem

    @State private var showingEdit = false
    @State private var showingAddBatch = false
    @State private var showingDeleteConfirmation = false
    @State private var showingRenewalDate = false
    @State private var renewalDate = Date()
    @State private var showingSnooze = false

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    /// 同一件商品的其他批次（方案 §30）。第一阶段没有 Product 表，
    /// 靠 productKey 把散落的记录认回来。
    private var siblings: [ExpiryItem] {
        allItems.filter { $0.id != item.id && $0.isActive && $0.productKey == item.productKey }
            .sorted { $0.effectiveExpiryDate < $1.effectiveExpiryDate }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ItemPhotoCard(item: item)

                    HStack(spacing: 12) {
                        ServiceIcon(item: item, size: 49, showsPhoto: false)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.title3.weight(.medium)).foregroundStyle(QJTheme.ink)
                            Text(item.subtitleText)
                                .font(.caption)
                                .foregroundStyle(QJTheme.subtle)
                        }
                        Spacer()
                    }

                    hero

                    VStack(spacing: 0) {
                        detailRow("到期", value: item.effectiveExpiryDate.qjDateText)
                        if let openedDate = item.openedDate {
                            detailRow("开封", value: "\(openedDate.qjDateText) · \(item.afterOpeningDays ?? 0) 天内")
                        }
                        if let location = item.location, !location.isEmpty { detailRow("位置", value: location) }
                        detailRow("数量", value: "\(item.quantityText) \(item.unit)")
                        if let batchNumber = item.batchNumber, !batchNumber.isEmpty { detailRow("批次号", value: batchNumber) }
                        if let brand = item.brand, !brand.isEmpty { detailRow("品牌", value: brand) }
                        if let barcode = item.barcode, !barcode.isEmpty { detailRow("条码", value: barcode) }
                        detailRow("提醒计划", value: reminderText)
                        detailRow("下一次提醒", value: nextReminderText)
                        detailRow("状态", value: item.state.title)
                        if let deadline = item.actionDeadline { detailRow("最晚处理", value: deadline.qjDateText) }
                        if let sourceURL = item.sourceURL, !sourceURL.isEmpty { detailRow("来源", value: sourceURL) }
                    }
                    .padding(.horizontal, 2)
                    .padding(.top, 16)

                    if !item.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("备注").font(.caption).foregroundStyle(QJTheme.subtle)
                            Text(item.notes).font(.subheadline).foregroundStyle(QJTheme.ink)
                        }
                        .padding(15)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .qjCard(fill: QJTheme.surface, radius: 17)
                        .padding(.top, 18)
                    }

                    if !siblings.isEmpty { siblingGroup }

                    Text("处理方式").font(.headline).padding(.top, QJMetric.section)

                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(ExpiryAction.available(for: item)) { action in
                            actionButton(action)
                        }
                    }

                    Button { showingAddBatch = true } label: {
                        Label("添加新批次", systemImage: "plus.circle")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(QJTheme.ink)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .qjCard(fill: QJTheme.elevated, radius: 14)
                    }
                    .padding(.top, 10)

                    if let url = item.sourceURL.flatMap(URL.init(string:)) {
                        Button { UIApplication.shared.open(url) } label: {
                            Label("打开管理页面", systemImage: "arrow.up.right.square")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(QJTheme.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, QJMetric.screen)
                .padding(.bottom, 28)
            }
            .background(QJTheme.canvas)
            .navigationTitle("物品详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("编辑", systemImage: "pencil") { showingEdit = true }
                        ShareLink(item: item.shareText) { Label("分享记录", systemImage: "square.and.arrow.up") }
                        Divider()
                        Button("删除记录", systemImage: "trash", role: .destructive) { showingDeleteConfirmation = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("更多操作")
                }
            }
        }
        .sheet(isPresented: $showingEdit) {
            AddEditSubscriptionView(item: item)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingAddBatch) {
            AddEditSubscriptionView(batchTemplate: item)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingRenewalDate) { renewalDateSheet }
        .sheet(isPresented: $showingSnooze) { SnoozeSheet(item: item) }
        .confirmationDialog("删除这条记录？", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                let context = modelContext
                Task {
                    await ExpiryActionCenter.shared.delete(item, in: context)
                    dismiss()
                }
            }
            Button("取消", role: .cancel) { }
        }
    }

    private var hero: some View {
        VStack(spacing: 5) {
            Text(item.daysRemaining >= 0 ? "\(item.daysRemaining) 天" : "已过期 \(-item.daysRemaining) 天")
                .font(.system(size: 40, weight: .medium, design: .rounded))
                .tracking(-1.6)
            Text(item.hasPrice ? "\(item.effectiveExpiryDate.qjDateText) 到期 · \(item.formattedPrice)" : "\(item.effectiveExpiryDate.qjDateText) 到期")
                .font(.subheadline)
        }
        .foregroundStyle(item.urgency.textTint)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(QJTheme.accentSoft)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.top, 22)
    }

    private var siblingGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("其他批次").font(.headline).padding(.top, QJMetric.section)
            VStack(spacing: 0) {
                ForEach(siblings) { sibling in
                    NavigationLink { SubscriptionDetailView(item: sibling) } label: {
                        ExpiryItemRow(item: sibling)
                    }
                    if sibling.id != siblings.last?.id { Divider().overlay(QJTheme.line) }
                }
            }
            .padding(.horizontal, QJMetric.card)
            .qjCard()
        }
    }

    private var reminderText: String {
        let offsets = item.reminderOffsets.sorted(by: >)
        guard !offsets.isEmpty else { return "未设置" }
        return offsets.map { ReminderPreset(minutesBefore: $0).title }.joined(separator: "、")
    }

    private var nextReminderText: String {
        guard let date = item.nextReminderDate else { return "本轮提醒已全部发出" }
        return date.qjShortDateTimeText
    }

    @ViewBuilder
    private var renewalDateSheet: some View {
        VStack(spacing: 18) {
            Text("续到什么时候？")
                .font(.headline)
            Text("这条记录没有周期，算不出下一次，只能由你定一个新的到期日。")
                .font(.caption)
                .foregroundStyle(QJTheme.subtle)
                .multilineTextAlignment(.center)
            DatePicker("新的到期日", selection: $renewalDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .tint(QJTheme.accent)
            HStack(spacing: 12) {
                Button("取消", role: .cancel) { showingRenewalDate = false }
                    .frame(maxWidth: .infinity)
                Button("确认续期") {
                    showingRenewalDate = false
                    Task {
                        await ExpiryActionCenter.shared.renew(item, to: renewalDate, in: modelContext)
                        dismiss()
                    }
                }
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .background(QJTheme.canvas)
        .presentationDetents([.medium])
    }

    @ViewBuilder
    private func detailRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).font(.subheadline).foregroundStyle(QJTheme.subtle)
            Spacer()
            Text(value).font(.subheadline).foregroundStyle(QJTheme.ink).multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(QJTheme.line).frame(height: 0.7) }
    }

    private func actionButton(_ action: ExpiryAction) -> some View {
        Button { handle(action) } label: {
            Label(action == .snoozed ? "稍后提醒" : action.title(for: item), systemImage: action.symbolName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(QJTheme.ink)
                .frame(maxWidth: .infinity, minHeight: 47)
                .background(QJTheme.elevated)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func handle(_ action: ExpiryAction) {
        // 详情页的「稍后提醒」问的是什么时候再提醒（方案 §45）；
        // 列表左滑才是直接推迟到明天。
        if action == .snoozed {
            showingSnooze = true
            return
        }
        // 没有周期的东西（护照、保修卡）算不出下一次，续期要先问一个新日期。
        if action == .renewed, item.nextOccurrence == nil {
            renewalDate = ExpiryEngine.calendar.date(byAdding: .year, value: 1, to: item.effectiveExpiryDate)
                ?? item.effectiveExpiryDate
            showingRenewalDate = true
            return
        }
        let context = modelContext
        Task { @MainActor in
            guard await ExpiryActionCenter.shared.perform(action, on: item, in: context) else { return }
            dismiss()
        }
    }
}

extension ExpiryItem {
    var shareText: String {
        var lines = ["期见｜\(name)", "到期：\(effectiveExpiryDate.qjDateText)（\(ExpiryUrgency.label(daysRemaining: daysRemaining))）"]
        if hasPrice { lines.append("金额：\(formattedPrice)") }
        lines.append("分类：\(category.title)")
        if recurrence.isRecurring { lines.append("周期：\(recurrence.title)") }
        if let location, !location.isEmpty { lines.append("位置：\(location)") }
        lines.append("提醒：\(reminderOffsets.sorted(by: >).map { ReminderPreset(minutesBefore: $0).title }.joined(separator: "、"))")
        return lines.joined(separator: "\n")
    }
}
