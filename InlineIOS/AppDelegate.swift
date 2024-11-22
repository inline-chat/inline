import Foundation
import InlineKit
import Sentry
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  let notificationHandler = NotificationHandler()
  let nav = Navigation()
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
    registerForPushNotifications()
  }

  func registerForPushNotifications() {
    let notificationCenter = UNUserNotificationCenter.current()
    notificationCenter.delegate = self
    notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in

      guard granted else { return }
      self.getNotificationSettings()
    }
  }

  func getNotificationSettings() {
    UNUserNotificationCenter.current().getNotificationSettings { settings in

      guard settings.authorizationStatus == .authorized else { return }
      DispatchQueue.main.async {
        UIApplication.shared.registerForRemoteNotifications()
      }
    }
  }

  #if DEBUG
    // This delegate method is called when the app is in foreground
    func userNotificationCenter(
      _ center: UNUserNotificationCenter,
      willPresent notification: UNNotification,
      withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
      // For iOS 14 and later
      completionHandler([.banner, .sound, .badge])
    }
  #endif

  func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let deviceToken = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()

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

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo

    if let userId = userInfo["userId"] as? Int {
      // Add a small delay to ensure app is ready
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        print("Pushing to chat \(userId)")

        // Check if chat is already open
        let peerId = Peer.user(id: Int64(userId))
        let chatDestination = Navigation.Destination.chat(peer: peerId)

        // Only push if it's not the current destination
        if self.nav.activeDestination != chatDestination {
          self.nav.push(chatDestination)
        }

        completionHandler()
      }
    }
  }
}

public class NotificationHandler: ObservableObject {
  @Published var authenticated: Bool = false

  public func setAuthenticated(value: Bool) {
    DispatchQueue.main.async {
      self.authenticated = value
      NotificationCenter.default.post(name: .authenticationChanged, object: value)
    }
  }
}

extension Notification.Name {
  static let authenticationChanged = Notification.Name("authenticationChanged")
}
