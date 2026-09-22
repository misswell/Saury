import SwiftUI
import SwiftData

struct SubscriptionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let item: RenewalItem

    @State private var showingEdit = false
    @State private var showingDeleteConfirmation = false

    private var days: Int { RenewalDateCalculator.daysUntil(item.nextRenewalDate) }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        ServiceIcon(item: item, size: 49)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.title3.weight(.medium)).foregroundStyle(QJTheme.ink)
                            Text(item.cycle.title + (item.isAutoRenewing ? " · 自动续费" : " · 手动续费"))
                                .font(.caption)
                                .foregroundStyle(QJTheme.subtle)
                        }
                        Spacer()
                    }

                    VStack(spacing: 5) {
                        Text(days >= 0 ? "\(days) 天" : "已到期")
                            .font(.system(size: 44, weight: .medium, design: .rounded))
                            .tracking(-1.6)
                        Text("\(item.nextRenewalDate.qjDateText) · 将续费 \(item.formattedAmount)")
                            .font(.subheadline)
                    }
                    .foregroundStyle(QJTheme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .background(QJTheme.accentSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.top, 22)

                    VStack(spacing: 0) {
                        detailRow("提醒计划", value: reminderText)
                        detailRow("下一次提醒", value: nextReminderText)
                        detailRow("状态", value: item.status.title)
                        if let cancelByDate = item.cancelByDate { detailRow("最晚取消", value: cancelByDate.qjDateText) }
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

                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            actionButton("已取消续费", symbol: "checkmark", tint: QJTheme.calm) { apply(.cancelled) }
                            actionButton("继续订阅", symbol: "arrow.clockwise", tint: QJTheme.ink) { apply(.continued) }
                        }
                        HStack(spacing: 10) {
                            actionButton("明天再提醒", symbol: "clock", tint: QJTheme.subtle) { apply(.snoozed) }
                            actionButton("暂停记录", symbol: "pause.fill", tint: QJTheme.subtle) { apply(.paused) }
                        }
                    }
                    .padding(.top, 22)

                    if let url = URL(string: item.managementURLString), !item.managementURLString.isEmpty {
                        Button { UIApplication.shared.open(url) } label: {
                            Label("打开订阅管理页面", systemImage: "arrow.up.right.square")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(QJTheme.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }
            .background(QJTheme.canvas)
            .navigationTitle("订阅详情")
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
        .confirmationDialog("删除这条记录？", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                modelContext.delete(item)
                try? modelContext.save()
                Task {
                    let allItems = (try? modelContext.fetch(FetchDescriptor<RenewalItem>())) ?? []
                    WidgetSnapshotStore.update(items: allItems)
                    await ReminderScheduler.shared.rescheduleAll(items: allItems)
                }
                dismiss()
            }
            Button("取消", role: .cancel) { }
        }
    }

    private var reminderText: String {
        item.reminderOffsets.sorted(by: >).map { ReminderPreset(minutesBefore: $0).title }.joined(separator: "、")
    }

    private var nextReminderText: String {
        guard let offset = item.reminderOffsets.sorted(by: >).last else { return "未设置" }
        return RenewalDateCalculator.notificationDate(for: item.nextRenewalDate, minutesBefore: offset).qjShortDateTimeText
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

    private func actionButton(_ title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: 47)
                .background(tint == QJTheme.calm ? QJTheme.calmSoft : QJTheme.elevated)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(QJTheme.line, lineWidth: 0.7))
        }
        .buttonStyle(.plain)
    }

    private func apply(_ action: DecisionAction) {
        Task { @MainActor in
            switch action {
            case .cancelled:
                item.status = .cancelled
                item.isAutoRenewing = false
            case .continued:
                if let next = RenewalDateCalculator.nextDate(for: item) {
                    item.nextRenewalDate = next
                    item.status = .active
                }
            case .paused:
                item.status = .paused
            case .snoozed:
                await ReminderScheduler.shared.scheduleSnooze(for: item)
            }
            modelContext.insert(DecisionRecord(renewalItemID: item.id, itemName: item.name, action: action, amountMinorUnits: item.amountMinorUnits, currencyCode: item.currencyCode))
            item.markUpdated()
            try? modelContext.save()
            let allItems = (try? modelContext.fetch(FetchDescriptor<RenewalItem>())) ?? []
            WidgetSnapshotStore.update(items: allItems)
            await ReminderScheduler.shared.rescheduleAll(items: allItems)
            if action != .snoozed { dismiss() }
        }
    }
}

extension RenewalItem {
    var shareText: String {
        "期见｜\(name)\n下次到期：\(nextRenewalDate.qjDateText)\n金额：\(formattedAmount)\n周期：\(cycle.title)\n提醒：\(reminderOffsets.map { ReminderPreset(minutesBefore: $0).title }.joined(separator: "、"))"
    }
}
