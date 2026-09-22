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
        let action: DecisionAction
        switch response.actionIdentifier {
        case "qijian.action.cancel": action = .cancelled
        case "qijian.action.continue": action = .continued
        case "qijian.action.snooze": action = .snoozed
        default:
            completionHandler()
            return
        }

        guard let itemIDString = response.notification.request.content.userInfo["renewalItemID"] as? String,
              let itemID = UUID(uuidString: itemIDString) else {
            completionHandler()
            return
        }
        NotificationActionHandler.store(NotificationActionPayload(renewalItemID: itemID, action: action))
        completionHandler()
    }
}
