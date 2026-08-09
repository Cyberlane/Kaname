import SwiftUI
import KanamePrototypeUI
import UIKit
@preconcurrency import UserNotifications

final class KanameAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { application.registerForRemoteNotifications() }
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        NotificationCenter.default.post(name: Notification.Name("kanameAPNsToken"), object: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        NotificationCenter.default.post(name: Notification.Name("kanameRemoteWake"), object: nil)
        completionHandler(.newData)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        NotificationCenter.default.post(name: Notification.Name("kanameRemoteWake"), object: nil)
        return [.banner, .list, .sound]
    }
}

@main
struct KanameIPhonePrototypeApp: App {
    @UIApplicationDelegateAdaptor(KanameAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            IPhoneControlSurface()
                .preferredColorScheme(.dark)
        }
    }
}
