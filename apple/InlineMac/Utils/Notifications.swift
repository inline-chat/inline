import InlineKit
import Logger
import UserNotifications

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

#if DEBUG || DEBUG_BUILD
    if notification.request.content.userInfo["playgroundNotification"] as? Bool == true {
      let playsSound = notification.request.content.userInfo["playgroundSoundEnabled"] as? Bool == true
      completionHandler(playsSound ? [.banner, .sound] : [.banner])
      return
    }
#endif

    if notification.request.content.userInfo["type"] as? String == "gridScreenShare" {
      completionHandler([.banner])
      return
    }

    let urgentOptions = UrgentNotificationPresentation.foregroundOptions(for: notification.request.content)
    if !urgentOptions.isEmpty {
      completionHandler(urgentOptions)
      return
    }

    // Don't alert the user for other types.
    completionHandler([])
  }

  func userNotificationCenter(
    _: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    log.debug("Received notification: \(response.notification.request.content.userInfo)")
    onNotificationReceivedAction.map { $0(response) }
    completionHandler() // Is this correct?
  }
}
