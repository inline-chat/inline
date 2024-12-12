import AppKit
import InlineConfig
import InlineKit
import Sentry
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
  let notifications = NotificationsManager()
  let navigation: NavigationModel = .shared
  let log = Log.scoped("AppDelegate")

  func applicationWillFinishLaunching(_ notification: Notification) {
    // Disable native tabbing
    NSWindow.allowsAutomaticWindowTabbing = false

    // Setup Notifications Delegate
    setupNotifications()
  }

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    SentrySDK.start { options in
      options.dsn = InlineConfig.SentryDSN
      options.debug = false
      options.tracesSampleRate = 0.1
    }

    notifications.setup()
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

// MARK: - Notifications

extension AppDelegate {
  func setupNotifications() {
    notifications.setup()
    notifications.onNotificationReceived { response in
      self.handleNotification(response)
    }
    UNUserNotificationCenter.current().delegate = notifications
  }
  
  func application(
    _ application: NSApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    log.debug("Registered for remote notifications: \(deviceToken)")

    notifications.didRegisterForRemoteNotifications(deviceToken: deviceToken)
  }

  func application(
    _ application: NSApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    log.error("Failed to register for remote notifications \(error)")
  }

  func handleNotification(_ response: UNNotificationResponse) {
    log.debug("Received notification: \(response)")

    // TODO: Navigate
    guard let userInfo = response.notification.request.content.userInfo as? [String: Any] else {
      return
    }

    if let peerId = getPeerFromNotification(userInfo) {
      navigation.select(.chat(peer: peerId))
      // TODO: Handle spaceId
    }
  }

  func getPeerFromNotification(_ userInfo: [String: Any]) -> Peer? {
    if let peerUserId = userInfo["userId"] as? Int64 {
      return .user(id: peerUserId)
    } else {
      return nil
    }
  }
}
