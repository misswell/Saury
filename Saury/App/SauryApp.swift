import SwiftUI
import SwiftData

@main
struct SauryApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: RenewalItem.self, DecisionRecord.self)
        } catch {
            fatalError("无法创建本地数据容器：\(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
