import SwiftUI
import SwiftData
import StoreKit

/// 设置主页。
struct SettingsView: View {
    @EnvironmentObject private var preferences: SubPreferences
    @Query private var subscriptions: [Subscription]

    enum Route: Hashable {
        case appearance, layout
        case currency, categories, payments, notifications
        case archive, trash
        case data, storage
        case whatsNew, aboutApp, tipJar
        case toys, misc
    }

    var body: some View { homeList }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .appearance: AppearanceSettingsView()
        case .layout: LayoutSettingsView()
        case .currency: CurrencySettingsView()
        case .categories: CategorySettingsView()
        case .payments: PaymentMethodSettingsView()
        case .notifications: NotificationSettingsView()
        case .archive: ArchiveListView()
        case .trash: TrashView()
        case .data: ICloudDataView()
        case .storage: StorageSettingsView()
        case .whatsNew: WhatsNewView(standalone: true)
        case .aboutApp: AboutAppView()
        case .tipJar: TipJarView()
        case .toys: ToysView()
        case .misc: MiscSettingsView()
        }
    }

    private var homeList: some View {
        List {
            Section("偏好") {
                NavigationLink(value: Route.appearance) { Label("外观", systemImage: "circle.lefthalf.filled") }
                NavigationLink(value: Route.layout) { Label("总览布局", systemImage: "square.grid.2x2") }
                // 竞品设置里「小玩具」「其他」就在这一组、外观/总览布局后面（矩阵 EON-039/071）。
                // 两页内容是我方自己的设计：竞品那两页在录屏里从未展开过，对不上内容、只对齐「入口存在」。
                NavigationLink(value: Route.toys) { Label("小玩具", systemImage: "gamecontroller") }
                NavigationLink(value: Route.misc) { Label("其他", systemImage: "ellipsis.circle") }
            }
            Section("订阅") {
                NavigationLink(value: Route.currency) {
                    HStack { Label("货币", systemImage: "dollarsign.circle"); Spacer(); Text(preferences.defaultCurrency).foregroundStyle(.secondary) }
                }
                NavigationLink(value: Route.categories) { Label("分类", systemImage: "tag") }
                NavigationLink(value: Route.payments) { Label("支付方式", systemImage: "creditcard") }
                NavigationLink(value: Route.notifications) { Label("通知", systemImage: "bell") }
                NavigationLink(value: Route.archive) { Label("归档订阅", systemImage: "archivebox") }
                NavigationLink(value: Route.trash) { Label("回收站", systemImage: "trash") }
            }
            Section("数据") {
                NavigationLink(value: Route.data) { Label("iCloud 与数据", systemImage: "icloud") }
                NavigationLink(value: Route.storage) { Label("存储管理", systemImage: "internaldrive") }
            }
            Section("关于") {
                NavigationLink(value: Route.whatsNew) { Label("新功能", systemImage: "wand.and.stars") }
                NavigationLink(value: Route.aboutApp) { Label("关于", systemImage: "info.circle") }
                NavigationLink(value: Route.tipJar) { Label("支持开发者", systemImage: "heart") }
            }
        }
        .scrollContentBackground(.hidden)
        .background(SauryTheme.background)
        .navigationTitle("设置")
        .navigationDestination(for: Route.self) { route in
            destination(for: route)
        }
    }
}

/// 外观：模式、主题色、彩色卡片。
struct AppearanceSettingsView: View {
    @EnvironmentObject private var preferences: SubPreferences

