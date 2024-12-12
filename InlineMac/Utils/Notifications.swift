import InlineKit
import SwiftUI
import UserNotifications

extension EnvironmentValues {
  @Entry var requestNotifications: () async -> Void = {}
}

class NotificationsManager: NSObject {
  var log = Log.scoped("Notifications")

  var center: UNUserNotificationCenter

  override init() {
    center = UNUserNotificationCenter.current()
    super.init()
  }

  // Call in app delegate
  func setup() {
    center.delegate = self
    log.debug("Notifications manager setup completed.")
  }

  var onNotificationReceivedAction: ((_ response: UNNotificationResponse) -> Void)?

  func onNotificationReceived(action: @escaping (_ response: UNNotificationResponse) -> Void) {
    if onNotificationReceivedAction != nil {
      log.error("onNotificationReceived action already attached. It must only be called once.")
    }
    log.trace("Attached onNotificationReceived action")
    onNotificationReceivedAction = action
  }
}

// Delegate
extension NotificationsManager: UNUserNotificationCenterDelegate {
  func userNotificationCenter(
    _: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler:
    @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    log.debug("willPresent called for \(notification)")

    // Don't alert the user for other types.
    completionHandler([])
  }

  func userNotificationCenter(
    _: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    log.debug("Received notification: \(response.notification.request.content.userInfo)")
    self.onNotificationReceivedAction.map { $0(response) }
    completionHandler() // Is this correct?
  }
}

// Functions
extension NotificationsManager {
  func requestNotifications() async {
    do {
      let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])

      log.debug("Requested notifications permissions")

      if granted {
        await registerForRemoteNotifications()
      }
    } catch {
      // Handle the error here.
      log.error("Failed to request notifications permissions", error: error)
    }
  }

//  func getNotificationSettings() async {
//    let settings = await center.notificationSettings()
//
//    guard settings.authorizationStatus == .authorized else {
//      log.debug("Notifications are not authorized")
//      return
//    }
//
//    log.debug("Notifications are authorized")
//
//    return settings
//  }

  func registerForRemoteNotifications() async {
    DispatchQueue.main.async {
      #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
      #elseif os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
      #endif
      self.log.debug("registerForRemoteNotifications called")
    }
  }

  func didRegisterForRemoteNotifications(deviceToken: Data) {
    log.debug("Registered for remote notifications: \(deviceToken)")

    let deviceToken = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()

    Task {
      let _ = try await ApiClient.shared.savePushNotification(
        pushToken: deviceToken
      )

      log.debug("Saved push notification token")
    }
  }
}
