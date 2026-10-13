import SwiftUI
import SwiftData
import UIKit
import UserNotifications
import os

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
    @EnvironmentObject private var sync: SyncCoordinator
    @EnvironmentObject private var writeFeedback: WriteFeedbackCenter

    @Query private var allSubscriptions: [Subscription]
    @Query private var events: [SubscriptionEvent]

    @Namespace private var tabPill
    @State private var selectedTab: MainTab = .overview
    /// 每个 Tab 自己的导航栈。存在根视图这里，换 Tab 时栈不会被销毁，
    /// push 出去的归档页 / 日历页就还在原地（任务书 §6.3）。
    @State private var paths: [MainTab: NavigationPath] = [:]
    /// 全站唯一的一张 sheet：新增、编辑、详情、筛选、提醒引导都从这里出。
    @StateObject private var sheets = SheetRouter()
    @State private var showingOnboarding = !SubPreferences.shared.hasOnboarded
    @State private var toast: ToastCenter.Message?
    // 库出过事：挪库重建过，或者只能跑在内存库上。这条不是一闪而过的 toast ——
    // 启动那几秒用户可能根本没在看屏幕。
    @State private var storeNotice: String?
    @State private var showingStoreNotice = false

    var body: some View {
        ZStack {
            pages
        }
        // 底色必须是 background 修饰符，不能当 ZStack 的第一个子视图：
        // 退场那页会被画在不透明底色下面，滑出去的一半根本看不见，
        // 看起来就像旧页瞬间消失、中间露出一屏黑。
        .background { SauryTheme.background.ignoresSafeArea() }
        #if DEBUG
        // 录屏对齐带：只在探针打点的那两帧是白的，用来把录屏秒数钉到日志的墙上时钟。
        .overlay(alignment: .top) { ProbeMarkerBand() }
        #endif
        .safeAreaInset(edge: .top, spacing: 0) { storeNoticeBanner }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        // 撤销/失败条挂在根视图上：详情页删完会关页，条子不能跟着 sheet 一起消失。
        .writeFeedback($writeFeedback.message, bottomPadding: 86) { writeFeedback.performAction() }
        .tint(Color(hex: preferences.accentHex) ?? .accentColor)
        .preferredColorScheme(preferences.appearance.colorScheme)
        .environmentObject(ToastCenter.shared)
        .environmentObject(sheets)
        .sheet(item: $sheets.route, onDismiss: sheets.noteClosed) { route in
            switch route {
            case .add(let prefill):
                AddSubscriptionView(editing: nil, prefill: prefill)
                    .presentationDragIndicator(.visible)
            case .edit(let id):
                RoutedEditView(id: id)
            case .detail(let id):
                RoutedDetailView(id: id)
            case .filter:
                SubscriptionFilterSheet()
                    .presentationDragIndicator(.visible)
            case .reminderPrompt:
                ReminderPromptView { sheets.close() }
                    .presentationDragIndicator(.visible)
            }
        }
        .fullScreenCover(isPresented: $showingOnboarding) {
            OnboardingView {
                showingOnboarding = false
                preferences.hasOnboarded = true
            }
        }
        .toast($toast)
        .task {
            reportStoreTroubleIfNeeded()
            await prepareVisualDemoIfNeeded()
            await refreshSideEffects()
            checkFirstSubscriptionReminderPrompt()
            // 冷启动是被通知点开的那种：这一次点击存进了队列，界面刚挂上就该跳过去。
            if let id = ReminderNavigation.shared.consume() { openFromReminder(id) }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshSideEffects() }
            // 回到前台是任务书 §4.2 列的六个触发源之一。
            // 没开自动同步时协调器自己会咽下这一脚。
            Task { await sync.requestSync(reason: .foreground) }
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
        // §6.2 副作用表：提醒这两格一动，待处理通知就得跟着重排。
        // 留给「下次回前台」去生效，就是那句「重新打开 App 才刷新」。
        .onChange(of: preferences.notificationsEnabled) { _, _ in
            Task { await rescheduleReminders() }
        }
        .onChange(of: preferences.reminderHour) { _, _ in
            Task { await rescheduleReminders() }
        }
        .onChange(of: preferences.defaultCurrency) { _, _ in
            WidgetSnapshotStore.update(subscriptions: allSubscriptions,
                                       defaultCurrency: preferences.defaultCurrency)
        }
        // 通知里点「查看订阅」进来的那一条。
        .onReceive(NotificationCenter.default.publisher(for: .sauryOpenSubscription)) { _ in
            if let id = ReminderNavigation.shared.consume() { openFromReminder(id) }
        }
    }

    /// 从通知跳进某条订阅。找不到就直说 —— 那条通知要么是删掉之后的残留，
    /// 要么是设置页的预览，都不该假装打开了一条订阅。
    private func openFromReminder(_ id: UUID) {
        guard allSubscriptions.first(where: { $0.id == id }) != nil else {
            toast = ToastCenter.Message(symbol: "bell.slash", text: "这条订阅在本机已经找不到了")
            return
        }
        select(.subscriptions, haptic: false)
        sheets.present(.detail(id))
    }

    /// 切 tab：方向由页序自己决定（见 `pages`），这里只管落地。
    private func select(_ tab: MainTab, haptic: Bool = true) {
        guard tab != selectedTab else { return }
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
        // 这一句是在「新增」那页刚关掉的时候说的：router 会把这次呈现排到退场跑完，
        // 而不是趁动画还在播的时候硬塞进去（那样整段会被系统丢掉）。
        sheets.present(.reminderPrompt)
    }

    /// 库出过事就把话摆在首屏：静默显示一个空库，等于让用户以为数据自己没了。
    private func reportStoreTroubleIfNeeded() {
        guard storeNotice == nil, let notice = PersistenceController.launchNotice else { return }
        storeNotice = notice
        withAnimation(Motion.ui) { showingStoreNotice = true }
    }

    /// 首屏那条说明上的「去找回数据」：把人送到设置里的「iCloud 与数据」页。
    ///
    /// 这里原来是给 `SettingsView.demoRoute` 赋值。那一格只在设置页第一次 `onAppear` 时读一次，
    /// 而三页从启动起就一直挂在视图树上（§6.3），那一次早在没有任何目标的时候就用掉了，
    /// 之后没有任何代码再看这个值 —— 按钮按下去只换了个 Tab，数据页根本没打开
    /// （跳转探针 08:17:29 那两行：`当前页=settings，设置页栈 0 层`）。
    /// 现在往设置那条栈上真 push 一层，和用户在列表里点进子页走的是同一个 NavigationStack。
    private func openStoreRecoveryPage() {
        goToSettings(.data)
    }

    /// 跳到设置页的某一格：切过去，再往设置自己那条栈上压一层。压上去就有返回按钮，
    /// 不是把设置主页整块换成别的脸。
    private func goToSettings(_ route: SettingsView.Route, haptic: Bool = true) {
        select(.settings, haptic: haptic)
        var path = paths[.settings] ?? NavigationPath()
        path.append(route)
        withAnimation(Motion.slide) { paths[.settings] = path }
    }

    @ViewBuilder
    private var storeNoticeBanner: some View {
        if showingStoreNotice, let notice = storeNotice {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(notice)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(Motion.ui) { showingStoreNotice = false }
                    } label: {
                        Image(systemName: "xmark").font(.caption.weight(.bold))
                    }
                    .accessibilityLabel("收起这条提示")
                }
                HStack(spacing: 10) {
                    Button("去找回数据") { openStoreRecoveryPage() }
                        .buttonStyle(.borderedProminent)
                    Text("原来的库文件还在手机里，没有被删")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: SauryTheme.cardRadius, style: .continuous)
                .fill(SauryTheme.surfaceElevated))
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .transition(.offset(y: -24).combined(with: .opacity))
        }
    }

    /// 截图/演示用的启动参数：-saury-demo 跳过引导并灌入示例订阅（仅 DEBUG）。
    /// 可再带 `-saury-tab <overview|subscriptions|settings|add>` 直达某个页面。
    private func prepareVisualDemoIfNeeded() async {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        // 引导页要单独截：这台机器上的库早就引导完了，只能把这一页重新摆出来。
        if arguments.contains("-saury-onboarding") {
            showingOnboarding = true
            return
        }
        // 备份探针自己会清库，绝不能和演示数据那条路混在一起跑。
        if arguments.contains("-saury-backup") {
            BackupSandboxProbe.run(context: modelContext, preferences: preferences)
            return
        }
        // 「库里一条都没有」那一屏只能用真空库拍：这条路绝不能带 `-saury-demo`，
        // 一带就往库里灌三行，拍到的就是有数据的列表了。这里只跳过引导、走到订阅页。
        if arguments.contains("-saury-list-empty") {
            preferences.hasOnboarded = true
            showingOnboarding = false
            select(.subscriptions, haptic: false)
            return
        }
        guard arguments.contains("-saury-demo") else { return }
        preferences.hasOnboarded = true
        preferences.appearance = .dark
        showingOnboarding = false
        // 操作验证要从空库开始：库里出现的每一行都只能是脚本真写出来的。
        if allSubscriptions.isEmpty, !arguments.contains("-saury-ops") {
            // 演示数据也走同一个写库入口：截图里看到的每一行都必须是真落盘的，
            // 塞进内存再靠自动保存去赌不算。
            do {
                try SubscriptionRepository(context: modelContext)
                    .install(DemoDataSeeder.sampleSubscriptions())
            } catch {
                writeFeedback.show(.failure(error.localizedDescription))
            }
        }
        if let index = arguments.firstIndex(of: "-saury-tab"), index + 1 < arguments.count {
            switch arguments[index + 1] {
            case "subscriptions": select(.subscriptions, haptic: false)
            case "settings": select(.settings, haptic: false)
            case "add":
                select(.subscriptions, haptic: false)
                // 这 0.6 秒只属于截图探针：窗口刚装好那一帧弹 sheet 有时会被系统吃掉。
                // 用户走的入口在 `.task` 之外，不靠这种延时。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    sheets.present(.add(prefill: .empty))
                }
            case "detail":
                select(.subscriptions, haptic: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if let first = allSubscriptions.first { sheets.present(.detail(first.id)) }
                }
            case "calendar":
                // 翻月录屏要从日历页开始：这一条走的就是面板上那一下 `push`。
                select(.overview, haptic: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    push(.overview, OverviewView.Route.calendar)
                }
            case "icloud", "data": goToSettings(.data, haptic: false)
            case "appearance": goToSettings(.appearance, haptic: false)
            case "about": goToSettings(.aboutApp, haptic: false)
            case "whatsnew": goToSettings(.whatsNew, haptic: false)
            case "notifications": goToSettings(.notifications, haptic: false)
            default: break
            }
        }
        if arguments.contains("-saury-motion") { runMotionCaptureScript() }
        if arguments.contains("-saury-ops") { runQAOpsScript() }
        if arguments.contains("-saury-nav") { runNavigationProbe() }
        if arguments.contains("-saury-jump") { await runStoreJumpProbe() }
        if arguments.contains("-saury-form") { runFormProbe() }
        // 分享扩展探针：按扩展那份线上 JSON 往 App Group 放一条图片 + 一条文字，
        // 再走用户回到前台时那一句真实的消费。
        if arguments.contains("-saury-share") { await runShareProbe() }
        // 回收站探针：两条触发路各跑一次，图标按引用计数看盘上的文件。
        if arguments.contains("-saury-trash") { await runTrashProbe() }
        // 同步探针：命令行没有辅助功能权限，点不动「立即同步」那一下，
        // 就直接调那个按钮走的同一个方法，看这一页最后把结果说成什么样子。
        if arguments.contains("-saury-sync") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                Task { await sync.requestSync(reason: .manual) }
            }
        }
        // 通知探针：单测跑的全是假件（`FakeDelivery`），这一条走的是真的
        // `UNUserNotificationCenter`：申请权限 → 重排 → 把系统中心里此刻真的挂着的那几条念出来。
        // 「会不会响」还得靠肉眼在真机上看，但「真的排进系统了没有」在这里就能对账。
        if arguments.contains("-saury-reminders") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                Task { await runReminderProbeWithRealCenter() }
            }
        }
        // 对齐缺口探针：种两条真数据看「待付款 / 试用中」面板，再走去设置那两个新入口。
        if arguments.contains("-saury-gaps") { await runGapProbe() }
        // 头像弹动与金额放大（矩阵 EON-005/007）：打字那几步在表单自己那一层。
        if arguments.contains("-saury-hero") { runHeroProbe() }
        #endif
    }

    #if DEBUG
    /// 截图只能证明「这一帧长什么样」，按秒去猜哪一帧对应哪一步猜不准 ——
    /// 每一步都打一行时间戳，外面才能把截图和动作对上。
    static let probeLogger = Logger(subsystem: "com.guofeng.saury", category: "probe")

    private func runReminderProbeWithRealCenter() async {
        // 这一段要验的是：提醒能不能真的排进系统中心、排进去的是哪几条、系统会不会真投递。
        let before = await SubscriptionScheduler.shared.authorizationStatus()
        // 这里**不**调标准的 `requestAuthorization`：那一下会弹系统模态框，而这台机器的
        // 命令行没有辅助功能权限（`simctl privacy` 也没有 notifications 这一档），
        // 点不动它，整趟探针会卡在弹窗上。`provisional` 是静默授权，不当场问用户、
        // 立刻返回，足够把「授权之后系统收不收」这一段读回来。
        // 代价是这台设备上要重装一次才会回到「还没问过」，权限框本身另截了图
        // （`build/verification/pr4/03-authorization-prompt.png`）。
        var asked = "没再问"
        if before == .notDetermined {
            let granted = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge, .provisional])
            asked = "静默申请\(granted == true ? "成功" : "失败")"
        }
        let status = await SubscriptionScheduler.shared.authorizationStatus()
        let pendingBefore = await pendingReminders()
        let report = await SubscriptionScheduler.shared.refill(
            subscriptions: allSubscriptions,
            hour: preferences.reminderHour,
            enabled: true)
        let justNow = await pendingReminders()
        // 排进去和读回来是两次 XPC：中间隔 2 秒再读一次，是为了分清
        // 「系统压根没收下」和「我读得太早」——这两种在界面上长得一模一样。
        try? await Task.sleep(for: .seconds(2))
        let later = await pendingReminders()
        SauryLog.notificationScheduled(
            "探针：授权 \(Self.authorizerName(before))→\(Self.authorizerName(status))（\(asked)） "
            + "结果 排入\(report.added)/撤回\(report.removed)/拒收\(report.rejected) "
            + "系统挂着 排前\(pendingBefore.count)/刚排完\(justNow.count)/两秒后\(later.count) 条")
        for request in later.sorted(by: { $0.identifier < $1.identifier }) {
            let trigger = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
            SauryLog.notificationScheduled(
                "挂着：\(request.identifier) 响于\(trigger.map { Self.probeDate($0) } ?? "读不出") "
                    + "正文「\(request.content.body)」动作组 \(request.content.categoryIdentifier)")
        }
        // 投递这一段用设置页那个「预览通知样式」走的同一个方法：
        // 同一条正文渲染、同一个动作组，只是触发器换成 3 秒后。
        // 这样读回来的「已送达」就不是我们自己写的日志，而是系统中心的账。
        await SubscriptionScheduler.shared.sendPreview(subscription: allSubscriptions.first,
                                                       after: 3)
        try? await Task.sleep(for: .seconds(6))
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
            .filter { $0.request.identifier.hasPrefix("saury.") }
        SauryLog.notificationScheduled("探针：系统已送达 \(delivered.count) 条")
        for note in delivered {
            SauryLog.notificationScheduled(
                "已送达：\(note.request.identifier) 正文「\(note.request.content.body)」"
                    + "动作组 \(note.request.content.categoryIdentifier)")
        }
    }

    private func pendingReminders() async -> [UNNotificationRequest] {
        await UNUserNotificationCenter.current().pendingNotificationRequests()
            .filter { ReminderPlan.isReminderIdentifier($0.identifier) }
    }

    private static func authorizerName(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "已授权"
        case .denied: return "已拒绝"
        case .notDetermined: return "还没问过"
        case .provisional: return "静默投递"
        case .ephemeral: return "临时会话"
        @unknown default: return "未知(\(status.rawValue))"
        }
    }

    private static func probeDate(_ date: Date) -> String {
        let parts = BillingMath.calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        return "\(parts.month ?? 0)/\(parts.day ?? 0) \(parts.hour ?? 0):"
            + String(format: "%02d", parts.minute ?? 0)
    }
    #endif

    #if DEBUG
    /// 操作验证剧本：把用户真正的写入路径按顺序走一遍 ——
    /// 打开新增表单（表单自己填字段并按保存）→ 重新打开成编辑态 → 详情里归档 → 点撤销条上的「撤销」。
    /// 每一步之间留 2 秒以上，方便外面截图和读库对账。
    private func runQAOpsScript() {
        let marks: [(Double, String, () -> Void)] = [
            (5.0, "切到订阅", { select(.subscriptions, haptic: false) }),
            (6.0, "弹新增表单（表单自己填、自己按保存两次）", { sheets.present(.add(prefill: .empty)) }),
            (12.5, "重新弹成编辑态", { if let item = qaItem { sheets.present(.edit(item.id)) } }),
            (19.5, "弹详情（详情页自己那一层会去归档）", {
                if let item = qaItem { sheets.present(.detail(item.id)) }
            }),
            (25.0, "关掉详情", { sheets.close() }),
            // 归档条浮在根视图上，「撤销」就是条上那个按钮的同一个方法。
            (26.0, "点撤销条上的撤销", { writeFeedback.performAction() }),
            (27.0, "切回总览", { select(.overview, haptic: false) })
        ]
        for (delay, label, action) in marks {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Self.probeLogger.log("操作探针 \(label, privacy: .public)")
                action()
            }
        }
    }

    private var qaItem: Subscription? {
        allSubscriptions.first { $0.name == "QA 自动验证" }
    }

    /// 表单与键盘探针（任务书 §7.1）。根视图只负责把新增表单弹出来 ——
    /// 走格子、按保存、点取消那几步都发生在表单自己那一层，由 `AddSubscriptionView` 打时间戳。
    private func runFormProbe() {
        let marks: [(Double, String, () -> Void)] = [
            (4.0, "切到订阅", { select(.subscriptions, haptic: false) }),
            (5.0, "弹新增表单（接下来十步在表单那一层）", { sheets.present(.add(prefill: .empty)) })
        ]
        for (delay, label, action) in marks {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Self.probeLogger.log("导航探针 \(label, privacy: .public)")
                action()
            }
        }
    }

    /// 头像弹动与金额放大那一对探针（矩阵 EON-005/007）。
    /// 根视图只负责把新增表单弹出来 —— 打字、对账那几步在表单自己那一层（见
    /// `AddSubscriptionView.runHeroProbeIfNeeded`）。
    private func runHeroProbe() {
        let marks: [(Double, String, () -> Void)] = [
            (4.0, "切到订阅", { select(.subscriptions, haptic: false) }),
            (5.0, "弹新增表单（头像那几步在表单自己那一层）", { sheets.present(.add(prefill: .empty)) })
        ]
        for (delay, label, action) in marks {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Self.probeLogger.log("头像探针 \(label, privacy: .public)")
                action()
            }
        }
    }

    /// 对齐缺口探针（矩阵 EON-070/071）。
    ///
    /// 「待付款」「试用中」两块面板只在库里有那种订阅时才有内容，演示库不一定有；
    /// 这里按真写库入口（`repository.apply`）种两条 —— 一条手动续费、一条还没开始 ——
    /// 把面板顺序临时挑到最前，拍完恢复原顺序、把种的两条删掉。
    /// 设置里两个新入口的页内动作（抽签、复制诊断信息）由那两页自己的探针接手。
    /// 种名前缀 `EON ` 是幂等键：开场先清上一趟的残留。
    private func runGapProbe() async {
        // 首屏装好、启动那一趟副作用跑完，再往里放东西。这段等待不参与任何判定。
        try? await Task.sleep(for: .seconds(4))
        let repository = SubscriptionRepository(context: modelContext)
        let stale = allSubscriptions.filter { $0.name.hasPrefix("EON ") }
        if stale.isEmpty == false { try? repository.deletePermanently(stale) }
        try? await Task.sleep(for: .milliseconds(300))

        let calendar = BillingMath.calendar
        let midnight = calendar.startOfDay(for: Date())
        var manualDraft = SubscriptionDraft(name: "EON 手动续费", priceMinorUnits: 8800, currencyCode: "CNY")
        manualDraft.state = .manualRenew
        manualDraft.startDate = calendar.date(byAdding: .day, value: -20, to: midnight) ?? midnight
        var futureDraft = SubscriptionDraft(name: "EON 未开始", priceMinorUnits: 1990, currencyCode: "CNY")
        futureDraft.startDate = calendar.date(byAdding: .day, value: 12, to: midnight) ?? midnight
        guard let manual = try? repository.apply(manualDraft),
              let future = try? repository.apply(futureDraft) else {
            Self.probeLogger.log("对齐探针 种数据这一步就失败了，后面没有任何判定")
            return
        }

        let front: [OverviewPanel] = [.pendingPayment, .trial, .quickView]
        let originalOrder = preferences.panelOrder
        preferences.panelOrder = front + originalOrder.filter { front.contains($0) == false }
        select(.overview, haptic: false)
        try? await Task.sleep(for: .seconds(1.6))

        let dueDate = BillingMath.nextChargeDate(for: manual)
        let awaitingNames = SubscriptionQuery.awaitingPayment(allSubscriptions).map(\.name)
        let trialNames = SubscriptionQuery.notStarted(allSubscriptions).map(\.name)
        let seeded = "种完：手动续费那条下次扣费=\(dueDate.map { QJFormat.shortDate($0) } ?? "读不出")，"
            + "未开始那条 \(QJFormat.shortDate(future.startDate)) 才开始；"
            + "待付款候选 \(awaitingNames.count) 条（\(awaitingNames.joined(separator: "、"))）、"
            + "未开始候选 \(trialNames.count) 条（\(trialNames.joined(separator: "、"))）"
        Self.probeLogger.log("对齐探针 \(seeded, privacy: .public)")
        _ = await ProbeShutter.capture("gaps-01-overview-panels", settle: 1.2)

        goToSettings(.toys, haptic: false)
        // 小玩具页自己那一段在这 8 秒里抽两次签、各拍一帧。
        try? await Task.sleep(for: .seconds(8))
        goToSettings(.misc, haptic: false)
        // 其他页自己那一段在这 7 秒里复制诊断信息、读回剪贴板、各拍一帧。
        try? await Task.sleep(for: .seconds(7))

        preferences.panelOrder = originalOrder
        try? repository.deletePermanently([manual, future])
        let closing = "收尾：面板顺序已恢复，种的两条已删；库 \(allSubscriptions.count) 条、"
            + "回收站 \(probeTrashCount()) 条"
        Self.probeLogger.log("对齐探针 \(closing, privacy: .public)")
    }

    /// 分享扩展 → 添加表单这一整条链路（任务书 §10.5「分享图片时不得静默丢弃」）。
    ///
    /// 命令行点不动系统的分享面板，所以这里按 `ShareViewController` 那边**手写的同一份 JSON 形状**
    /// 往 App Group 里放两条草稿（一张图、一段文字），再调用户回到前台时真的会走的那一句
    /// `drainExternalInput()`。要验的两件事只有走真链路才看得到：
    /// 两个 target 之间那份契约解得开，图片从暂存目录搬成了订阅图标。
    /// 这一条以前的实现是 `case .image: continue` —— 用户按了「存进」，App 把图扔了还不说话。
    private func runShareProbe() async {
        // 首屏装好、启动那一趟 drain 跑完，再往里放东西。这一段等待不参与任何判定。
        try? await Task.sleep(for: .seconds(4))

        guard let pending = SharedImageIngest.stagedDirectory() else {
            Self.probeLogger.log("分享探针 App Group 暂存目录拿不到，图片这一条没法验")
            return
        }
        let fileName = "probe-\(UUID().uuidString.prefix(8)).jpg"
        let sample = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 600)).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
            NSAttributedString(string: "QA 分享图", attributes: [
                .font: UIFont.systemFont(ofSize: 64, weight: .heavy),
                .foregroundColor: UIColor.white
            ]).draw(at: CGPoint(x: 90, y: 260))
        }
        do {
            try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
            try sample.jpegData(compressionQuality: 0.85)!.write(
                to: pending.appendingPathComponent(fileName), options: .atomic)
        } catch {
            Self.probeLogger.log("分享探针 暂存图片没写出去：\(error.localizedDescription, privacy: .public)")
            return
        }

        let sharedText = "净云会员 年卡\n298 元 / 年\n到期 2027-01-01"
        do {
            try seedQueueTheWayTheExtensionDoes([
                ["kind": "image", "value": fileName],
                ["kind": "text", "value": sharedText]
            ])
        } catch {
            Self.probeLogger.log("分享探针 队列写不进去：\(error.localizedDescription, privacy: .public)")
            return
        }
        // `log(_:)` 要的是字符串字面量，拼接出来的 String 得先落到变量里再插进去。
        let seeded = "入队后：队列 \(ExternalInputStore.queue().count) 条，"
            + "看不懂 \(ExternalInputStore.unreadableCount()) 条"
        Self.probeLogger.log("分享探针 \(seeded, privacy: .public)")

        select(.subscriptions, haptic: false)
        drainExternalInput()
        try? await Task.sleep(for: .seconds(1.6))
        let imageReadout = formReadout(tag: "图片那条", expected: fileName)
        Self.probeLogger.log("分享探针 \(imageReadout, privacy: .public)")
        _ = await ProbeShutter.capture("share-01-image-icon", settle: 1.0)

        // 关掉这一张，队列里剩下的那条该在下一次前台时被带出来。
        sheets.close()
        try? await Task.sleep(for: .seconds(1.8))
        drainExternalInput()
        try? await Task.sleep(for: .seconds(1.6))
        let textReadout = formReadout(tag: "文字那条", expected: "净云会员 年卡")
        Self.probeLogger.log("分享探针 \(textReadout, privacy: .public)")
        _ = await ProbeShutter.capture("share-02-text-name", settle: 1.0)

        sheets.close()
        try? await Task.sleep(for: .seconds(1.4))
        let stagedAfter = pending.appendingPathComponent(fileName).path
        let closing = "收尾：队列还剩 \(ExternalInputStore.queue().count) 条，"
            + "暂存文件还在=\(FileManager.default.fileExists(atPath: stagedAfter))"
        Self.probeLogger.log("分享探针 \(closing, privacy: .public)")
    }

    /// 回收站到期清理探针（任务书 §10.6）。两条触发路各证一次，图标那一头跟着看。
    ///
    /// ①「数据变了 → 根视图那一脚」：正常写库、回拨删除时间、落盘。落盘就广播，
    ///   探针自己一次都不碰清理代码，只看它有没有把到期那条收掉。
    /// ②「进回收站页 → 页面那一脚」：回拨之后**故意不落盘**，所以没有广播、
    ///   根视图那一脚不会跑，只有页面 `.task` 那一脚能收掉它。
    ///   这种种法是探针专用的：真实路径里没有任何一处会写了删除时间又不保存。
    ///   它等的是「页面自己有没有查一次到期」这一步，不是「我们能不能删」。
    /// 图标两处判定：到期那条独占的那张要真的从磁盘上没了；两条共用的一张不能提前没，
    /// 要等最后一个引用也没了才没。
    private func runTrashProbe() async {
        // 首屏装好、启动那一趟副作用跑完，再往里放东西。这段等待不参与任何判定。
        try? await Task.sleep(for: .seconds(4))
        let repository = SubscriptionRepository(context: modelContext)
        // 幂等：先把上一趟留下的探针数据清干净，免得跑一次攒一条「还剩二十天」。
        let stale = allSubscriptions.filter { $0.name.hasPrefix("PR7d ") }
        if stale.isEmpty == false { try? repository.deletePermanently(stale) }
        try? await Task.sleep(for: .milliseconds(300))
        let leftover = allSubscriptions.filter { $0.name.hasPrefix("PR7d ") }.count
        Self.probeLogger.log("回收站探针 开场：上一趟留下探针数据 \(stale.count) 条，清完剩 \(leftover) 条")
        let calendar = BillingMath.calendar
        let midnight = calendar.startOfDay(for: Date())
        func stamp(_ days: Int) -> Date { calendar.date(byAdding: .day, value: days, to: midnight)! }
        func swatch(_ text: String) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300)).image { renderer in
                UIColor.systemTeal.setFill()
                renderer.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
                NSAttributedString(string: text, attributes: [
                    .font: UIFont.systemFont(ofSize: 52, weight: .heavy),
                    .foregroundColor: UIColor.white
                ]).draw(at: CGPoint(x: 52, y: 120))
            }
        }
        let solo = IconImageStore.shared.store(swatch("独占"), named: "pr7d-solo.png") ?? "pr7d-solo.png"
        let twin = IconImageStore.shared.store(swatch("共用"), named: "pr7d-twin.png") ?? "pr7d-twin.png"

        func make(_ name: String, _ icon: String?) -> Subscription? {
            var draft = SubscriptionDraft(name: name, priceMinorUnits: 4500, currencyCode: "CNY")
            draft.iconImageFile = icon
            return try? repository.apply(draft)
        }
        guard let due = make("PR7d 到期独占图标", solo),
              let later = make("PR7d 还剩二十天", nil),
              let shared = make("PR7d 到期共用图标", twin),
              let keeper = make("PR7d 还在用这张图", twin) else {
            Self.probeLogger.log("回收站探针 种数据这一步就失败了，后面没有任何判定")
            return
        }

        // 三条进回收站：走真实的软删除（它写 `deletedAt`），一次批量、一次落盘。
        _ = try? repository.moveToTrash([due, later, shared])
        due.deletedAt = stamp(-31)
        later.deletedAt = stamp(-10)
        try? repository.commit("探针：回拨两条删除时间")   // 这一句会广播「数据变了」

        let opening = "起点：库 \(allSubscriptions.count) 条 / 回收站 \(probeTrashCount()) 条，"
            + "到期那条在=\(probeHasRow("PR7d 到期独占图标")) "
            + "独占图标在盘上=\(IconImageStore.shared.exists(solo)) "
            + "共用图标在盘上=\(IconImageStore.shared.exists(twin))"
        Self.probeLogger.log("回收站探针 \(opening, privacy: .public)")

        let sweptByRoot = await probeWait("①根视图那一脚（落盘广播驱动）", timeout: 10) {
            self.probeHasRow("PR7d 到期独占图标") == false
        }
        let soloGone = await probeWait("①独占图标从盘上释放", timeout: 5) {
            IconImageStore.shared.exists(solo) == false
        }
        let act1 = "①判定：到期那条没了=\(sweptByRoot)，"
            + "还剩 20 天那条还在=\(self.probeHasRow("PR7d 还剩二十天"))，"
            + "独占图标从盘上没了=\(soloGone)，"
            + "屏上那句「\(self.writeFeedback.message?.text ?? "（没有弹条）")」"
        Self.probeLogger.log("回收站探针 \(act1, privacy: .public)")

        // ②第二条：回拨但不落盘 —— 没有广播，页面那一脚是唯一还可能动手的。
        shared.deletedAt = stamp(-40)
        let seededQuietly = "②起点：到期那条又出现了一条（没落盘、没广播），"
            + "共用图标在盘上=\(IconImageStore.shared.exists(twin))"
        Self.probeLogger.log("回收站探针 \(seededQuietly, privacy: .public)")

        goToSettings(.trash, haptic: false)
        try? await Task.sleep(for: .seconds(1.2))
        let sweptByPage = await probeWait("②回收站页那一脚（页面 .task）", timeout: 10) {
            self.probeHasRow("PR7d 到期共用图标") == false
        }
        let act2 = "②判定：页面那一脚把它收掉了=\(sweptByPage)，"
            + "共用图标还在盘上=\(IconImageStore.shared.exists(twin))（另一条活着的订阅在用），"
            + "回收站里剩 \(probeTrashCount()) 条"
        Self.probeLogger.log("回收站探针 \(act2, privacy: .public)")
        _ = await ProbeShutter.capture("trash-01-page-after-purge", settle: 1.0)

        // ③最后一个引用：先把「还在用这张图」那条摆到订阅列表上拍一张（图标就在行里），
        // 彻底删除之后再拍一张 —— 前后两帧拍的是这一屏，不是回收站页（回收站里没有它）。
        select(.subscriptions, haptic: false)
        try? await Task.sleep(for: .seconds(1.0))
        _ = await ProbeShutter.capture("trash-02-keeper-still-on-list", settle: 1.0)

        try? repository.deletePermanently([keeper])
        let keeperGone = await probeWait("③那条从订阅列表上消失", timeout: 5) {
            self.probeHasRow("PR7d 还在用这张图") == false
        }
        let twinGone = await probeWait("③共用图标从盘上释放", timeout: 5) {
            IconImageStore.shared.exists(twin) == false
        }
        let released = "③最后一个引用走掉之后：列表上那条没了=\(keeperGone)，"
            + "共用图标从盘上没了=\(twinGone)，"
            + "库 \(allSubscriptions.count) 条 / 回收站 \(probeTrashCount()) 条"
        Self.probeLogger.log("回收站探针 \(released, privacy: .public)")
        _ = await ProbeShutter.capture("trash-03-keeper-gone", settle: 0.8)
    }

    private func probeHasRow(_ name: String) -> Bool {
        allSubscriptions.contains { $0.name == name }
    }

    private func probeTrashCount() -> Int {
        allSubscriptions.filter { $0.deletedAt != nil }.count
    }

    /// 等到某个条件真的成立，不是「睡一下再当它成功了」。超时就把没等到说出来。
    private func probeWait(_ label: String, timeout: TimeInterval,
                           _ done: @escaping () -> Bool) async -> Bool {
        let began = Date()
        while done() == false {
            if Date().timeIntervalSince(began) > timeout {
                let late = "\(label)：\(Int(timeout)) 秒内没等到"
                Self.probeLogger.log("回收站探针 \(late, privacy: .public)")
                return false
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    /// 把草稿按扩展那一份线上格式写进队列。
    /// 故意不走 `ExternalInputStore.store`：那一来就变成「主 App 自己写的自己读」，
    /// 两个 target 之间的契约就没被碰过，而崩的恰恰是这一处。
    private func seedQueueTheWayTheExtensionDoes(_ payloads: [[String: Any]]) throws {
        let drafts: [[String: Any]] = payloads.enumerated().map { offset, payload in
            ["id": UUID().uuidString,
             "createdAt": Date().timeIntervalSinceReferenceDate - Double(offset),
             "source": "分享扩展",
             "payload": payload]
        }
        ExternalInputStore.storage.set(
            try JSONSerialization.data(withJSONObject: drafts), forKey: ExternalInputStore.key)
    }

    /// 表单此刻到底带进来了什么：名字、备注、图标，以及图标库和暂存目录两边的实际状态。
    private func formReadout(tag: String, expected: String) -> String {
        guard case .add(let prefill)? = sheets.route else {
            return "\(tag)：没弹出表单，屏幕上挂的是 \(String(describing: sheets.route))"
        }
        let icon = prefill.iconImageFile
        let stagedStillThere = icon.map {
            FileManager.default.fileExists(
                atPath: SharedImageIngest.stagedDirectory()?
                    .appendingPathComponent($0, isDirectory: false).path ?? "")
        } ?? false
        return "\(tag)：名字=«\(prefill.name)» 备注=\(prefill.note ?? "无")；"
            + "图标=\(icon ?? "无") 图标库里有=\(icon.map { IconImageStore.shared.exists($0) } ?? false) "
            + "暂存已清=\(stagedStillThere == false)；带进来的名字该是=\(expected)"
    }

    /// 导航保持探针（任务书 §6.3：Tab 切换保留导航状态、详情→编辑保留身份和返回来源）。
    ///
    /// 这台机器的命令行没有辅助功能权限，点不动菜单里「归档订阅」那一条和详情里那支笔，
    /// 所以这里直接调那两个入口走的同一句：往那一页自己的栈上 push、把详情页的编辑层打开。
    /// 不是另搭一条演示用的通路 —— 换 Tab、push、弹层用的都是真那套状态。
    private func runNavigationProbe() {
        let marks: [(Double, String, () -> Void)] = [
            (4.0, "切到订阅", { select(.subscriptions, haptic: false) }),
            (5.0, "push 归档订阅", { push(.subscriptions, SubscriptionsView.Route.archived) }),
            (6.5, "切去设置", { select(.settings, haptic: false) }),
            // 9.5 秒这一屏该还停在「归档订阅」：换过一轮 Tab 还没被销毁。
            (8.0, "切回订阅", { select(.subscriptions, haptic: false) }),
            (9.5, "切去总览", { select(.overview, haptic: false) }),
            // 总览那四块面板点下去走的就是这一句 `path.append`（以前它挂在一个没人绑的
            // 局部 @State 上，所以点上去什么都不会发生）。
            (10.5, "push 订阅日历", { push(.overview, OverviewView.Route.calendar) }),
            (12.5, "弹详情", {
                if let first = allSubscriptions.first { sheets.present(.detail(first.id)) }
            })
            // 14 秒这一屏该是「详情上面叠着编辑」：编辑是详情自己那一层，
            // 关掉它会回到详情，而不是回到列表。那两步的时间戳在详情页里。
        ]
        for (delay, label, action) in marks {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Self.probeLogger.log("导航探针 \(label, privacy: .public)")
                action()
            }
        }
    }

    private func push<T: Hashable>(_ tab: MainTab, _ route: T) {
        var path = paths[tab] ?? NavigationPath()
        path.append(route)
        paths[tab] = path
    }

    /// 「去找回数据」那一跳的探针。横幅本身在 PR2d 已经截过了，从来没验过的是**按下之后那一跳**
    /// （那一版命令行没有辅助功能权限，三个按钮一次都没点过）。这里调的就是按钮那一句，
    /// 判定只看设置页那条栈有没有真的多出一层，不等够几秒就当它成功了。
    private func runStoreJumpProbe() async {
        // 这一句等待只负责让首屏装好（窗口、三页都挂上），不参与任何判定。
        try? await Task.sleep(for: .seconds(4))
        let depthBefore = paths[.settings]?.count ?? 0
        let line1 = "按之前：当前页=\(selectedTab)，设置页栈 \(depthBefore) 层（这一屏能不能走到「iCloud 与数据」页）"
        Self.probeLogger.log("跳转探针 \(line1, privacy: .public)")
        openStoreRecoveryPage()
        var reached = false
        for _ in 0..<80 {
            if (self.paths[.settings]?.count ?? 0) >= 1 { reached = true; break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let depthAfter = paths[.settings]?.count ?? 0
        let line2 = "按之后：当前页=\(selectedTab)，设置页栈 \(depthAfter) 层，跳到数据页=\(reached)；"
            + "没跳到的话就是只换了个 Tab，数据页根本没打开"
        Self.probeLogger.log("跳转探针 \(line2, privacy: .public)")
        _ = await ProbeShutter.capture("jump-01-after-tap", settle: 1.2)
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
            (16.0, { sheets.present(.add(prefill: .empty)) }),
            (19.0, { sheets.close() }),
            (21.5, { select(.subscriptions, haptic: false) }),
            (24.0, {
                if let first = try? modelContext.fetch(FetchDescriptor<Subscription>()),
                   let item = first.first { sheets.present(.detail(item.id)) }
            })
        ]
        for (delay, action) in marks {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    }
    #endif

    private var isFormPresented: Bool { sheets.route?.isFormSheet == true }

    private func pathBinding(_ tab: MainTab) -> Binding<NavigationPath> {
        Binding(get: { paths[tab] ?? NavigationPath() },
                set: { paths[tab] = $0 })
    }

    /// 三页都留在树上。
    ///
    /// 以前用 `if selectedTab == …` 三选一：换 Tab 就是旧页被从视图里摘掉，
    /// 滚动位置、push 出去的归档页、搜索词、勾了哪几条，全跟着没了 ——
    /// 「切回来又从头开始」。现在三页一直都在，只是不在屏幕上的那两页被挪开、点不到。
    /// 滑出去的方向由页序自己决定，观感和以前那版 `directionalSlide` 一致。
    @ViewBuilder
    private var pages: some View {
        ZStack {
            tab(.overview) {
                NavigationStack(path: pathBinding(.overview)) {
                    OverviewView(path: pathBinding(.overview))
                }
            }
            tab(.subscriptions) {
                NavigationStack(path: pathBinding(.subscriptions)) {
                    SubscriptionsView(path: pathBinding(.subscriptions))
                }
            }
            tab(.settings) {
                NavigationStack(path: pathBinding(.settings)) {
                    settingsPage
                }
            }
        }
    }

    @ViewBuilder
    private func tab<Content: View>(_ target: MainTab,
                                   @ViewBuilder content: () -> Content) -> some View {
        let offset = CGFloat(target.index - selectedTab.index)
        content()
            .opacity(offset == 0 ? 1 : 0)
            .offset(x: offset * 64)
            .scaleEffect(offset == 0 ? 1 : 0.98)
            // 看不见的那两页不许接点击：否则用户在总览上点到的其实是身后那一页。
            .allowsHitTesting(offset == 0)
            // 数据变化照样要刷到隐藏页上（提醒队列、小组件读的是同一份库），
            // 所以这里只是把它挪出屏幕，没有把它停掉。
            .accessibilityHidden(offset != 0)
    }

    private var settingsPage: SettingsView { SettingsView() }

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
                sheets.present(.add(prefill: .empty))
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(isFormPresented ? 135 : 0))
                    .frame(width: 56, height: 56)
                    .background(
                        Circle().fill(
                            LinearGradient(
                                colors: [Color(hex: preferences.accentHex) ?? .blue, (Color(hex: preferences.accentHex) ?? .blue).opacity(0.75)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: (Color(hex: preferences.accentHex) ?? .blue).opacity(0.45), radius: isFormPresented ? 4 : 10, y: isFormPresented ? 2 : 5)
                    )
                    .animation(Motion.pop, value: isFormPresented)
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
        await rescheduleReminders(subscriptions: subscriptions)
        WidgetSnapshotStore.update(subscriptions: subscriptions, defaultCurrency: preferences.defaultCurrency)
        drainExternalInput()
        ToastCenter.shared.post = { message in toast = message }
        // 汇率每 24 小时自动同步一次（页脚承诺的那句话）。
        await ExchangeRateStore.shared.refreshIfStale()
        // 这里不再脚一脚踩同步：本地改动的触发归协调器自己的订阅管
        // （`startTriggers` 观察 `.sauryDataChanged`），挂两处会把同一趟跑两遍。
        purgeExpiredTrash()
    }

    /// 回收站满 30 天的那几条：真删，而且删完要说出来（任务书 §10.6）。
    ///
    /// 排在最后一步是有原因的。`allSubscriptions` 是 `@Query` 缓存，删完不会当场变短，
    /// 拿它去排提醒就会给一条已经不存在的订阅挂上通知。放在末尾，
    /// 本次删除落盘时广播的 `.sauryDataChanged` 会再跑一趟这一套，
    /// 那一趟读到的才是删干净之后的库，多余的那几条通知跟着被对账掉。
    /// 第二趟不再有任何到期项，所以不会自己追着自己循环。
    private func purgeExpiredTrash() {
        let report = TrashJanitor(repository: SubscriptionRepository(context: modelContext)).run()
        guard report.isQuiet == false, let message = report.feedback else { return }
        writeFeedback.show(message)
    }

    /// 把待处理提醒排成现在该挂的那几条。
    /// 不收 `defaultReminderDays`：那是新建表单的默认值，和「现在该响哪几条」无关。
    private func rescheduleReminders(subscriptions: [Subscription]? = nil) async {
        await SubscriptionScheduler.shared.refill(
            subscriptions: subscriptions ?? allSubscriptions,
            hour: preferences.reminderHour,
            enabled: preferences.notificationsEnabled
        )
    }

    /// 快捷指令 / 分享扩展递进来的条目：一条一条按顺序进添加页。
    ///
    /// 「哪一格填什么」全部收在 `ExternalIntake` 里（那层能单测）；这里只做三件事：
    /// 取一条、把图片搬进图标库、把结果或者失败摊到用户眼前。
    /// 图片以前是 `case .image: continue` —— 用户分享了一张图，App 一声不吭地扔了。
    private func drainExternalInput() {
        guard sheets.route == nil, !showingOnboarding else { return }
        while let draft = ExternalInputStore.consume() {
            do {
                sheets.present(.add(prefill: try ExternalIntake.prefill(for: draft)))
                return
            } catch {
                WriteFeedbackCenter.shared.report(error)
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