    var body: some View {
        List {
            Section("显示") {
                Picker("外观", selection: Binding(
                    get: { preferences.appearance },
                    set: { preferences.appearance = $0 }
                )) {
                    ForEach(SubPreferences.AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("主题色").font(.subheadline)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 14) {
                        ForEach(SubPreferences.accentChoices, id: \.self) { hex in
                            Button {
                                SelectionHaptics.tick()
                                preferences.accentHex = hex
                            } label: {
                                ZStack {
                                    Circle().fill(Palette.color(hex)).frame(width: 36, height: 36)
                                    if preferences.accentHex == hex {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundStyle(.white)
                                        Circle().stroke(Color.primary.opacity(0.4), lineWidth: 2).frame(width: 42, height: 42)
                                    }
                                }
                                .scaleEffect(preferences.accentHex == hex ? 1.1 : 1)
                                .shadow(color: preferences.accentHex == hex
                                    ? Palette.color(hex).opacity(0.5) : .clear, radius: 8, y: 3)
                            }
                            .buttonStyle(Pressable(scale: 0.88, animation: Motion.pop))
                            .animation(Motion.pop, value: preferences.accentHex)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            // 说明的话术在 `AppIconSwitcher` 自己那里：它要按这台设备能不能换图标分成两句话说，
            // 挂在这一层只会重复一遍，还会把「系统会弹确认」这种没验过的说法留在屏幕上。
            Section {
                AppIconSwitcher()
            }
            Section {
                Toggle("彩色订阅卡片", isOn: Binding(
                    get: { preferences.coloredCards },
                    set: { preferences.coloredCards = $0 }
                ))
            } footer: {
                Text("让每张订阅卡片染上图标的主色调。关闭则回到默认底色。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(SauryTheme.background)
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 总览布局：快览开关 + 面板显隐 + 拖动排序。
struct LayoutSettingsView: View {
    @EnvironmentObject private var preferences: SubPreferences
    @State private var editMode = EditMode.inactive

    var body: some View {
        List {
            Section {
                Toggle("快览（文字模式）", isOn: Binding(
                    get: { preferences.compactStats },
                    set: { preferences.compactStats = $0 }
                ))
            } footer: {
                Text("开启后，月均和平均每个在「快览」面板里收成一行文字，不再各占一张卡片。")
            }
            Section {
                let visible = preferences.panelOrder.filter { !preferences.hiddenPanels.contains($0) }
                if visible.isEmpty {
                    Text("没有显示中的面板").foregroundStyle(.secondary)
                }
                ForEach(visible) { panel in
                    Button {
                        preferences.hiddenPanels.insert(panel)
                    } label: {
                        HStack {
                            Image(systemName: panel.symbol).foregroundStyle(.secondary)
                            Text(panel.title).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "minus.circle")
                                .foregroundStyle(.red.opacity(0.7))
                        }
                    }
                }
                .onMove { from, to in
                    var order = preferences.panelOrder
                    order.move(fromOffsets: from, toOffset: to)
                    preferences.panelOrder = order
                }
            } header: {
                Text("显示中")
            } footer: {
                Text("点减号隐藏面板；点右上角「编辑」可拖动排序。在 iPad 和 Mac 上，这个顺序会按左右两列交替排布。")
            }
            Section {
                let hidden = SubPreferences.allPanels.filter { preferences.hiddenPanels.contains($0) }
                if hidden.isEmpty {
                    Text("没有隐藏的面板").foregroundStyle(.secondary)
                }
                ForEach(hidden) { panel in
                    Button {
                        preferences.hiddenPanels.remove(panel)
                    } label: {
                        HStack {
                            Image(systemName: panel.symbol).foregroundStyle(.tertiary)
                            Text(panel.title).foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "plus.circle")
                                .foregroundStyle(Color.accentColor.opacity(0.8))
                        }
                    }
                }
            } header: {
                Text("已隐藏")
            }
            Section {
                Button("恢复默认排列") {
                    preferences.hiddenPanels = []
                    preferences.compactStats = false
                    preferences.panelOrder = SubPreferences.allPanels
                }
            }
        }
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode == .active ? "完成" : "编辑") {
                    editMode = editMode == .active ? .inactive : .active
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(SauryTheme.background)
        .navigationTitle("总览布局")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 货币设置。
struct CurrencySettingsView: View {
    @EnvironmentObject private var preferences: SubPreferences
    @EnvironmentObject private var exchangeRates: ExchangeRateStore

    var body: some View {
        List {
            Section {
                ForEach(preferences.commonCurrencies, id: \.self) { code in
                    HStack {
                        Text(code).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                        Text(CurrencyCatalog.name(for: code))
                        Spacer()
                        if preferences.defaultCurrency == code {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                }
                Toggle("选择货币时只显示常用币种", isOn: Binding(
                    get: { preferences.onlyCommonCurrencies },
                    set: { preferences.onlyCommonCurrencies = $0 }
                ))
            } header: {
                Text("常用币种")
            } footer: {
                Text("在添加订阅的货币选择器里长按币种可以加入或移出常用。")
            }

            Section {
                ForEach(CurrencyCatalog.all) { entry in
                    Button {
                        preferences.defaultCurrency = entry.code
                    } label: {
                        HStack {
                            Text(entry.code).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                            Text(entry.listTitle).foregroundStyle(.primary)
                            Spacer()
                            if preferences.defaultCurrency == entry.code {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            } header: {
                Text("全部币种")
            } footer: {
                Text("点一下设为默认币种。")
            }

            Section {
                Toggle("显示原始币种", isOn: Binding(
                    get: { preferences.showOriginalCurrency },
                    set: { preferences.showOriginalCurrency = $0 }
                ))
                Button {
                    Task { await exchangeRates.refresh() }
                } label: {
                    HStack {
                        Label("立即刷新汇率", systemImage: "arrow.clockwise")
                        Spacer()
                        if exchangeRates.isRefreshing { ProgressView() }
                    }
                }
            } footer: {
                Text("开启「显示原始币种」后，不同币种的订阅会同时显示折算金额和原价。汇率每天自动同步，订阅价格会跟着浮动。上次更新 \(exchangeRates.lastUpdatedText())。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(SauryTheme.background)
        .navigationTitle("货币")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 分类管理：改名、换色、增删。
struct CategorySettingsView: View {
    @EnvironmentObject private var preferences: SubPreferences
    @State private var newCategoryName = ""

    var body: some View {
        List {
            ForEach($preferences.categories, editActions: [.delete, .move]) { $category in
                HStack(spacing: 10) {
                    Menu {
                        ForEach(Palette.colors, id: \.self) { hex in
                            Button { category.colorHex = hex } label: {
                                HStack { Circle().fill(Palette.color(hex)).frame(width: 12, height: 12); Text(hex) }
                            }
                        }
                    } label: {
                        Circle().fill(category.color).frame(width: 22, height: 22)
                    }
                    TextField("名称", text: $category.name)
                    Image(systemName: category.symbol)
                        .foregroundStyle(.secondary)
                }
            }
            .onMove { from, to in
                preferences.categories.move(fromOffsets: from, toOffset: to)
            }
            .onDelete { offsets in
                // 至少留一个分类；被删分类下的订阅归「其他」。
                let remaining = preferences.categories.count - offsets.count
                guard remaining >= 1 else { return }
                preferences.categories.remove(atOffsets: offsets)
            }

            Section("添加分类") {
                HStack {
                    TextField("名称", text: $newCategoryName)
                    Button("添加") {
                        let name = newCategoryName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        let id = "custom-\(UUID().uuidString.prefix(6))"
                        preferences.categories.append(
                            SubscriptionCategory(id: id, name: name, colorHex: Palette.colors[preferences.categories.count % Palette.colors.count], symbol: "square.grid.2x2")
                        )
                        newCategoryName = ""
                    }
                    .disabled(newCategoryName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .scrollContentBackground(.hidden)
        .background(SauryTheme.background)
        .navigationTitle("分类")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 支付方式管理。
struct PaymentMethodSettingsView: View {
    @EnvironmentObject private var preferences: SubPreferences
    @State private var newMethod = ""
    @State private var editMode = EditMode.inactive

    var body: some View {
        List {
            Section {
                ForEach(preferences.paymentMethods, id: \.self) { method in
                    Text(method)
                }
                .onMove { from, to in
                    preferences.paymentMethods.move(fromOffsets: from, toOffset: to)
                }
                .onDelete { offsets in
                    preferences.paymentMethods.remove(atOffsets: offsets)
                }
            } header: {
                Text("已添加")
            } footer: {
                Text("添加订阅时从这里挑支付方式，顺序就是这里的顺序。点右上角「编辑」可以拖动排序或删除；删除不会影响已经填好的订阅。")
            }
            Section("添加新方式") {
                HStack {
                    Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                    TextField("名称，如 花呗 / 招行信用卡", text: $newMethod)
                        .onSubmit(addNew)
                    Button("添加", action: addNew)
                        .disabled(newMethod.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode == .active ? "完成" : "编辑") {
                    editMode = editMode == .active ? .inactive : .active
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(SauryTheme.background)
        .navigationTitle("支付方式")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func addNew() {
        let name = newMethod.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        preferences.paymentMethods.append(name)
        newMethod = ""
    }
}

/// 通知设置。
struct NotificationSettingsView: View {
    @EnvironmentObject private var preferences: SubPreferences
    @Query private var storedSubscriptions: [Subscription]
    @State private var authorized: UNAuthorizationStatus = .notDetermined
    @State private var countdown: Int?

    var body: some View {
        List {
            Section {
                Toggle("开启提醒", isOn: Binding(
                    get: { preferences.notificationsEnabled },
                    set: { enabled in
                        // 先拿到系统授权再落这个开关。反过来写会留一小段假状态：
                        // 开关已经是「开」，而系统那边一条都挂不上（实测排入 3、挂着 0）。
                        guard enabled else {
                            preferences.notificationsEnabled = false
                            return
                        }
                        Task {
                            let granted = await SubscriptionScheduler.shared.requestAuthorization()
                            preferences.notificationsEnabled = granted
                            authorized = await SubscriptionScheduler.shared.authorizationStatus()
                        }
                    }
                ))
            } footer: {
                Text(footerText)
            }

            Section {
                // §5.1：「要不要提醒」和「提前几天」是两件事，不能再让 0 兼职表达「不提醒」。
                Toggle("新建订阅默认提醒", isOn: Binding(
                    get: { preferences.defaultRemindersEnabled },
                    set: { preferences.defaultRemindersEnabled = $0 }
                ))
                if preferences.defaultRemindersEnabled {
                    Stepper(value: Binding(
                        get: { preferences.defaultReminderDays },
                        set: { preferences.defaultReminderDays = $0 }
                    ), in: 0...30) {
                        Text(preferences.defaultReminderDays == 0
                            ? "扣费当天提醒"
                            : "提前 \(preferences.defaultReminderDays) 天提醒")
                            .font(.subheadline)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Stepper(value: Binding(
                    get: { preferences.reminderHour },
                    set: { preferences.reminderHour = $0 }
                ), in: 0...23) {
                    Text("提醒时刻：\(preferences.reminderHour):00")
                        .font(.subheadline.monospacedDigit())
                }
            } footer: {
                Text("开关只管新建的订阅，已有的订阅在自己的页面里改；提前 0 天就是扣费当天，提醒落在当天的整点。")
            }
            .animation(Motion.ui, value: preferences.defaultRemindersEnabled)

            Section {
                Button {
                    Task { await sendPreview() }
                } label: {
                    HStack {
                        Label("预览通知样式", systemImage: "eye")
                        Spacer()
                        if let countdown {
                            Text("\(countdown) 秒后送达")
                                .font(.footnote)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            } footer: {
                Text("点一下后回到桌面，稍等片刻能看到样例通知。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(SauryTheme.background)
        .navigationTitle("通知")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            authorized = await SubscriptionScheduler.shared.authorizationStatus()
        }
    }

    /// 页脚说系统此刻真会做什么，而不是开关的样子。
    /// 依据是模拟器实测：没授权时排多少条系统都不挂，这时候界面还写「会准时提醒你」
    /// 就是假话（任务书 §16：不把静态 UI 当作完整功能）。
    private var footerText: String {
        switch authorized {
        case .authorized:
            return preferences.notificationsEnabled
                ? "通知已开启，我们会按每个订阅的设置准时提醒你。"
                : "开关现在是关的：订阅不会提醒，系统里已经挂着的也会被撤掉。"
        case .denied:
            return "系统里已经拒绝通知，所以一条提醒都挂不上。去「设置 → 通知 → 期见」允许后，下一轮会自动补排。"
        case .provisional, .ephemeral:
            return "通知以静默方式送达（进通知中心，不弹横幅）。想要横幅需要在系统设置里允许通知。"
        default:
            return "开启后，订阅会在扣费前按时提醒你；系统首次会请求通知权限。"
        }
    }

    private func sendPreview() async {
        let granted = await SubscriptionScheduler.shared.requestAuthorization()
        guard granted else { return }
        countdown = 3
        // 拿一条真订阅写正文：预览该预览用户将来真会看到的那句话。
        // 库里一条都没有时才退回示例，那种情况点进去只会提示「找不到」。
        SubscriptionScheduler.shared.sendPreview(subscription: storedSubscriptions.first, after: 3)
        while let current = countdown, current > 0 {
            try? await Task.sleep(for: .seconds(1))
            countdown = (countdown ?? 1) - 1
        }
        countdown = nil
    }
}

/// 归档订阅列表：可以恢复、移入回收站，或彻底删除。
struct ArchiveListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Subscription> { $0.archivedAt != nil && $0.deletedAt == nil })
    private var archived: [Subscription]
    @EnvironmentObject private var preferences: SubPreferences

    private var repository: SubscriptionRepository { SubscriptionRepository(context: modelContext) }
    private var actions: SubscriptionActions { SubscriptionActions(repository: repository) }

    /// 等用户确认的那一条。「彻底删除」不可撤销，所以必须先把话说清楚再动手。
    @State private var pendingForever: Subscription?

    var body: some View {
        List {
            if archived.isEmpty {
                Text("暂无归档订阅")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .staged(0)
            }
            ForEach(Array(archived.enumerated()), id: \.element) { index, subscription in
                HStack(spacing: 12) {
                    SubscriptionIconView(subscription: subscription, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(subscription.name).font(.subheadline.weight(.medium))
                        Text(subscription.myAmount.formatted + " · " + subscription.cycleTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("恢复") {
                        withAnimation(Motion.ui) { _ = actions.unarchive([subscription]) }
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(Pressable(scale: 0.92))
                    Button("彻底删除") { pendingForever = subscription }
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .buttonStyle(Pressable(scale: 0.92))
                }
                .staged(min(index, 8))
                .transition(.opacity.combined(with: .move(edge: .leading)))
                .swipeActions {
                    Button(role: .destructive) {
                        withAnimation(Motion.ui) { _ = actions.moveToTrash([subscription]) }
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
            .animation(Motion.ui, value: archived.count)
        }
        .scrollContentBackground(.hidden)
        .background(SauryTheme.background)
        .navigationTitle("归档订阅")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(confirmTitle, isPresented: confirmBinding, titleVisibility: .visible) {
            Button("彻底删除，不可恢复", role: .destructive) {
                if let target = pendingForever {
                    withAnimation(Motion.ui) { _ = actions.deleteForever([target]) }
                }
                pendingForever = nil
            }
            Button("取消", role: .cancel) { pendingForever = nil }
        } message: {
            Text("这条订阅连同它的历史扣费记录一起从本机删掉，没有撤销入口。同步过的设备会把它移进回收站。")
        }
    }

    private var confirmTitle: String {
        "彻底删除「\(pendingForever?.name ?? "")」？"
    }

    private var confirmBinding: Binding<Bool> {
        Binding(get: { pendingForever != nil },
                set: { if !$0 { pendingForever = nil } })
    }
}

/// 回收站：软删除的订阅随时可以恢复，也可以当场彻底删除。
///
/// 满保留期的那几条会在进这一页时被真的清掉（另外两处在冷启动和回到前台，
/// 见 `TrashJanitor`）。判据是 `deletedAt` 加日历天，写在 `TrashPolicy`；
/// 这一屏那句「还剩 N 天」、页脚那条规则、清完之后弹的那句话，
/// 全部读同一份数字 —— 以前这里写着「保留 30 天」却没有任何一处按它清过。
struct TrashView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Subscription> { $0.deletedAt != nil })
    private var deleted: [Subscription]
    @EnvironmentObject private var preferences: SubPreferences
    @EnvironmentObject private var writeFeedback: WriteFeedbackCenter

    private var repository: SubscriptionRepository { SubscriptionRepository(context: modelContext) }
    private var actions: SubscriptionActions { SubscriptionActions(repository: repository) }

    @State private var pendingForever: Subscription?
    /// 这一屏的「现在」：每行那句「还剩 N 天」跟着它算。
    /// 每渲染一次读一次 `Date()` 的话，列表会在动画中间自己改字。
    @State private var renderedAt = Date()

    var body: some View {
        List {
            if deleted.isEmpty {
                Text("回收站是空的")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .staged(0)
            } else {
                ForEach(Array(deleted.enumerated()), id: \.element) { index, subscription in
                    HStack(spacing: 12) {
                        SubscriptionIconView(subscription: subscription, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(subscription.name).font(.subheadline.weight(.medium))
                            if let deletedAt = subscription.deletedAt {
                                Text(remainingText(deletedAt))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("恢复") {
                            withAnimation(Motion.ui) { _ = actions.restoreFromTrash([subscription]) }
                        }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(Pressable(scale: 0.92))
                        Button("彻底删除") { pendingForever = subscription }
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .buttonStyle(Pressable(scale: 0.92))
                    }
                    .staged(min(index, 8))
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
                .animation(Motion.ui, value: deleted.count)
            }
        }
        .scrollContentBackground(.hidden)
        .background(SauryTheme.background)
        .navigationTitle("回收站")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if deleted.isEmpty == false {
                Text(retentionFootnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, SauryTheme.screen)
                    .padding(.vertical, 8)
            }
        }
        .confirmationDialog(confirmTitle, isPresented: confirmBinding, titleVisibility: .visible) {
            Button("彻底删除，不可恢复", role: .destructive) {
                if let target = pendingForever {
                    withAnimation(Motion.ui) { _ = actions.deleteForever([target]) }
                }
                pendingForever = nil
            }
            Button("取消", role: .cancel) { pendingForever = nil }
        } message: {
            Text("这条订阅连同它的历史扣费记录一起从本机删掉，没有撤销入口。同步过的设备会把它移进回收站。")
        }
        .task {
            // 「现在」和到期判定用同一个时刻，页面上那句「还剩 N 天」才不会和这一脚删掉的东西打架。
            renderedAt = Date()
            let report = TrashJanitor(repository: repository, now: renderedAt).run()
            guard report.isQuiet == false, let message = report.feedback else { return }
            writeFeedback.show(message)
        }
    }

    private func remainingText(_ deletedAt: Date) -> String {
        "删除于 \(QJFormat.shortDate(deletedAt)) · "
            + TrashPolicy.notice(for: deletedAt, now: renderedAt)
    }

    private var retentionFootnote: String {
        """
        移入回收站起保留 \(TrashPolicy.retentionDays) 天，到期自动彻底删除：连同它的历史扣费记录、\
        以及只属于这一条的图标文件（几条订阅共用一张图时那张会留下）。这期间随时可以恢复，\
        「恢复」会把删除时间清掉，重新按在用的算。想留着历史花费又不想在列表里看到它，请用「归档」而不是删除。
        """
    }

    private var confirmTitle: String {
        "彻底删除「\(pendingForever?.name ?? "")」？"
    }

    private var confirmBinding: Binding<Bool> {
        Binding(get: { pendingForever != nil },
                set: { if !$0 { pendingForever = nil } })
    }
}
