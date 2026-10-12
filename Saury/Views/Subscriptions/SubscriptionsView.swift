import SwiftUI
import SwiftData

/// 订阅页：月/季/年合计、搜索、三种视图、排序、左滑操作。
struct SubscriptionsView: View {
    var onAdd: () -> Void
    var onSelectTab: (MainTab) -> Void

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var preferences: SubPreferences
    @Query private var subscriptions: [Subscription]

    enum Route: Hashable {
        case archived
        case trash
    }

    @State private var period: SubscriptionStats.StatsPeriod = .month
    @State private var searchText = ""
    @State private var sortSeed = UUID()
    @State private var selectedSubscription: Subscription?
    @State private var editingSubscription: Subscription?
    @State private var showingFilter = false
    @State private var showingSelection = false
    @State private var selection: Set<UUID> = []

    var body: some View {
        VStack(spacing: 10) {
            toolbarRow
                .padding(.horizontal, SauryTheme.screen)
                .padding(.top, 4)
                .staged(0, edge: .top)
            searchBar
                .padding(.horizontal, SauryTheme.screen)
                .staged(1, edge: .top)
            summaryRow
                .padding(.horizontal, SauryTheme.screen)
                .staged(2, edge: .top)
            if items.isEmpty {
                emptyState
            } else {
                contentList
                    .id(preferences.subscriptionsViewMode)
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
        }
        .animation(Motion.page, value: preferences.subscriptionsViewMode)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(SauryTheme.background)
        .navigationTitle("")
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationDestination(for: Route.self) { route in
            switch route {
            case .archived: ArchiveListView()
            case .trash: TrashView()
            }
        }
        .sheet(item: $selectedSubscription) { subscription in
            SubscriptionDetailView(subscription: subscription) {
                editingSubscription = subscription
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $editingSubscription) { subscription in
            AddSubscriptionView(editing: subscription)
        }
        .sheet(isPresented: $showingFilter) {
            SubscriptionFilterSheet()
                .presentationDragIndicator(.visible)
        }
        .overlay(alignment: .bottom) {
            // `.animation(value:)` 必须留在 overlay 里面：挂到页面上会把
            // 整棵子树的动画事务改成 nil，列表增删就再也不动。
            Group {
                if showingSelection {
                    selectionBar
                        .transition(.offset(y: 96).combined(with: .opacity))
                }
            }
            .animation(Motion.pop, value: showingSelection)
        }
    }

    /// 选择订阅模式的批量操作条。
    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text("已选 \(selection.count)")
                .font(.footnote.weight(.semibold))
                .contentTransition(.numericText())
                .animation(Motion.ui, value: selection.count)
            Spacer()
            Button {
                SelectionHaptics.impact(.medium)
                for subscription in items where selection.contains(subscription.id) {
                    subscription.pinnedAt = Date()
                    subscription.markUpdated()
                }
                showingSelection = false
            } label: {
                Label("置顶", systemImage: "pin")
            }
            .disabled(selection.isEmpty)
            Button {
                SelectionHaptics.impact(.medium)
                for subscription in items where selection.contains(subscription.id) {
                    subscription.archivedAt = Date()
                    subscription.markUpdated()
                }
                showingSelection = false
            } label: {
                Label("归档", systemImage: "archivebox")
            }
            .disabled(selection.isEmpty)
            Button(role: .destructive) {
                SelectionHaptics.impact(.heavy)
                for subscription in items where selection.contains(subscription.id) {
                    subscription.deletedAt = Date()
                    subscription.markUpdated()
                }
                showingSelection = false
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(selection.isEmpty)
            Button("完成") { showingSelection = false }
                .fontWeight(.semibold)
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(SauryTheme.surfaceElevated)
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        )
        .padding(.horizontal, SauryTheme.screen)
        .padding(.bottom, 74)
    }

    private var stats: SubscriptionStats {
        SubscriptionStats(
            subscriptions: subscriptions,
            defaultCurrency: preferences.defaultCurrency,
            rates: ExchangeRateStore.shared.rates
        )
    }

    // MARK: - 工具行

    private var toolbarRow: some View {
        HStack(spacing: 10) {
            PeriodToggle(selection: $period)
            Spacer()
            Menu {
                Picker("视图", selection: Binding(
                    get: { preferences.subscriptionsViewMode },
                    set: { preferences.subscriptionsViewMode = $0 }
                )) {
                    ForEach(SubscriptionListViewMode.allCases, id: \.self) { mode in
                        Label(mode.title, systemImage: symbol(for: mode)).tag(mode)
                    }
                }
            } label: {
                Image(systemName: symbol(for: preferences.subscriptionsViewMode))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(SauryTheme.surface))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(Pressable(scale: 0.9))
            Button {
                showingFilter = true
            } label: {
                Image(systemName: preferences.listFilters.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(SauryTheme.surface))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(Pressable(scale: 0.9))
            .accessibilityLabel("筛选")
            Menu {
                Section("排序") {
                    ForEach(SubscriptionSort.allCases, id: \.self) { sort in
                        Button {
                            preferences.subscriptionsSort = sort
                        } label: {
                            if preferences.subscriptionsSort == sort {
                                Label(sort.title, systemImage: "checkmark")
                            } else {
                                Text(sort.title)
                            }
                        }
                    }
                    Button("再随机一次") {
                        SelectionHaptics.tick()
                        withAnimation(Motion.page) { sortSeed = UUID() }
                    }
                }
                Section {
                    Button {
                        SelectionHaptics.tick()
                        showingSelection = true
                        selection = []
                    } label: {
                        Label("选择订阅", systemImage: "checkmark.circle")
                    }
                    NavigationLink(value: Route.archived) { Label("归档订阅", systemImage: "archivebox") }
                    NavigationLink(value: Route.trash) { Label("回收站", systemImage: "trash") }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(SauryTheme.surface))
            }
            .buttonStyle(Pressable(scale: 0.9))
        }
    }

    private func symbol(for mode: SubscriptionListViewMode) -> String {
        switch mode {
        case .list: return "list.bullet"
        case .compactList: return "list.bullet.rectangle"
        case .card: return "square.grid.2x2"
        case .compact: return "circle.grid.2x2"
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索名称、套餐、分类或备注", text: $searchText)
                .textInputAutocapitalization(.never)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Capsule().fill(SauryTheme.surface))
        .animation(Motion.pop, value: searchText.isEmpty)
    }

    private var summaryRow: some View {
        let total = stats.total(for: period)
        return HStack(spacing: 4) {
            Text("共 \(items.count) 个")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Spacer()
            Text("合计")
                .font(.footnote)
                .foregroundStyle(.secondary)
            AnimatedNumber(value: total.majorValue,
                           format: { Money(minorUnits: Int(($0 * 100).rounded()),
                                           currencyCode: total.currencyCode).formattedGrouped },
                           font: .system(size: 13, weight: .semibold, design: .rounded))
        }
        .animation(Motion.ui, value: items.count)
        .animation(Motion.ui, value: period)
    }

    // MARK: - 数据

    private var items: [Subscription] {
        var result = subscriptions.filter { $0.deletedAt == nil && $0.archivedAt == nil }
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let lowered = text.lowercased()
            result = result.filter { subscription in
                let category = preferences.category(withID: subscription.categoryRawValue)
                return subscription.name.lowercased().contains(lowered)
                    || subscription.plan.lowercased().contains(lowered)
                    || subscription.notes.lowercased().contains(lowered)
                    || subscription.paymentMethod.lowercased().contains(lowered)
                    || category.name.lowercased().contains(lowered)
            }
        }
        let filters = preferences.listFilters
        if filters.isActive {
            result = result.filter { subscription in
                (filters.categoryIDs.isEmpty || filters.categoryIDs.contains(subscription.categoryRawValue))
                    && (filters.states.isEmpty || filters.states.contains(subscription.state))
                    && (filters.paymentMethods.isEmpty || filters.paymentMethods.contains(subscription.paymentMethod))
                    && (filters.currencies.isEmpty || filters.currencies.contains(subscription.currencyCode))
            }
        }
        return SubscriptionSorter.sort(result, by: preferences.subscriptionsSort, seed: sortSeed, period: period, preferences: preferences)
    }

    // MARK: - 列表

    /// grouped 排序时按「周期订阅 / 买断·一次性」分节。
    private var groupedSections: [(title: String, items: [Subscription])] {
        [
            ("周期订阅", items.filter { $0.cycle.isRecurring }),
            ("买断 · 一次性", items.filter { !$0.cycle.isRecurring })
        ].filter { !$0.items.isEmpty }
    }

    @ViewBuilder
    private func sectionedRows(sectionTitle: String?) -> some View {
        if let sectionTitle {
            Text(sectionTitle)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, SauryTheme.screen)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var contentList: some View {
        switch preferences.subscriptionsViewMode {
        case .list, .compactList:
            List {
                if preferences.subscriptionsSort.groupsItems {
                    ForEach(groupedSections, id: \.title) { section in
                        Section(section.title) {
                            ForEach(section.items) { subscription in
                                row(for: subscription, compact: preferences.subscriptionsViewMode == .compactList)
                            }
                        }
                    }
                } else {
                    ForEach(items) { subscription in
                        row(for: subscription, compact: preferences.subscriptionsViewMode == .compactList)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        case .card:
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                    ForEach(Array(items.enumerated()), id: \.element) { index, subscription in
                        SubscriptionCardCell(subscription: subscription, compact: false) {
                            selectedSubscription = subscription
                        }
                        .contextMenu { contextActions(for: subscription) }
                        .staged(min(index, 8))
                    }
                }
                .padding(.horizontal, SauryTheme.screen)
            }
        case .compact:
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(Array(items.enumerated()), id: \.element) { index, subscription in
                        SubscriptionCardCell(subscription: subscription, compact: true) {
                            selectedSubscription = subscription
                        }
                        .contextMenu { contextActions(for: subscription) }
                        .staged(min(index, 9))
                    }
                }
                .padding(.horizontal, SauryTheme.screen)
            }
        }
    }

    @ViewBuilder
    private func row(for subscription: Subscription, compact: Bool) -> some View {
        Group {
            if showingSelection {
                Button {
                    SelectionHaptics.tick()
                    if selection.contains(subscription.id) {
                        selection.remove(subscription.id)
                    } else {
                        selection.insert(subscription.id)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selection.contains(subscription.id) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .foregroundStyle(selection.contains(subscription.id) ? Color.accentColor : Color.secondary)
                            .contentTransition(.symbolEffect(.replace))
                            .scaleEffect(selection.contains(subscription.id) ? 1 : 0.9)
                        if compact {
                            CompactListRow(subscription: subscription)
                        } else {
                            SubscriptionListRow(subscription: subscription, onTap: {})
                        }
                    }
                    .animation(Motion.pop, value: selection.contains(subscription.id))
                }
                .buttonStyle(.plain)
            } else if compact {
                Button { selectedSubscription = subscription } label: {
                    CompactListRow(subscription: subscription)
                }
                .buttonStyle(.plain)
            } else {
                SubscriptionListRow(subscription: subscription) {
                    selectedSubscription = subscription
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: SauryTheme.screen, bottom: 0, trailing: SauryTheme.screen))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            swipeActions(for: subscription)
        }
        .contextMenu { contextActions(for: subscription) }
    }

    private func swipeActions(for subscription: Subscription) -> some View {
        HStack {
            Button {
                subscription.pinnedAt = subscription.isPinned ? nil : Date()
                subscription.markUpdated()
            } label: {
                Label(subscription.isPinned ? "取消置顶" : "置顶", systemImage: "pin")
            }
            .tint(.orange)

            Button {
                subscription.archivedAt = Date()
                subscription.markUpdated()
            } label: {
                Label("归档", systemImage: "archivebox")
            }
            .tint(.indigo)

            Button(role: .destructive) {
                subscription.deletedAt = Date()
                subscription.markUpdated()
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func contextActions(for subscription: Subscription) -> some View {
        Button { selectedSubscription = subscription } label: {
            Label("查看详情", systemImage: "info.circle")
        }
        Button { editingSubscription = subscription } label: {
            Label("编辑", systemImage: "pencil")
        }
        Button {
            subscription.pinnedAt = subscription.isPinned ? nil : Date()
            subscription.markUpdated()
        } label: {
            Label(subscription.isPinned ? "取消置顶" : "置顶", systemImage: "pin")
        }
        Divider()
        Button(role: .destructive) {
            subscription.deletedAt = Date()
            subscription.markUpdated()
        } label: {
            Label("移入回收站", systemImage: "trash")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "archivebox")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.secondary)
                .staged(0)
            Text("还没有订阅")
                .font(.headline)
                .staged(1)
            Text("点右下角的 + 记下第一笔。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .staged(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

/// 排序逻辑独立出来，测试才好覆盖。
@MainActor
enum SubscriptionSorter {
    static func sort(
        _ items: [Subscription],
        by sort: SubscriptionSort,
        seed: UUID,
        period: SubscriptionStats.StatsPeriod,
        preferences: SubPreferences
    ) -> [Subscription] {
        let calendar = BillingMath.calendar
        var result: [Subscription] = items
        switch sort {
        case .grouped:
            result.sort { a, b in
                let nextA = BillingMath.nextChargeDate(for: a) ?? .distantFuture
                let nextB = BillingMath.nextChargeDate(for: b) ?? .distantFuture
                return nextA < nextB
            }
        case .nextCharge:
            result.sort { a, b in
                let nextA = BillingMath.nextChargeDate(for: a) ?? .distantFuture
                let nextB = BillingMath.nextChargeDate(for: b) ?? .distantFuture
                if nextA == nextB { return a.name < b.name }
                return nextA < nextB
            }
        case .duration:
            result.sort { a, b in a.startDate < b.startDate }
        case .addedDate:
            result.sort { a, b in a.createdAt > b.createdAt }
        case .priceDescending, .priceAscending:
            let rates = ExchangeRateStore.shared.rates
            result.sort { a, b in
                let valueA = Double(a.myAmount.converting(to: preferences.defaultCurrency, rates: rates).minorUnits)
                let valueB = Double(b.myAmount.converting(to: preferences.defaultCurrency, rates: rates).minorUnits)
                return sort == .priceDescending ? valueA > valueB : valueA < valueB
            }
        case .name:
            result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .random:
            var hasher = Hasher()
            hasher.combine(seed)
            let token = hasher.finalize()
            result = result.shuffled().sorted { a, b in
                (a.id.uuidString.hashValue ^ token) % 1000 < (b.id.uuidString.hashValue ^ token) % 1000
            }
        }
        // 置顶永远在最前，随机除外。
        if sort != .random {
            result.sort {
                let pinnedL = $0.pinnedAt != nil
                let pinnedR = $1.pinnedAt != nil
                if pinnedL != pinnedR { return pinnedL }
                if pinnedL && pinnedR { return ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast) }
                return false
            }
        }
        _ = calendar
        return result
    }
}
