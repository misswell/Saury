import SwiftUI
import SwiftData
import os

/// 订阅页：月/季/年合计、搜索、四种视图、排序、左滑操作、批量选择。
struct SubscriptionsView: View {
    /// 这一页的导航栈由根视图持有：从归档页换一下 Tab 再回来，还停在归档页。
    @Binding var path: NavigationPath

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var preferences: SubPreferences
    @EnvironmentObject private var sheets: SheetRouter
    @Query private var subscriptions: [Subscription]
    @Query private var events: [SubscriptionEvent]

    /// 所有写库都经过这里：校验、落盘、报错、通知，页面只负责把结果说给用户。
    private var repository: SubscriptionRepository { SubscriptionRepository(context: modelContext) }
    /// 触感、撤销入口和那句话也经过这里：滑动、长按、批量、详情四条路必须一模一样。
    private var actions: SubscriptionActions { SubscriptionActions(repository: repository) }

    enum Route: Hashable {
        case archived
        case trash
    }

    @State private var period: SubscriptionStats.StatsPeriod = .month
    @State private var searchText = ""
    @State private var sortSeed = UUID()
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
                // 这里原来挂着 `.id(preferences.subscriptionsViewMode)`：换布局时整个容器重建。
                // 重建之后列表和列表之间也没了可比性 —— 同一条订阅在过渡里被拆掉再装一遍，
                // 看起来就是闪一下，而不是位置变了。去掉它，SwiftUI 才能拿稳定的订阅身份逐行对齐。
                contentList
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
        }
        .animation(Motion.page, value: preferences.subscriptionsViewMode)
#if DEBUG
        .task { await runListProbeIfNeeded() }
