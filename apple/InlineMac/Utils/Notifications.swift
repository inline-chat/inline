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

  var onNotificationReceivedAction: (@MainActor (_ response: UNNotificationResponse) -> Void)?

  func onNotificationReceived(action: @escaping @MainActor (_ response: UNNotificationResponse) -> Void) {
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
    log.debug("Received foreground notification")

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

    guard let account = MessageNotificationAccount.capture(userInfo: notification.request.content.userInfo) else {
      completionHandler([])
      return
    }
    let urgentOptions = UrgentNotificationPresentation.foregroundOptions(for: notification.request.content)
    if !urgentOptions.isEmpty {
      completionHandler(urgentOptions)
      return
    }

    let content = notification.request.content
    let target = MessageNotificationTarget(userInfo: content.userInfo, threadIdentifier: content.threadIdentifier)
    Task { @MainActor in
      let peer = await target?.resolvePeer()
      guard MessageNotificationAccount.isCurrent(account) else {
        completionHandler([])
        return
      }
      let isViewingChat = peer.map { MainWindowOpenCoordinator.shared.isViewingChat($0) } ?? false
      completionHandler(MessageNotificationPresentation.foregroundOptions(
        for: content,
        isViewingConversation: isViewingChat
      ))
    }
  }

  func userNotificationCenter(
    _: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    log.debug("Received notification action")
    let action = onNotificationReceivedAction
    Task { @MainActor in
      action?(response)
      completionHandler()
    }
  }
}
