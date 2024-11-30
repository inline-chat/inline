import AppKit
import InlineConfig
import InlineKit
import Sentry
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
  let notifications = NotificationsManager()

  func applicationWillFinishLaunching(_ notification: Notification) {
    // Disable native tabbing
    NSWindow.allowsAutomaticWindowTabbing = false

    // Setup Notifications Delegate
    notifications.setup()
    UNUserNotificationCenter.current().delegate = notifications
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

  func application(
    _ application: NSApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    print("Registered for remote notifications: \(deviceToken)")

    notifications.didRegisterForRemoteNotifications(deviceToken: deviceToken)
  }

  func application(
    _ application: NSApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    print("Failed to register for remote notifications \(error)")
  }
}
