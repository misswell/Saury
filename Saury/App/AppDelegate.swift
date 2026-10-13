import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // 快捷入口必须**先登记**再排通知：排进去的时候系统里没有这个类别，
        // 那条通知就永远只有「点开」一种反应，用户看不到「稍后提醒」。
        ReminderActions.register(in: center)
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let intent = ReminderActions.intent(actionIdentifier: response.actionIdentifier,
                                           userInfo: response.notification.request.content.userInfo)
        // 这一脚是真的落了子（留痕 + 重排 / 记下要打开哪条），所以处理必须做完再回系统：
        // 后台起来那一趟随时可能被系统掐掉，扔进 Task 里等它跑就等于没做。
        MainActor.assumeIsolated {
            ReminderInteraction.handle(intent,
                                       preferences: .shared,
                                       scheduler: .shared,
                                       ledger: .shared,
                                       container: PersistenceController.liveContainer)
        }
        completionHandler()
    }
}
