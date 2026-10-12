import SwiftUI
import SwiftData

enum MainTab: Hashable {
    case overview, subscriptions, settings

    var index: Int {
        switch self {
        case .overview: return 0
        case .subscriptions: return 1
        case .settings: return 2
        }
    }
}

/// 根视图：三个页面 + 自定义底部栏 + 新增按钮。
/// 系统的 TabView 排不出「胶囊 + 独立加号」的形状，这一层自己画。
struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var preferences: SubPreferences
    @EnvironmentObject private var cloudSync: CloudSyncEngine

    @Query private var allSubscriptions: [Subscription]
    @Query private var events: [SubscriptionEvent]

    @Namespace private var tabPill
    @State private var selectedTab: MainTab = .overview
    @State private var tabDirection = 1
    @State private var showingAdd = false
    @State private var addEditing: Subscription?
    @State private var addPrefillName = ""
    @State private var selectedDetail: Subscription?
    @State private var showingOnboarding = !SubPreferences.shared.hasOnboarded
    @State private var showingReminderPrompt = false
    @State private var toast: ToastCenter.Message?

    var body: some View {
        ZStack {
            pages
        }
        // 底色必须是 background 修饰符，不能当 ZStack 的第一个子视图：
        // 退场那页会被画在不透明底色下面，滑出去的一半根本看不见，
        // 看起来就像旧页瞬间消失、中间露出一屏黑。
        .background { SauryTheme.background.ignoresSafeArea() }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .tint(Color(hex: preferences.accentHex) ?? .accentColor)
        .preferredColorScheme(preferences.appearance.colorScheme)
        .environmentObject(ToastCenter.shared)
        .sheet(isPresented: $showingAdd) {
            AddSubscriptionView(editing: addEditing, prefillName: addPrefillName)
                .presentationDragIndicator(.visible)
                .onDisappear {
                    addPrefillName = ""
                    addEditing = nil
                }
        }
        .sheet(item: $selectedDetail) { subscription in
            SubscriptionDetailView(subscription: subscription) {
                // 演示参数不带编辑；真实入口在列表与总览里。
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showingOnboarding) {
            OnboardingView {
                showingOnboarding = false
                preferences.hasOnboarded = true
            }
        }
        .sheet(isPresented: $showingReminderPrompt) {
            ReminderPromptView {
                showingReminderPrompt = false
            }
            .presentationDragIndicator(.visible)
        }
        .toast($toast)
        .task {
            await prepareVisualDemoIfNeeded()
            await refreshSideEffects()
            checkFirstSubscriptionReminderPrompt()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshSideEffects() }
        }
        .onChange(of: allSubscriptions.count) { _, _ in
            // 第一笔订阅是保存之后才出现的，引导必须挂在这里；
            // 只在启动时问一次的话，用户当次永远等不到（模拟器操作验证抓出来的）。
            checkFirstSubscriptionReminderPrompt()
            Task { await refreshSideEffects() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sauryDataChanged)) { _ in
            Task { await refreshSideEffects() }
        }
    }

    /// 切 tab：先记方向，页面才能往对的一侧滑走。
    private func select(_ tab: MainTab, haptic: Bool = true) {
        guard tab != selectedTab else { return }
        tabDirection = tab.index > selectedTab.index ? 1 : -1
        if haptic { SelectionHaptics.tick() }
        withAnimation(Motion.slide) { selectedTab = tab }
    }

    /// 第一笔订阅保存后问一次「要不要开提醒」——竞品的引导路径。
    private func checkFirstSubscriptionReminderPrompt() {
        guard !SubPreferences.shared.hasOnboarded == false else { return }
        guard !preferences.notificationsEnabled,
              !UserDefaults.standard.bool(forKey: "saury.askedReminderPrompt"),
              !allSubscriptions.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: "saury.askedReminderPrompt")
        showingReminderPrompt = true
    }

    /// 截图/演示用的启动参数：-saury-demo 跳过引导并灌入示例订阅（仅 DEBUG）。
    /// 可再带 `-saury-tab <overview|subscriptions|settings|add>` 直达某个页面。
    private func prepareVisualDemoIfNeeded() async {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-saury-demo") else { return }
        preferences.hasOnboarded = true
        preferences.appearance = .dark
        showingOnboarding = false
        // 操作验证要从空库开始：库里出现的每一行都只能是脚本真写出来的。
        if allSubscriptions.isEmpty, !arguments.contains("-saury-ops") {
            for subscription in DemoDataSeeder.sampleSubscriptions() {
                modelContext.insert(subscription)
            }
            try? modelContext.save()
        }
        if let index = arguments.firstIndex(of: "-saury-tab"), index + 1 < arguments.count {
            switch arguments[index + 1] {
            case "subscriptions": select(.subscriptions, haptic: false)
            case "settings": select(.settings, haptic: false)
            case "add":
                select(.subscriptions, haptic: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showingAdd = true }
            case "detail":
                select(.subscriptions, haptic: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    selectedDetail = allSubscriptions.first
                }
            case "icloud", "appearance", "about", "whatsnew":
                select(.settings, haptic: false)
            default: break
            }
        }
        if arguments.contains("-saury-motion") { runMotionCaptureScript() }
        if arguments.contains("-saury-ops") { runQAOpsScript() }
        #endif
    }

    #if DEBUG
    /// 操作验证剧本：把用户真正的写入路径按顺序走一遍 ——
    /// 打开新增表单（表单自己填字段并按保存）→ 重新打开成编辑态 → 详情里归档。
    /// 每一步之间留 2 秒以上，方便外面截图和读库对账。
    private func runQAOpsScript() {
        let marks: [(Double, () -> Void)] = [
            (5.0, { select(.subscriptions, haptic: false) }),
            (6.0, { addEditing = nil; showingAdd = true }),
            (11.0, { showingReminderPrompt = false }),
            (12.5, { addEditing = qaItem; showingAdd = true }),
            (18.0, { showingReminderPrompt = false }),
            (19.5, { selectedDetail = qaItem }),
            (25.0, { selectedDetail = nil }),
            (27.0, { select(.overview, haptic: false) })
        ]
        for (delay, action) in marks {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    }

    private var qaItem: Subscription? {
        allSubscriptions.first { $0.name == "QA 自动验证" }
    }
    #endif

    #if DEBUG
    /// 动效录制用的自动剧本：每个动作之间留出 1.5 秒静止，
    /// 这样逐帧分析能把一段段动画单独切出来量时长。
    /// 起点推迟到 8 秒，留给启动和模拟器接管屏幕。
    private func runMotionCaptureScript() {
        let marks: [(Double, () -> Void)] = [
            (8.0, { select(.subscriptions, haptic: false) }),
            (10.5, { select(.settings, haptic: false) }),
            (13.0, { select(.overview, haptic: false) }),
            (16.0, { showingAdd = true }),
            (19.0, { showingAdd = false }),
            (21.5, { select(.subscriptions, haptic: false) }),
            (24.0, { selectedDetail = (try? modelContext.fetch(FetchDescriptor<Subscription>()))?.first })
        ]
        for (delay, action) in marks {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    }
    #endif

    /// 三页各写一个 `if`：这样换页时旧页还在树上，能跟着一起滑走。
    private var pageTransition: AnyTransition {
        .directionalSlide(tabDirection, distance: 64, shrink: 0.02)
    }

    @ViewBuilder
    private var pages: some View {
        if selectedTab == .overview {
            NavigationStack { OverviewView(onSelectTab: { select($0, haptic: false) }) }
                .transition(pageTransition)
        }
        if selectedTab == .subscriptions {
            NavigationStack {
                SubscriptionsView(onAdd: { showingAdd = true }, onSelectTab: { select($0, haptic: false) })
            }
            .transition(pageTransition)
        }
        if selectedTab == .settings {
            NavigationStack { settingsPage }
                .transition(pageTransition)
        }
    }

    private var settingsPage: SettingsView {
        var settings = SettingsView()
        #if DEBUG
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-saury-tab"),
           index + 1 < ProcessInfo.processInfo.arguments.count {
            switch ProcessInfo.processInfo.arguments[index + 1] {
            case "icloud": settings.demoRoute = .data
            case "appearance": settings.demoRoute = .appearance
            case "about": settings.demoRoute = .aboutApp
            case "whatsnew": settings.demoRoute = .whatsNew
            default: break
            }
        }
        #endif
        return settings
    }

    // MARK: - 底部栏

    private var bottomBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                tabButton(.overview, symbol: "chart.pie.fill", selectedSymbol: "chart.pie.fill", title: "总览")
                tabButton(.subscriptions, symbol: "archivebox", selectedSymbol: "archivebox.fill", title: "订阅")
                tabButton(.settings, symbol: "gear", selectedSymbol: "gear.fill", title: "设置")
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(light: .white, dark: Color(red: 0.13, green: 0.13, blue: 0.14)))
                    .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
            )

            Button {
                SelectionHaptics.impact(.light)
                showingAdd = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(showingAdd ? 135 : 0))
                    .frame(width: 56, height: 56)
                    .background(
                        Circle().fill(
                            LinearGradient(
                                colors: [Color(hex: preferences.accentHex) ?? .blue, (Color(hex: preferences.accentHex) ?? .blue).opacity(0.75)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: (Color(hex: preferences.accentHex) ?? .blue).opacity(0.45), radius: showingAdd ? 4 : 10, y: showingAdd ? 2 : 5)
                    )
                    .animation(Motion.pop, value: showingAdd)
            }
            .buttonStyle(Pressable(scale: 0.9, animation: Motion.pop))
            .accessibilityLabel("新增订阅")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        // 强调色跟随：只能挂在底部栏上。挂在页面容器上会把它自己
        // 那棵子树的动画事务覆盖掉 —— 换页的 withAnimation 直接失效，
        // 旧页瞬间消失、新页连滑入都没有（实测中间露出 150ms 黑底）。
        .animation(Motion.page, value: preferences.accentHex)
    }

    private func tabButton(_ tab: MainTab, symbol: String, selectedSymbol: String, title: String) -> some View {
        let isSelected = selectedTab == tab
        let accent = Color(hex: preferences.accentHex) ?? .accentColor
        return Button {
            select(tab)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: isSelected ? selectedSymbol : symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .symbolEffect(.bounce, value: isSelected)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(height: 22)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .opacity(isSelected ? 1 : 0.75)
            }
            .foregroundStyle(isSelected ? accent : Color.secondary)
            .scaleEffect(isSelected ? 1 : 0.96)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(accent.opacity(0.16))
                        .matchedGeometryEffect(id: "tabPill", in: tabPill)
                }
            }
            .contentShape(Rectangle())
            .animation(Motion.ui, value: isSelected)
        }
        .buttonStyle(Pressable(scale: 0.93))
    }

    // MARK: - 副作用

    private func refreshSideEffects() async {
        let subscriptions = allSubscriptions
        let reminderDays = preferences.defaultReminderDays
        let hour = preferences.reminderHour
        let enabled = preferences.notificationsEnabled
        await SubscriptionScheduler.shared.refill(
            subscriptions: subscriptions,
            defaultReminderDays: reminderDays,
            hour: hour,
            enabled: enabled
        )
        WidgetSnapshotStore.update(subscriptions: subscriptions, defaultCurrency: preferences.defaultCurrency)
        drainExternalInput()
        ToastCenter.shared.post = { message in toast = message }
        // 汇率每 24 小时自动同步一次（页脚承诺的那句话）。
        await ExchangeRateStore.shared.refreshIfStale()
        if cloudSync.autoSyncEnabled {
            await cloudSync.syncNow(context: modelContext)
        }
    }

    /// 快捷指令 / 分享扩展递进来的条目：文字和链接取名字，直接进添加页。
    /// 图片在新产品里没有 OCR 流程，只能留在队列外面 —— 直接消费掉并提示。
    private func drainExternalInput() {
        guard !showingAdd, !showingOnboarding else { return }
        while let draft = ExternalInputStore.consume() {
            switch draft.payload {
            case .text(let text):
                let name = text.split(separator: "\n").first.map(String.init) ?? text
                guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                addPrefillName = name.trimmingCharacters(in: .whitespaces)
                showingAdd = true
                return
            case .url(let urlString):
                let host = URL(string: urlString)?.host ?? urlString
                addPrefillName = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                showingAdd = true
                return
            case .fields(let fields):
                addPrefillName = fields.name
                showingAdd = true
                return
            case .image:
                continue
            }
        }
    }
}

