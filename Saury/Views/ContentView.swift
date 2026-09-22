import SwiftUI
import SwiftData
import UserNotifications

enum QJTab: Hashable {
    case home, items, add, calendar, stats
}

enum QJRoute: Hashable {
    case history
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \ExpiryItem.expiryDate) private var items: [ExpiryItem]
    @Query(sort: \ExpiryEvent.happenedAt, order: .reverse) private var events: [ExpiryEvent]

    @State private var selectedTab: QJTab = .home
    @State private var lastContentTab: QJTab = .home
    @State private var statsPath = NavigationPath()
    @State private var showingQuickAdd = false
    @State private var showingAddOptions = false
    @State private var showingAdd = false
    @State private var scanRequest: ScanRequest?
    @State private var showingContinuousScan = false
    @State private var scanned: ScanReviewView.Confirmation?
    @State private var showingSettings = false
    @State private var selectedItem: ExpiryItem?
    @State private var editingItem: ExpiryItem?
    @State private var externalDraft: ExternalItemDraft?
    @State private var query = ItemQuery(sort: QJPreferences.itemSort)
    @State private var actionCenter = ExpiryActionCenter.shared

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeView(
                    items: homeItems,
                    onOpenItem: openItem,
                    onScan: { scanRequest = .package },
                    onAdd: beginCustomAdd,
                    onPickUrgency: filterByUrgency,
                    onPickLocation: filterByLocation
                )
                    .navigationTitle("今天")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar { settingsToolbar }
            }
            .tabItem { Label("首页", systemImage: "house.fill") }
            .tag(QJTab.home)

            NavigationStack {
                ItemsView(
                    items: items,
                    query: $query,
                    onOpenItem: openItem,
                    onAdd: { showingAddOptions = true },
                    onAction: perform,
                    onEdit: { item in
                        selectedItem = nil
                        editingItem = item
                    }
                )
                    .navigationTitle("物品")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar { addToolbarItem }
            }
            .tabItem { Label("物品", systemImage: "square.grid.2x2") }
            .tag(QJTab.items)

            Color.clear
            .tabItem { Label("添加", systemImage: "plus.circle.fill") }
            .tag(QJTab.add)
            // 方案 §19 还要「长按 + 直接弹菜单」：SwiftUI 的 TabBar 项不接收长按，
            // 所以这份菜单挂在各页工具栏的 + 上（见 addToolbarItem）。

            NavigationStack {
                CalendarView(items: homeItems, onOpenItem: openItem)
                    .navigationTitle("日历")
                    .navigationBarTitleDisplayMode(.large)
            }
            .tabItem { Label("日历", systemImage: "calendar") }
            .tag(QJTab.calendar)

            NavigationStack(path: $statsPath) {
                BillingView(items: homeItems, onOpenItem: openItem, onShowHistory: { statsPath.append(QJRoute.history) })
                    .navigationTitle("统计")
                    .navigationBarTitleDisplayMode(.large)
                    .navigationDestination(for: QJRoute.self) { route in
                        switch route {
                        case .history:
                            HistoryView(events: events)
                                .navigationTitle("活动记录")
                        }
                    }
            }
            .tabItem { Label("统计", systemImage: "chart.pie.fill") }
            .tag(QJTab.stats)
        }
        .onChange(of: selectedTab) { _, tab in
            guard tab == .add else {
                lastContentTab = tab
                return
            }
            selectedTab = lastContentTab
            showingAddOptions = true
        }
        .onChange(of: query.sort) { _, sort in
            QJPreferences.itemSort = sort
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { undoBar }
        .sheet(isPresented: $showingAdd, onDismiss: { externalDraft = nil }) {
            AddEditSubscriptionView(initialDraft: externalDraft)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $editingItem) { item in
            AddEditSubscriptionView(item: item)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedItem) { item in
            SubscriptionDetailView(item: item)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingQuickAdd) {
            QuickAddSubscriptionView(onSelect: beginTemplateAdd, onCustom: beginCustomAdd)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $scanned) { confirmation in
            AddEditSubscriptionView(scanned: confirmation)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingAddOptions) {
            AddOptionsView(
                onScan: beginScan,
                onContinuousScan: beginContinuousScan,
                onQuickAdd: beginQuickAdd,
                onManualAdd: beginCustomAdd
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        // 连续扫描是全屏流程（方案 §20）：确认即入库，不进表单。
        .fullScreenCover(isPresented: $showingContinuousScan) {
            ContinuousScanView(context: modelContext)
        }
        // 扫描链子整套挂在这里（方案 §19）：TabBar 的 +、首页的「开始扫描」和
        // 工具栏长按菜单都只需要改 `scanRequest`。
        .scanFlow(request: $scanRequest) { scanned = $0 }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .task {
            DemoDataSeeder.seedIfNeeded(in: modelContext)
            drainExternalInput()
            if let pending = NotificationActionHandler.consumePendingAction() {
                await NotificationActionHandler.apply(pending, in: modelContext)
            }
            await ExpiryActionCenter.shared.refresh(in: modelContext)
        }
        .onChange(of: items.count) { _, _ in
            Task { await ExpiryActionCenter.shared.refresh(in: modelContext) }
        }
        // 回到前台补一次队列（方案 §42）：在后台过掉的那些提醒要腾出位置，
        // 装不下的那部分也才有机会排进来。
        // 回到前台补一次队列（方案 §42）：在后台过掉的那些提醒要腾出位置，
        // 装不下的那部分也才有机会排进来。分享扩展递进来的东西同样要在这这一刻被接住。
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            drainExternalInput()
            let context = modelContext
            Task { await ExpiryActionCenter.shared.refresh(in: context) }
        }
    }

    /// 首页和日历看的是同一份「还在跟踪、最快过期在前」（方案 §14）。
    private var homeItems: [ExpiryItem] {
        ItemQuery(sort: .earliestExpiry).results(in: items)
    }

    @ViewBuilder
    private var undoBar: some View {
        if let record = actionCenter.pendingUndo {
            UndoBanner(
                record: record,
                onUndo: {
                    let context = modelContext
                    Task { await actionCenter.undo(in: context) }
                },
                onDismiss: { actionCenter.pendingUndo = nil }
            )
            .padding(.bottom, 6)
        }
    }

    @ToolbarContentBuilder
    private var settingsToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showingSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .accessibilityLabel("设置")
        }
    }

    @ToolbarContentBuilder
    private var addToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showingAddOptions = true } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("添加物品")
            // 长按 = 直接出菜单，点 = 进入口表（方案 §19）。
            .contextMenu { addMenu }
        }
    }

    @ViewBuilder
    private var addMenu: some View {
        Button(action: beginContinuousScan) {
            Label("连续扫描", systemImage: "camera.viewfinder")
        }
        Button {
            beginScan(.package)
        } label: {
            Label("扫包装上的日期", systemImage: "text.viewfinder")
        }
        Button {
            beginScan(.library)
        } label: {
            Label("从相册识别", systemImage: "photo.on.rectangle")
        }
        Button(action: beginCustomAdd) {
            Label("添加物品", systemImage: "plus.circle")
        }
        Button(action: beginQuickAdd) {
            Label("快速添加", systemImage: "square.grid.2x2")
        }
    }

    private func openItem(_ item: ExpiryItem) {
        selectedItem = item
    }

    private func perform(_ action: ExpiryAction, on item: ExpiryItem) {
        let context = modelContext
        Task { await actionCenter.perform(action, on: item, in: context) }
    }

    private func filterByUrgency(_ urgency: ExpiryUrgency) {
        query = ItemQuery(urgencies: [urgency], sort: query.sort)
        selectedTab = .items
    }

    private func filterByLocation(_ location: String) {
        query = ItemQuery(locations: [location], sort: query.sort)
        selectedTab = .items
    }

    private func beginCustomAdd() {
        showingQuickAdd = false
        showingAddOptions = false
        externalDraft = nil
        DispatchQueue.main.async { showingAdd = true }
    }

    private func beginQuickAdd() {
        showingAddOptions = false
        DispatchQueue.main.async { showingQuickAdd = true }
    }

    private func beginTemplateAdd(_ draft: ExternalItemDraft) {
        showingQuickAdd = false
        externalDraft = draft
        DispatchQueue.main.async { showingAdd = true }
    }

    /// 从入口表里走扫描：先把这张表收掉，下一轮循环再让 `scanFlow` 接手弹层 ——
    /// 同一个视图上叠两层 present 会被系统丢掉。
    private func beginScan(_ request: ScanRequest) {
        showingAddOptions = false
        DispatchQueue.main.async { scanRequest = request }
    }

    /// 连续扫描和一次性扫描一样：躲开叠层，等下一轮再 present。
    private func beginContinuousScan() {
        showingAddOptions = false
        DispatchQueue.main.async { showingContinuousScan = true }
    }

    /// 外部入口递进来的东西一次只接一条（方案 §58）：正在填表单、正在看识别结果的
    /// 时候不叠第二层 present，剩下的留在队列里等下一次回到前台。
    private func drainExternalInput() {
        guard externalDraft == nil, scanned == nil, scanRequest == nil else { return }
        guard let draft = ExternalInputStore.consume() else { return }
        switch draft.payload {
        case .fields(let fields):
            beginExternalAdd(fields)
        case .text(let text):
            beginExternalAdd(ExternalItemDraft(name: Self.firstLine(of: text) ?? "来自分享的记录"))
        case .url(let url):
            beginExternalAdd(ExternalItemDraft(name: Self.linkName(url), sourceURL: url))
        case .image(let fileName):
            beginScan(.sharedImage(fileName: fileName))
        }
    }

    private func beginExternalAdd(_ draft: ExternalItemDraft) {
        showingAddOptions = false
        showingQuickAdd = false
        externalDraft = draft
        DispatchQueue.main.async { showingAdd = true }
    }

    private static func firstLine(of text: String) -> String? {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// 分享链接进来时名字用域名：整串 URL 属于「来源」那一行，不该占掉标题。
    private static func linkName(_ urlText: String) -> String {
        guard let host = URL(string: urlText)?.host else { return "来自分享的链接" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