#endif
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
            Text(selectionSummary)
                .font(.footnote.weight(.semibold))
                .contentTransition(.numericText())
                .animation(Motion.ui, value: selection.count)
            Spacer()
            Button {
                actions.setPinned(chosenSubscriptions, true)
                showingSelection = false
            } label: {
                Label("置顶", systemImage: "pin")
            }
            .disabled(selection.isEmpty)
            Button {
                actions.archive(chosenSubscriptions)
                showingSelection = false
            } label: {
                Label("归档", systemImage: "archivebox")
            }
            .disabled(selection.isEmpty)
            Button {
                actions.setState(chosenSubscriptions, to: .inactive)
                showingSelection = false
            } label: {
                Label("停用", systemImage: "pause.circle")
            }
            .disabled(selection.isEmpty)
            Button(role: .destructive) {
                actions.moveToTrash(chosenSubscriptions)
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

    /// 批量目标按**全部订阅**解析：被当前搜索或筛选挡住的那几条一样要办事。
    /// 以前这里从 `items` 里挑，用户明明勾选了、却因为列表里看不见而静默不参与。
    private var chosenSubscriptions: [Subscription] {
        subscriptions.filter { selection.contains($0.id) }
    }

    private var selectionSummary: String {
        let visible = Set(items.map(\.id))
        let hidden = chosenSubscriptions.filter { !visible.contains($0.id) }.count
        return hidden > 0 ? "已选 \(selection.count)（含筛选外的 \(hidden)）" : "已选 \(selection.count)"
    }

    /// 合计对着哪几条算：没收窄时是全部订阅，收窄时是屏上这一批。
    /// 口径本身不变（还是「在册、非停用」），变的只是范围。
    private var summaryStats: SubscriptionStats {
        SubscriptionStats(
            subscriptions: SubscriptionQuery.summaryScope(items, all: subscriptions,
                                                          narrowed: isNarrowed),
            events: events,
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
                sheets.present(.filter)
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
        // 「共 N 个」数的是屏上这一批，合计就必须算同一批。
        // 搜「Netflix」只剩一条、右边却写着二十条订阅的月费，那个数不是用户正在看的东西。
        let total = summaryStats.total(for: period)
        return HStack(spacing: 4) {
            Text("共 \(items.count) 个")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Spacer()
            Text(isNarrowed ? "筛选中的合计" : "合计")
                .font(.footnote)
                .foregroundStyle(.secondary)
            AnimatedNumber(value: total.majorValue,
                           format: { Money(minorUnits: Int(($0 * 100).rounded()),
                                           currencyCode: total.currencyCode).formattedGrouped },
                           font: .system(size: 13, weight: .semibold, design: .rounded))
        }
        .animation(Motion.ui, value: items.count)
        .animation(Motion.ui, value: period)
        .animation(Motion.ui, value: isNarrowed)
    }

    // MARK: - 数据

    private var items: [Subscription] {
        SubscriptionQuery.sorted(
            SubscriptionQuery.visible(subscriptions,
                                      search: searchText,
                                      filters: preferences.listFilters,
                                      categoryName: { preferences.category(withID: $0).name }),
            by: preferences.subscriptionsSort,
            seed: sortSeed,
            defaultCurrency: preferences.defaultCurrency,
            rates: ExchangeRateStore.shared.rates
        )
    }

    /// 搜索或筛选正在收窄这一屏。空态文案和合计都跟着它换说法。
    private var isNarrowed: Bool {
        SubscriptionQuery.isNarrowed(search: searchText, filters: preferences.listFilters)
    }

    // MARK: - 列表

    /// grouped 排序时按「周期订阅 / 买断·一次性」分节。
    private var groupedSections: [(title: String, items: [Subscription])] {
        SubscriptionQuery.sections(of: items)
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
                            sheets.present(.detail(subscription.id))
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
                            sheets.present(.detail(subscription.id))
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
                Button { sheets.present(.detail(subscription.id)) } label: {
                    CompactListRow(subscription: subscription)
                }
                .buttonStyle(.plain)
            } else {
                SubscriptionListRow(subscription: subscription) {
                    sheets.present(.detail(subscription.id))
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
                actions.setPinned([subscription], !subscription.isPinned)
            } label: {
                Label(subscription.isPinned ? "取消置顶" : "置顶", systemImage: "pin")
            }
            .tint(.orange)

            // 停用在归档前面：它不改这条订阅在不在列表里，只是不再算它下一次扣费。
            // 反过来（重新启用）不放滑动区 —— 那一下必须说清要回到自动还是手动续费，
            // 猜一个「自动」等于替用户改了续费方式。恢复走长按菜单里的「状态」。
            if subscription.state != .inactive {
                Button {
                    actions.setState([subscription], to: .inactive)
                } label: {
                    Label("停用", systemImage: "pause.circle")
                }
                .tint(.teal)
            }

            Button {
                actions.archive([subscription])
            } label: {
                Label("归档", systemImage: "archivebox")
            }
            .tint(.indigo)

            Button(role: .destructive) {
                actions.moveToTrash([subscription])
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func contextActions(for subscription: Subscription) -> some View {
        Button { sheets.present(.detail(subscription.id)) } label: {
            Label("查看详情", systemImage: "info.circle")
        }
        Button { sheets.present(.edit(subscription.id)) } label: {
            Label("编辑", systemImage: "pencil")
        }
        Button {
            actions.setPinned([subscription], !subscription.isPinned)
        } label: {
            Label(subscription.isPinned ? "取消置顶" : "置顶", systemImage: "pin")
        }
        Button {
            actions.archive([subscription])
        } label: {
            Label("归档", systemImage: "archivebox")
        }
        stateMenu(for: subscription)
        Divider()
        Button(role: .destructive) {
            actions.moveToTrash([subscription])
        } label: {
            Label("移入回收站", systemImage: "trash")
        }
    }

    /// 三个状态平铺摆出来，不做「停用 → 启用」那种两态猜测。
    @ViewBuilder
    private func stateMenu(for subscription: Subscription) -> some View {
        Menu {
            ForEach(SubscriptionState.allCases, id: \.self) { state in
                Button {
                    actions.setState([subscription], to: state)
                } label: {
                    if subscription.state == state {
                        Label(state.title, systemImage: "checkmark")
                    } else {
                        Text(state.title)
                    }
                }
            }
        } label: {
            Label("状态：\(subscription.state.title)", systemImage: "circle.lefthalf.filled")
        }
    }

    /// 「一条都还没有」和「有，但被搜索或筛选挡住了」是两件事。
    /// 以前只有一句「还没有订阅，点右下角的 + 记下第一笔」——
    /// 库里躺着二十条、搜了个不存在的词的时候，这句话是在让用户把已有数据再录一遍。
    private var emptyState: some View {
        VStack(spacing: 10) {
            if isNarrowed {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.secondary)
                    .staged(0)
                Text("没有匹配的订阅")
                    .font(.headline)
                    .staged(1)
                Text(emptyHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    // 不加这一条边距，长提示（把关键词整段念出来的那一句）会顶到屏幕两头。
                    .padding(.horizontal, SauryTheme.screen)
                    .staged(2)
                Button {
                    SelectionHaptics.tick()
                    withAnimation(Motion.page) { clearNarrowing() }
                } label: {
                    Label(emptyClearTitle, systemImage: "xmark.circle")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(SauryTheme.surfaceElevated))
                }
                .buttonStyle(Pressable(scale: 0.94))
                .staged(3)
            } else {
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
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .animation(Motion.page, value: isNarrowed)
    }

    /// 只说真正在收窄的那一样。搜索框是空的却写「换个关键词试试」，等于说了句废话。
    private var emptyHint: String {
        let searching = !SubscriptionQuery.normalizedSearch(searchText).isEmpty
        switch (searching, preferences.listFilters.isActive) {
        case (true, true): return "当前搜索和筛选条件下没有订阅。"
        case (true, false): return "没有名字、套餐、备注、支付方式或分类对得上「\(SubscriptionQuery.normalizedSearch(searchText))」。"
        case (false, true): return "当前筛选条件下没有订阅。"
        default: return ""
        }
    }

    private var emptyClearTitle: String {
        let searching = !SubscriptionQuery.normalizedSearch(searchText).isEmpty
        if searching && preferences.listFilters.isActive { return "清除搜索与筛选" }
        return searching ? "清空搜索" : "清除全部筛选"
    }

    private func clearNarrowing() {
        searchText = ""
        preferences.listFilters = .init()
    }
}

#if DEBUG
// MARK: - 列表探针

extension SubscriptionsView {
    private static let probeLogger = Logger(subsystem: "com.guofeng.saury", category: "probe")
    /// 两段探针（列表那一屏 / 动作这一圈）共用同一套 helper，日志前缀跟着当前这一段走。
    nonisolated(unsafe) private static var probeTag = "列表探针"

    /// 「哪几条看得见、按什么排、合计对着谁算」这一层判断现在住在 `SubscriptionQuery`，
    /// 单测里已经拿真列表反复考过。这一条拍的是**摆出来的那一屏**（任务书 §8.2 / §8.3）：
    /// 四种布局是不是还在说同一批订阅、两种空态分不分得清、筛选面板报不报得准已选几项。
    ///
    /// 命令行没有辅助功能权限，按不动那些按钮，所以每一步调的都是那个控件背后的**同一个**方法：
    /// 换布局写 `preferences.subscriptionsViewMode`（就是视图菜单改的那一格），
    /// 「再随机一次」跑的是菜单里那条 `withAnimation { sortSeed = UUID() }`，
    /// 空态上那个清除按钮跑的是 `clearNarrowing()`。拍到的就是它们真正的结果。
    func runListProbeIfNeeded() async {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-saury-list-empty") {
            await runEmptyLibraryProbe()
            return
        }
        if arguments.contains("-saury-actions") {
            await runActionsProbe()
            return
        }
        guard arguments.contains("-saury-list") else { return }
        await runListProbe()
    }

    private func runListProbe() async {
        let originalMode = preferences.subscriptionsViewMode
        let originalSort = preferences.subscriptionsSort
        let originalFilters = preferences.listFilters
        // 探针动过的是用户真的会用的那些设置（布局档、排序档、筛选），不能留在机器上。
        defer {
            searchText = ""
            preferences.subscriptionsViewMode = originalMode
            preferences.subscriptionsSort = originalSort
            preferences.listFilters = originalFilters
        }

        guard await waitProbe("演示数据入库", timeout: 25, { !self.subscriptions.isEmpty }) else { return }
        await installVisualRowsIfNeeded()
        probe("① 开始：库 \(subscriptions.count) 条，屏上 \(items.count) 条，\(summaryText)")

        // ② 四种布局：同一个筛选、同一个排序档，四张图里应当是同一批订阅、同一个先后。
        for (offset, mode) in SubscriptionListViewMode.allCases.enumerated() {
            withAnimation(Motion.page) { preferences.subscriptionsViewMode = mode }
            guard await waitProbe("切到\(mode.title)", timeout: 5,
                                  { self.preferences.subscriptionsViewMode == mode }) else { return }
            probe("②.\(offset + 1) 布局「\(mode.title)」：\(items.count) 条，前三个「\(headNames)」，\(summaryText)")
            _ = await ProbeShutter.capture("l-0\(offset + 1)-\(mode.rawValue)", settle: 1.1)
        }
        preferences.subscriptionsViewMode = .list

        // ③ 分组档：列表里真的切成两节，节名和节内条数念出来。
        preferences.subscriptionsSort = .grouped
        guard await waitProbe("换到分组档", timeout: 5, { self.preferences.subscriptionsSort == .grouped }) else { return }
        probe("③ 分组档：\(groupedSections.map { "\($0.title) \($0.items.count) 条" }.joined(separator: " / "))")
        _ = await ProbeShutter.capture("l-05-grouped", settle: 1.0)

        // ③b 两个节名要同框才看得出「分组真的分了组」。17 条里第二节的标题在屏外，
        // 所以用支付方式把一条周期的和一条一次性的单独圈出来 —— 圈的这两条都是探针写的行。
        preferences.listFilters = SubPreferences.ListFilters(paymentMethods: ["探针配对"])
        guard await waitProbe("支付方式圈出两条", timeout: 5, { self.items.count == 2 }) else { return }
        probe("③b 只看支付方式「探针配对」：\(groupedSections.map { "\($0.title)=\($0.items.map(\.name))" }.joined(separator: " + "))")
        _ = await ProbeShutter.capture("l-05b-grouped-both-sections", settle: 1.0)
        preferences.listFilters = .init()
        guard await waitProbe("圈完就放开", timeout: 5, { self.items.count > 2 }) else { return }

        // ④ 搜到东西：合计那句话跟着换说法，数也跟着屏上这一批走。
        preferences.subscriptionsSort = originalSort
        let totalBefore = summaryText
        let needle = String(items.first?.name.prefix(2) ?? "")
        searchText = needle
        guard await waitProbe("搜「\(needle)」进入收窄态", timeout: 5,
                              { self.isNarrowed && !self.items.isEmpty }) else { return }
        probe("④ 搜「\(needle)」：屏上 \(items.count) 条（库 \(subscriptions.count)），\(totalBefore) → \(summaryText)")
        _ = await ProbeShutter.capture("l-06-search-hit", settle: 1.0)

        // ⑤ 搜不到：这一屏空了，但那句「还没有订阅」这时候是说谎，得换「没有匹配的」。
        searchText = "zzz-不存在-zzz"
        guard await waitProbe("搜一个不存在的词", timeout: 5, { self.items.isEmpty }) else { return }
        probe("⑤ 搜不存在的词：屏上 0 条，走「没有匹配的订阅」那一支，提示「\(emptyHint)」，按钮「\(emptyClearTitle)」")
        _ = await ProbeShutter.capture("l-07-search-nomatch", settle: 1.0)

        // ⑥ 只有筛选挡光的：搜索框是空的，那句提示就不该提关键词。
        searchText = ""
        preferences.listFilters = SubPreferences.ListFilters(currencies: ["ZZZ"])
        guard await waitProbe("币种筛选项挡光列表", timeout: 5, { self.items.isEmpty && self.isNarrowed }) else { return }
        probe("⑥ 只留筛选（币种 ZZZ）：屏上 0 条，提示「\(emptyHint)」，按钮「\(emptyClearTitle)」")
        _ = await ProbeShutter.capture("l-08-filter-nomatch", settle: 1.0)

        // ⑦ 按一下那个清除按钮（走它自己的方法）：列表回来了，话也回到「合计」。
        withAnimation(Motion.page) { clearNarrowing() }
        guard await waitProbe("一键清除后列表回来", timeout: 5, { !self.items.isEmpty && !self.isNarrowed }) else { return }
        probe("⑦ 清除之后：屏上 \(items.count) 条，\(summaryText)，空态不在场")
        _ = await ProbeShutter.capture("l-09-cleared", settle: 1.0)

        // ⑧ 筛选面板：顶上那句「已选 N 项」的数法必须和列表口径一致。
        let chosen = preferences.categories.prefix(2).map(\.id)
        preferences.listFilters = SubPreferences.ListFilters(categoryIDs: chosen, states: [.autoRenew])
        sheets.present(.filter)
        guard await waitProbe("筛选面板弹出", timeout: 8, { self.sheets.route == .filter }) else { return }
        probe("⑧ 筛选面板：已选 \(preferences.listFilters.selectedCount) 项（分类 \(chosen.count) + 状态 1），"
              + "这一档挡掉了 \(subscriptions.count - items.count) 条")
        _ = await ProbeShutter.capture("l-10-filter-sheet", settle: 1.2)
        sheets.close()
        _ = await waitProbe("筛选面板收起", timeout: 8, { self.sheets.route == nil })

        // ⑨ 「再随机一次」：这一档以前只把顺序转了个圈（seed 整个乘在哈希前面），按下去看着没反应。
        preferences.listFilters = .init()
        preferences.subscriptionsSort = .random
        guard await waitProbe("切到随机档", timeout: 5, { self.preferences.subscriptionsSort == .random }) else { return }
        let before = items.map(\.name)
        _ = await ProbeShutter.capture("l-11-random-before", settle: 1.0)
        SelectionHaptics.tick()
        withAnimation(Motion.page) { sortSeed = UUID() }
        guard await waitProbe("重洗后顺序真的变了", timeout: 8, { self.items.map(\.name) != before }) else { return }
        let after = items.map(\.name)
        let moved = zip(before, after).filter { $0 != $1 }.count
        probe("⑨ 再随机一次：\(before.prefix(4)) → \(after.prefix(4))，\(moved)/\(after.count) 个位置换了；"
              + "置顶那条仍在最前：\(items.first?.isPinned == true)；条数还是 \(after.count) 条，"
              + "身份不重复：\(Set(items.map(\.id)).count == after.count)")
        _ = await ProbeShutter.capture("l-12-random-after", settle: 1.0)

        probe("⑩ 收尾：把设置交还给原来的 布局=\(originalMode.title) 排序=\(originalSort.title) 筛选已选 \(originalFilters.selectedCount) 项")
    }

    /// 库里一条都没有时的那一屏。单独开一次启动跑：它要的是「真的没有数据」，
    /// 拿搜索把列表挡出来不算 —— 那是另一句文案、另一个分支。
    /// 这里的 3 秒只是等 @Query 把库读上来再按快门，不参与任何判定。
    private func runEmptyLibraryProbe() async {
        try? await Task.sleep(for: .seconds(3))
        probe("⑪ 空库探针：库 \(subscriptions.count) 条（其中归档 \(subscriptions.filter { $0.archivedAt != nil }.count)、"
              + "回收站 \(subscriptions.filter { $0.deletedAt != nil }.count)），屏上 \(items.count) 条，"
              + "isNarrowed=\(isNarrowed) → 该走「还没有订阅」那一支：\(items.isEmpty && !isNarrowed)")
        _ = await ProbeShutter.capture("l-13-empty-library", settle: 1.2)
    }

    /// 归档 / 停用 / 回收站 / 批量 / 撤销这一圈（任务书 §8.5，PR5e 那一句「所有主要操作闭环正确」）。
    ///
    /// 每一步调的都是滑动、长按菜单、批量栏那三个入口共用的同一个方法（`SubscriptionActions`），
    /// 「撤销」按的是根视图那条撤销栏上那个按钮走的同一句 `performAction()`。
    /// 判定只看那条订阅**在库里到底变成了什么**、撤销之后有没有真的原样回来 ——
    /// 不等够几秒就当它成功了，那种证法不算证。
    ///
    /// 全程只动探针自己写的三行，最后用「彻底删除」把它们收干净：真库那几条一个字节都不碰。
    private func runActionsProbe() async {
        Self.probeTag = "动作探针"
        let center = WriteFeedbackCenter.shared
        let names = ["撤销探针甲", "撤销探针乙", "撤销探针丙"]
        guard await waitProbe("等库读上来", timeout: 25, { !self.subscriptions.isEmpty }) else { return }
        let base = subscriptions.count
        do {
            try repository.install(names.map { probeRow(named: $0) })
        } catch {
            probe("⓪ 探针行没写进去：\(error.localizedDescription) —— 这一趟不跑，真库一条都不动")
            return
        }
        guard await waitProbe("探针行读回", timeout: 15, { self.subscriptions.count >= base + names.count }) else { return }
        probe("⓪ 写了 \(names.count) 条探针行：库 \(base) → \(subscriptions.count) 条，屏上 \(items.count) 条")

        // ② 归档 → 撤销条上那个按钮 → 归档字段收回
        guard let first = named(names[0]) else {
            probe("① 找不到「\(names[0])」，这一趟不跑")
            return
        }
        center.clear()
        let archived = actions.archive([first])
        let barText = center.message?.text ?? "（没有条子）"
        let barButton = center.message?.actionTitle ?? "无"
        _ = await ProbeShutter.capture("a-02-archive-undo-bar", settle: 0.9)
        let offScreen = await waitProbe("归档后从这一屏撤下", timeout: 6, {
            self.named(names[0])?.archivedAt != nil && self.containsRow(names[0]) == false
        })
        probe("② 归档：落库=\(archived)，条子「\(barText)」按钮=\(barButton)，"
              + "归档字段已写且这一屏撤下=\(offScreen)，屏上 \(items.count) 条")
        center.performAction()
        let unarchived = await waitProbe("撤销把归档收回去", timeout: 6, {
            self.named(names[0])?.archivedAt == nil
        })
        probe("③ 撤销归档：归档字段清空=\(unarchived)，条子收掉=\(center.message == nil)，"
              + "屏上回到 \(items.count) 条，身份不重复=\(Set(items.map(\.id)).count == items.count)")

        // ④ 停用 → 撤销回**原来那一个**状态（不是「启用就等于改回自动续费」那种猜测）
        if let row = named(names[0]) {
            let before = row.state
            center.clear()
            actions.setState([row], to: .inactive)
            let stopped = await waitProbe("状态落成停用", timeout: 6, { self.named(names[0])?.state == .inactive })
            probe("④ 停用：\(before.title) → \(self.named(names[0])?.state.title ?? "?")，"
                  + "条子「\(center.message?.text ?? "（没有条子）")」，等到了=\(stopped)")
            center.performAction()
            let back = await waitProbe("撤销把状态原样还回", timeout: 6, { self.named(names[0])?.state == before })
            probe("⑤ 撤销停用：回到「\(before.title)」=\(back)")
        }

        // ⑥ 回收站 → 撤销
        if let row = named(names[0]) {
            center.clear()
            actions.moveToTrash([row])
            let trashed = await waitProbe("进回收站", timeout: 6, {
                self.named(names[0])?.deletedAt != nil && self.containsRow(names[0]) == false
            })
            probe("⑥ 移入回收站：删除时间已写且这一屏撤下=\(trashed)，"
                  + "条子「\(center.message?.text ?? "（没有条子）")」按钮=\(center.message?.actionTitle ?? "无")")
            center.performAction()
            let restored = await waitProbe("撤销把回收站那条捞回来", timeout: 6, {
                self.named(names[0])?.deletedAt == nil
            })
            probe("⑦ 撤销移入回收站：删除时间清空=\(restored)，这一屏又看得见=\(self.containsRow(names[0]))")
        }

        // ⑧ 批量：三条一起归档，一句「已归档 3 条」，一次撤销三条全回来
        let trio = names.compactMap { named($0) }
        center.clear()
        actions.archive(trio)
        let allGone = await waitProbe("三条一起进归档", timeout: 6, {
            trio.count == names.count && trio.allSatisfy { $0.archivedAt != nil }
        })
        let batchText = center.message?.text ?? "（没有条子）"
        _ = await ProbeShutter.capture("a-08-batch-undo-bar", settle: 0.9)
        probe("⑧ 批量归档 \(trio.count) 条：条子「\(batchText)」按钮=\(center.message?.actionTitle ?? "无")，"
              + "三条都写上归档时间=\(allGone)，这一屏还剩 \(self.items.count) 条")
        center.performAction()
        let allBack = await waitProbe("一次撤销三条全回来", timeout: 6, {
            trio.allSatisfy { $0.archivedAt == nil }
        })
        probe("⑨ 一次撤销批量：三条归档时间都清空=\(allBack)，这一屏回到 \(self.items.count) 条")

        // ⑩ 彻底删除：不可逆的事不给撤销按钮，同时把探针自己写的行收干净
        let leftovers = names.compactMap { named($0) }
        center.clear()
        let deleted = actions.deleteForever(leftovers)
        let cleaned = await waitProbe("探针行全部消失", timeout: 6, { self.namedAny() == nil })
        let goneText = center.message?.text ?? "（没有条子）"
        let goneButton = center.message?.actionTitle ?? "无（不可逆，所以不给撤销）"
        probe("⑩ 彻底删除 \(leftovers.count) 条：落库=\(deleted)，条子「\(goneText)」按钮=\(goneButton)，"
              + "库里探针行清空=\(cleaned)")
        probe("⑪ 收尾：库 \(subscriptions.count) 条 =「\(subscriptions.map(\.name).joined(separator: "、"))」，"
              + "屏上 \(items.count) 条 —— 探针写的行全部收干净，真库那几条原样还在")
    }

    /// 探针专用的行：只服务这一趟动作循环，最后自己删掉。
    private func probeRow(named name: String) -> Subscription {
        Subscription(name: name, priceMinorUnits: 10_000, currencyCode: "CNY",
                     cycle: .monthly, customMonths: 2,
                     category: preferences.categories.first?.id ?? "other",
                     state: .autoRenew,
                     startDate: Date(timeIntervalSince1970: 1_700_000_000),
                     paymentMethod: "")
    }

    private func named(_ name: String) -> Subscription? {
        subscriptions.first { $0.name == name }
    }

    private func namedAny() -> Subscription? {
        subscriptions.first { $0.name.hasPrefix("撤销探针") }
    }

    /// 这一屏（搜索/筛选之后那批）里有没有这个名字。
    private func containsRow(_ name: String) -> Bool {
        items.contains { $0.name == name }
    }

    /// 截图要能看出名堂，库里就得有那么多种子：同价三条、一次性两笔、停用的、归档的、
    /// 别的币种的。只有 3 条演示数据时，「四种布局是同一批订阅」「分组真的分了两节」
    /// 「同价的不许每次刷新换个位」这三件事要么看不见，要么一眼分辨不出来。
    ///
    /// 写库走的是用户那条路（`SubscriptionRepository`，和表单保存同一个入口），
    /// 但这一批只服务目测：持久化那一段由 PR1b/PR2 的写库与备份测试在管，不拿它作证。
    private func installVisualRowsIfNeeded() async {
        guard ProcessInfo.processInfo.arguments.contains("-saury-list-many") else { return }
        guard subscriptions.count < 12 else {
            probe("⓪ 库里已有 \(subscriptions.count) 条，探针数据不再重复写")
            return
        }
        let categoryID = preferences.categories.first?.id ?? "other"
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func row(_ name: String, _ minor: Int, cycle: BillingCycle = .monthly,
                 currency: String = "CNY", state: SubscriptionState = .autoRenew,
                 payment: String = "", pinned: Bool = false, archived: Bool = false) -> Subscription {
            let item = Subscription(name: name, priceMinorUnits: minor, currencyCode: currency,
                                    cycle: cycle, customMonths: 2, category: categoryID,
                                    state: state, startDate: start, paymentMethod: payment)
            if pinned { item.pinnedAt = Date(timeIntervalSince1970: 1_800_000_000) }
            if archived { item.archivedAt = Date(timeIntervalSince1970: 1_800_000_000) }
            return item
        }
        let rows: [Subscription] = [
            row("Alpha", 6800), row("Bravo", 6800), row("Charlie", 6800),      // 同价三条
            row("Delta", 13401, state: .manualRenew),
            row("Echo", 2500, cycle: .weekly),
            row("Foxtrot", 22800, cycle: .quarterly),
            row("Golf", 68800, cycle: .yearly),
            row("Hotel", 18800, cycle: .yearly, payment: "探针配对"),            // 和 Kilo 一起
            row("India", 4500, cycle: .custom),
            row("Juliett", 29900, cycle: .oneTime),
            row("Kilo", 1200, cycle: .oneTime, payment: "探针配对"),             // 圈出两节各一条
            row("Lima", 999, currency: "USD"),
            row("Mike", 30000, state: .inactive),                              // 不计入合计
            row("November", 7700, pinned: true),
            row("Oscar", 5000, archived: true),                                // 不该出现在这一屏
        ]
        let before = subscriptions.count
        do {
            try repository.install(rows)
            guard await waitProbe("探针数据读回", timeout: 15, { self.subscriptions.count >= before + rows.count }) else { return }
            probe("⓪ 写了 \(rows.count) 条（同价 3 / 一次性 2 / 停用 1 / 归档 1 / 美元 1）：库 \(before) → \(subscriptions.count) 条")
        } catch {
            probe("⓪ 探针数据没写进去：\(error.localizedDescription) —— 后面的截图仍在原有库上拍")
        }
    }

    private var headNames: String {
        items.prefix(3).map(\.name).joined(separator: "、")
    }

    private var summaryText: String {
        "\(isNarrowed ? "筛选中的合计" : "合计") "
        + summaryStats.total(for: period).formattedGrouped
        + "（共 \(items.count) 个）"
    }

    private func probe(_ line: String) {
        Self.probeLogger.log("\(Self.probeTag, privacy: .public) \(line, privacy: .public)")
    }

    /// 等条件成立。超时就把「没等到」如实说一句，不假装等到了再往下走。
    private func waitProbe(_ label: String, timeout: TimeInterval, _ done: () -> Bool) async -> Bool {
        let began = Date()
        while !done() {
            if Date().timeIntervalSince(began) > timeout {
                probe("⏱ \(label)：\(Int(timeout)) 秒内没等到")
                return false
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }
}
#endif