/// 轻量 toast：设置页的「已同步」「汇率已更新」这类一闪而过的话。
@MainActor
final class ToastCenter: ObservableObject {
    struct Message: Equatable {
        let symbol: String
        let text: String
    }

    static let shared = ToastCenter()
    var post: ((Message) -> Void)?

    func show(_ symbol: String, _ text: String) {
        post?(Message(symbol: symbol, text: text))
    }
}

extension View {
    func toast(_ binding: Binding<ToastCenter.Message?>) -> some View {
        overlay(alignment: .top) { ToastBanner(message: binding) }
    }
}

/// toast 自己管自己的动画。`.animation(value:)` 只能写在这棵子树里：
/// 挂在宿主视图上会把宿主整棵子树（包括三个页面）的动画事务改成 nil，
/// 换页的 withAnimation 全部作废 —— 旧页瞬间消失，中间露出黑底。
private struct ToastBanner: View {
    @Binding var message: ToastCenter.Message?

    var body: some View {
        Group {
            if let toast = message {
                HStack(spacing: 8) {
                    Image(systemName: toast.symbol)
                    Text(toast.text).font(.footnote.weight(.medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color(white: 0.15).opacity(0.95)))
                .padding(.top, 8)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.86)).combined(with: .offset(y: -10)),
                    removal: .opacity.combined(with: .offset(y: -14))
                ))
                .task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation(Motion.ui) { message = nil }
                }
            }
        }
        .animation(Motion.pop, value: message)
    }
}
