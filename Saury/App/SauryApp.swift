import SwiftUI
import SwiftData

@main
struct SauryApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let container: ModelContainer
    @StateObject private var preferences = SubPreferences.shared
    @StateObject private var exchangeRates = ExchangeRateStore.shared
    @StateObject private var cloudSync = CloudSyncEngine.shared

    init() {
        do {
            container = try PersistenceController.makeContainerWithRecovery()
        } catch {
            fatalError("无法创建本地数据容器：\(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(preferences)
                .environmentObject(exchangeRates)
                .environmentObject(cloudSync)
        }
        .modelContainer(container)
    }
}
