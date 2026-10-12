import SwiftUI
import SwiftData
import StoreKit

/// 设置主页。
struct SettingsView: View {
    var demoRoute: Route? = nil

    @EnvironmentObject private var preferences: SubPreferences
    @Query private var subscriptions: [Subscription]

    @State private var pushedDemoRoute: Route?

    enum Route: Hashable {
        case appearance, layout
        case currency, categories, payments, notifications
        case archive, trash
        case data, storage
        case whatsNew, aboutApp, tipJar
    }

    var body: some View {
        if let pushedDemoRoute {
            destination(for: pushedDemoRoute)
        } else {
            homeList
        }
    }

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
        }
    }

    private var homeList: some View {
        List {
            Section("偏好") {
                NavigationLink(value: Route.appearance) { Label("外观", systemImage: "circle.lefthalf.filled") }
                NavigationLink(value: Route.layout) { Label("总览布局", systemImage: "square.grid.2x2") }
                NavigationLink(value: Route.notifications) { Label("通知", systemImage: "bell") }
            }
            Section("订阅") {
                NavigationLink(value: Route.currency) {
                    HStack { Label("货币", systemImage: "dollarsign.circle"); Spacer(); Text(preferences.defaultCurrency).foregroundStyle(.secondary) }
                }
                NavigationLink(value: Route.categories) { Label("分类", systemImage: "tag") }
                NavigationLink(value: Route.payments) { Label("支付方式", systemImage: "creditcard") }
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
        .onAppear {
            if pushedDemoRoute == nil {
                pushedDemoRoute = demoRoute
            }
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
            Section {
                AppIconSwitcher()
            } footer: {
                Text("「自动」跟随系统在亮/暗色间切换。切换时系统会弹一下确认提示。")
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
                Text("开启后，月均和平均每个以文字形式显示在总额下方，不再占用独立卡片位置。")
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
    @State private var authorized: UNAuthorizationStatus = .notDetermined
    @State private var countdown: Int?

    var body: some View {
        List {
            Section {
                Toggle("开启提醒", isOn: Binding(
                    get: { preferences.notificationsEnabled },
                    set: { enabled in
                        preferences.notificationsEnabled = enabled
                        if enabled {
                            Task {
                                let granted = await SubscriptionScheduler.shared.requestAuthorization()
                                if !granted { preferences.notificationsEnabled = false }
                            }
                        }
                    }
                ))
            } footer: {
                Text(authorized == .authorized
                    ? "通知已开启，我们会按每个订阅的设置准时提醒你。"
                    : "开启后，订阅会在扣费前按时提醒你；系统首次会请求通知权限。")
            }

            Section {
                Stepper(value: Binding(
                    get: { preferences.defaultReminderDays },
                    set: { preferences.defaultReminderDays = $0 }
                ), in: 0...30) {
                    Text(preferences.defaultReminderDays == 0 ? "新建订阅不提醒" : "新建订阅默认提前 \(preferences.defaultReminderDays) 天提醒")
                        .font(.subheadline)
                }
                Stepper(value: Binding(
                    get: { preferences.reminderHour },
                    set: { preferences.reminderHour = $0 }
                ), in: 0...23) {
                    Text("提醒时刻：\(preferences.reminderHour):00")
                        .font(.subheadline.monospacedDigit())
                }
            } footer: {
                Text("新建订阅默认就用这个提醒天数，之后单条可改；提醒落在当天的整点。")
            }

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

    private func sendPreview() async {
        let granted = await SubscriptionScheduler.shared.requestAuthorization()
        guard granted else { return }
        countdown = 3
        SubscriptionScheduler.shared.sendPreview(after: 3)
        while let current = countdown, current > 0 {
            try? await Task.sleep(for: .seconds(1))
            countdown = (countdown ?? 1) - 1
        }
        countdown = nil
    }
}

/// 归档订阅列表：可以恢复或彻底删除。
struct ArchiveListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Subscription> { $0.archivedAt != nil && $0.deletedAt == nil })
    private var archived: [Subscription]
    @EnvironmentObject private var preferences: SubPreferences

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
                        SelectionHaptics.success()
                        withAnimation(Motion.ui) {
                            subscription.archivedAt = nil
                            subscription.markUpdated()
                        }
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(Pressable(scale: 0.92))
                }
                .staged(min(index, 8))
                .transition(.opacity.combined(with: .move(edge: .leading)))
                .swipeActions {
                    Button(role: .destructive) {
                        SelectionHaptics.impact(.medium)
                        withAnimation(Motion.ui) {
                            subscription.deletedAt = Date()
                            subscription.markUpdated()
                        }
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
    }
}

/// 回收站：30 天后自动清除，期间随时恢复。
struct TrashView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Subscription> { $0.deletedAt != nil })
    private var deleted: [Subscription]
    @EnvironmentObject private var preferences: SubPreferences

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
                                Text("删除于 " + QJFormat.shortDate(deletedAt) + " · 保留 30 天")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("恢复") {
                            SelectionHaptics.success()
                            withAnimation(Motion.ui) {
                                subscription.deletedAt = nil
                                subscription.markUpdated()
                            }
                        }
                        .font(.footnote.weight(.semibold))
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
    }
}
