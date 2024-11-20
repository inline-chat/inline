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

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAuthenticationChange(_:)),
      name: .authenticationChanged,
      object: nil
    )

    return true
  }

  @objc private func handleAuthenticationChange(_ notification: Notification) {
    if let authenticated = notification.object as? Bool, authenticated {
      requestPushNotifications()
    }
  }

  public func requestPushNotifications() {
    print("Requestedd")
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

  // This delegate method is called when the app is in foreground
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    // For iOS 14 and later
    completionHandler([.banner, .sound, .badge])
  }

  func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
//    let tokenParts = deviceToken.map { data in String(format: "%02.2hhx", data) }
//    let token = tokenParts.joined()
    let deviceToken = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()

    print("deviceToken \(deviceToken)")
    Task {
      try await ApiClient.shared.savePushNotification(
        pushToken: deviceToken
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
  @Published var authenticated: Bool = false

  public func setAuthenticated(value: Bool) {
    print("Setting authenticated to \(value)")
    DispatchQueue.main.async {
      self.authenticated = value
      NotificationCenter.default.post(name: .authenticationChanged, object: value)
    }
  }
}

extension Notification.Name {
  static let authenticationChanged = Notification.Name("authenticationChanged")
}
