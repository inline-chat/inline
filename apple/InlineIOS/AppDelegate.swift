import Auth
import Foundation
import InlineConfig
import InlineKit
import Logger
import Sentry
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  let notificationHandler = NotificationHandler()
  let nav = Navigation()
  let router = NavigationModel<AppTab, Destination, Sheet>(initialTab: .chats)

  func application(
    _ application: UIApplication,
    willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    // Set up notification delegate here to not miss anything
    let notificationCenter = UNUserNotificationCenter.current()
    notificationCenter.delegate = self
    setupAppDataUpdater()
    return true
  }

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    Analytics.start()

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAuthenticationChange(_:)),
      name: .authenticationChanged,
      object: nil
    )

    // Send timezone to server
    Task {
      if Auth.shared.isLoggedIn {
        try? await DataManager.shared.updateTimezone()
      }
    }

    return true
  }

  private func applicationDidResignActive(_ notification: Notification) {
//    Task {
//      // Mark offline
//      try? await DataManager.shared.updateStatus(online: false)
//    }
  }

  private func applicationDidBecomeActive(_ notification: Notification) {
//    Task {
//      // Mark online
//      try? await DataManager.shared.updateStatus(online: true)
//    }
  }

  @objc private func handleAuthenticationChange(_ notification: Notification) {
    if let authenticated = notification.object as? Bool, authenticated {
      requestPushNotifications()
    }
  }

  func requestPushNotifications() {
    let notificationCenter = UNUserNotificationCenter.current()
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

  func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let deviceToken = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()

    Task.detached {
      _ = try await ApiClient.shared.savePushNotification(
        pushToken: deviceToken
      )
    }
  }

  func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    Log.shared.error("Failed to register for remote notifications", error: error)
  }

  func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    guard let kind = userInfo["kind"] as? String else {
      completionHandler(.noData)
      return
    }

    switch kind {
    case "message_deleted":
      guard
        let threadId = userInfo["threadId"] as? String,
        let messageIdSet = Self.coerceStringSet(userInfo["messageIds"]),
        !messageIdSet.isEmpty
      else {
        completionHandler(.noData)
        return
      }

      Self.removeNotificationRequests(threadId: threadId) { content in
        guard let deliveredMessageId = Self.coerceString(content.userInfo["messageId"]) else { return false }
        return messageIdSet.contains(deliveredMessageId)
      } didRemoveAny: { didRemoveAny in
        completionHandler(didRemoveAny ? .newData : .noData)
      }

    case "messages_read":
      guard
        let threadId = userInfo["threadId"] as? String,
        let readUpToRaw = Self.coerceString(userInfo["readUpToMessageId"]),
        let readUpToMessageId = Int64(readUpToRaw)
      else {
        completionHandler(.noData)
        return
      }

      Self.removeNotificationRequests(threadId: threadId) { content in
        guard
          let deliveredMessageIdRaw = Self.coerceString(content.userInfo["messageId"]),
          let deliveredMessageId = Int64(deliveredMessageIdRaw)
        else {
          return false
        }
        return deliveredMessageId <= readUpToMessageId
      } didRemoveAny: { didRemoveAny in
        completionHandler(didRemoveAny ? .newData : .noData)
      }

    default:
      completionHandler(.noData)
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    defer {
      completionHandler()
    }

    let userInfo = response.notification.request.content.userInfo
    let userId = userInfo["userId"] as? Int64
    let isThread = userInfo["isThread"] as? Bool
    let threadId = userInfo["threadId"] as? String
    let ogThreadId = threadId?.replacingOccurrences(of: "chat_", with: "")

    let peerId: Peer? = if isThread == true, let ogThreadId, let threadIdInt = Int64(ogThreadId) {
      Peer.thread(id: threadIdInt)
    } else if let userId {
      Peer.user(id: userId)
    } else {
      nil
    }

    guard let peerId else {
      return
    }

    // nav.navigateToChatFromNotification(peer: peerId)
    router.navigateFromNotification(peer: peerId)
  }
}

private extension AppDelegate {
  static func coerceString(_ value: Any?) -> String? {
    if let string = value as? String { return string }
    if let int = value as? Int { return String(int) }
    if let int64 = value as? Int64 { return String(int64) }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
  }

  static func coerceStringArray(_ value: Any?) -> [String] {
    if let array = value as? [Any] {
      return array.compactMap { coerceString($0) }
    }
    if let array = value as? NSArray {
      return array.compactMap { coerceString($0) }
    }
    return []
  }

  static func coerceStringSet(_ value: Any?) -> Set<String>? {
    let array = coerceStringArray(value)
    return array.isEmpty ? nil : Set(array)
  }

  static func removeNotificationRequests(
    threadId: String,
    shouldRemove: @escaping (UNNotificationContent) -> Bool,
    didRemoveAny: @escaping (Bool) -> Void
  ) {
    let center = UNUserNotificationCenter.current()

    func matchesThread(_ content: UNNotificationContent) -> Bool {
      if content.threadIdentifier == threadId { return true }
      if let payloadThreadId = content.userInfo["threadId"] as? String, payloadThreadId == threadId { return true }
      return false
    }

    center.getDeliveredNotifications { delivered in
      let deliveredIds = delivered.compactMap { deliveredNotification -> String? in
        let content = deliveredNotification.request.content
        guard matchesThread(content), shouldRemove(content) else { return nil }
        return deliveredNotification.request.identifier
      }

      center.getPendingNotificationRequests { pending in
        let pendingIds = pending.compactMap { request -> String? in
          let content = request.content
          guard matchesThread(content), shouldRemove(content) else { return nil }
          return request.identifier
        }

        if !deliveredIds.isEmpty {
          center.removeDeliveredNotifications(withIdentifiers: deliveredIds)
        }
        if !pendingIds.isEmpty {
          center.removePendingNotificationRequests(withIdentifiers: pendingIds)
        }

        didRemoveAny(!deliveredIds.isEmpty || !pendingIds.isEmpty)
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
