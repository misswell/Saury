import SwiftUI
import SwiftData
import UserNotifications

enum QJTab: String, CaseIterable {
    case home, calendar, billing, history

    var title: String {
        switch self {
        case .home: return "首页"
        case .calendar: return "日历"
        case .billing: return "账单"
        case .history: return "历史"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .calendar: return "calendar"
        case .billing: return "chart.pie.fill"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RenewalItem.nextRenewalDate) private var items: [RenewalItem]
    @Query(sort: \DecisionRecord.happenedAt, order: .reverse) private var decisions: [DecisionRecord]

    @State private var selectedTab: QJTab = .home
    @State private var showingQuickAdd = false
    @State private var showingAdd = false
    @State private var showingSettings = false
    @State private var showingDetail = false
    @State private var selectedItemID: UUID?
    @State private var externalDraft: ExternalRenewalDraft?

    var body: some View {
        NavigationStack {
            ZStack {
                QJTheme.canvas.ignoresSafeArea()
                Group {
                    switch selectedTab {
                    case .home:
                        HomeView(items: activeItems, onOpenItem: openItem, onAdd: beginCustomAdd, onSettings: { showingSettings = true })
                    case .calendar:
                        CalendarView(items: activeItems, onOpenItem: openItem, onSettings: { showingSettings = true })
                    case .billing:
                        BillingView(items: activeItems, onOpenItem: openItem, onSettings: { showingSettings = true })
                    case .history:
                        HistoryView(decisions: decisions, onSettings: { showingSettings = true })
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                QJTabBar(selectedTab: $selectedTab, onAdd: { showingQuickAdd = true }, onSettings: { showingSettings = true })
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $showingAdd) {
            AddEditSubscriptionView(initialDraft: externalDraft)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingQuickAdd) {
            QuickAddSubscriptionView(onSelect: beginTemplateAdd, onCustom: beginCustomAdd)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingDetail) {
            if let item = selectedItem {
                SubscriptionDetailView(item: item)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .task {
            DemoDataSeeder.seedIfNeeded(in: modelContext)
            if let draft = ExternalInputStore.consume() {
                externalDraft = draft
                showingAdd = true
            }
            if let pending = NotificationActionHandler.consumePendingAction() {
                await NotificationActionHandler.apply(pending, in: modelContext)
            }
            WidgetSnapshotStore.update(items: items)
            await ReminderScheduler.shared.rescheduleAll(items: items)
        }
        .onChange(of: items.count) { _, _ in
            WidgetSnapshotStore.update(items: items)
            Task { await ReminderScheduler.shared.rescheduleAll(items: items) }
        }
    }

    private var activeItems: [RenewalItem] {
        items.filter { $0.status == .active }.sorted { $0.nextRenewalDate < $1.nextRenewalDate }
    }

    private var selectedItem: RenewalItem? {
        guard let selectedItemID else { return nil }
        return items.first(where: { $0.id == selectedItemID })
    }

    private func openItem(_ item: RenewalItem) {
        selectedItemID = item.id
        showingDetail = true
    }

    private func beginCustomAdd() {
        showingQuickAdd = false
        externalDraft = nil
        DispatchQueue.main.async { showingAdd = true }
    }

    private func beginTemplateAdd(_ draft: ExternalRenewalDraft) {
        showingQuickAdd = false
        externalDraft = draft
        DispatchQueue.main.async { showingAdd = true }
    }
}

struct QJTabBar: View {
    @Binding var selectedTab: QJTab
    let onAdd: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            tabButton(.home)
            tabButton(.billing)
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 50, height: 50)
                    .background(QJTheme.ink)
                    .foregroundStyle(QJTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .accessibilityLabel("添加订阅")
            .frame(maxWidth: .infinity)
            tabButton(.calendar)
            tabButton(.history)
            Button(action: onSettings) {
                VStack(spacing: 3) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 17, weight: .medium))
                    Text("设置")
                        .font(.caption2)
                }
                .foregroundStyle(QJTheme.subtle)
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .accessibilityLabel("设置")
        }
        .padding(7)
        .background(.ultraThinMaterial)
        .background(QJTheme.elevated.opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 23, style: .continuous).stroke(QJTheme.line, lineWidth: 0.7))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
    }

    @ViewBuilder
    private func tabButton(_ tab: QJTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 17, weight: .medium))
                Text(tab.title)
                    .font(.caption2)
            }
            .foregroundStyle(selectedTab == tab ? QJTheme.accent : QJTheme.subtle)
            .frame(maxWidth: .infinity, minHeight: 50)
        }
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
    }
}
