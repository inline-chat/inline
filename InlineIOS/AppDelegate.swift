import Foundation
import InlineKit
import Sentry
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  let notificationHandler = NotificationHandler()
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    SentrySDK.start { options in
      // usenoor/inline-ios
      options.dsn =
        "https://1bd867ae25150dd18dad6100789649fd@o124360.ingest.us.sentry.io/4508058293633024"
      options.debug = false
    }

    if notificationHandler.authenticated {
      requestPushNotifications()
    }
    return true
  }

  public func requestPushNotifications() {
    print("Requesteddd")
    registerForPushNotifications()
  }

  func registerForPushNotifications() {
    let notificationCenter = UNUserNotificationCenter.current()
    notificationCenter.delegate = self
    notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
      print("Permission granted: \(granted)")
      guard granted else { return }
      self.getNotificationSettings()
    }
  }

  func getNotificationSettings() {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      print("Notification settings: \(settings)")
      guard settings.authorizationStatus == .authorized else { return }
      DispatchQueue.main.async {
        UIApplication.shared.registerForRemoteNotifications()
      }
    }
  }

  func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let tokenParts = deviceToken.map { data in String(format: "%02.2hhx", data) }

    let token = tokenParts.joined()
    Task {
      try await ApiClient.shared.savePushNotification(
        pushToken: token
      )
    }

    UNUserNotificationCenter.current().delegate = self
  }

  func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {}

  // This method will be called when the user taps on the notification
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if let response = response.notification.request.content.userInfo["response"] as? String {
      print("Response: \(response)")
    }
  }
}

public class NotificationHandler: ObservableObject {
  var authenticated: Bool = false
  public func setAuthenticated(value: Bool) {
    print("Setting authenticated to \(value)")
    authenticated = value
  }
}
