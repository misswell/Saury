import SwiftUI
import SwiftData

@main
struct SauryApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let container: ModelContainer
    @StateObject private var preferences = SubPreferences.shared
    @StateObject private var exchangeRates = ExchangeRateStore.shared
    /// 同步的唯一入口。它必须自己拿着容器：上一版是「恰好拿到 context 才合并」，
    /// 于是查了一圈云端就报「已同步」，本机一条都没动。
    @StateObject private var sync: SyncCoordinator

    init() {
        // 不在这里 fatalError：库出问题时，用户需要看见「数据去哪了」和找回入口，
        // 而不是被弹回桌面。原因由 makeContainerForLaunch 留下，首屏挂说明。
        // 先存进局部量再交给 StateObject：那个包装器收的是 autoclosure，
        // 直接读 `container` 会把还在初始化中的 self 捕获进去。
        let launched = PersistenceController.makeContainerForLaunch()
        container = launched
        // 老库里每一行的「要不要提醒」在这一步补算，必须排在同步和调度之前：
        // 补算没做完就把整片推上云，另一台设备刚改的开关会被盖掉；
        // 反过来先排通知，那一趟会按还没补的开关排出该静默的订阅。
        // 跑在内存兜底库上时不写哨兵 —— 那一趟下次启动还要再来一遍。
        if PersistenceController.lastOpenFailure == nil {
            ReminderIntentBackfill.runIfNeeded(container: launched)
        }
        _sync = StateObject(wrappedValue: SyncCoordinator.live(container: launched,
                                                               preferences: SubPreferences.shared))
        #if DEBUG
        // 验证用：走的是数据页「我看过了，不再提示」同一个方法。
        // 命令行没有辅助功能权限点不了按钮，留底记录又存在 App 自己的偏好里，
        // 外面清不掉 —— 造完现场得能收回去。
        if ProcessInfo.processInfo.arguments.contains("-saury-clear-store-note") {
            PersistenceController.acknowledgeRecovery()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(preferences)
                .environmentObject(exchangeRates)
                .environmentObject(sync)
                .environmentObject(WriteFeedbackCenter.shared)
        }
        .modelContainer(container)
    }
}
