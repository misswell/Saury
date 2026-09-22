import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
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
        // 按钮标识里带着动作本身（方案 §39），所以通知上的按钮和 App 里的
        // 动作永远是同一套定义，不需要在这里再抄一份对照表。
        guard let action = ReminderCategory.action(for: response.actionIdentifier) else {
            completionHandler()
            return
        }

        guard let itemIDString = response.notification.request.content.userInfo[ReminderCategory.itemIDKey] as? String,
              let itemID = UUID(uuidString: itemIDString) else {
            completionHandler()
            return
        }
        NotificationActionHandler.store(NotificationActionPayload(itemID: itemID, action: action))
        completionHandler()
    }
}
