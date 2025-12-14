import Foundation
@preconcurrency import UserNotifications

enum NotificationCleanup {
  static func removeNotifications(
    threadId: String,
    upToMessageId: Int64?
  ) {
    let threadId = threadId
    let upToMessageId = upToMessageId

    let shouldRemove: @Sendable (UNNotificationContent) -> Bool = { content in
      if content.threadIdentifier != threadId {
        let payloadThreadId = content.userInfo["threadId"] as? String
        if payloadThreadId != threadId { return false }
      }

      guard let upToMessageId else { return true }

      let messageId: Int64? = if let raw = content.userInfo["messageId"] as? String {
        Int64(raw)
      } else if let raw = content.userInfo["messageId"] as? Int64 {
        raw
      } else if let raw = content.userInfo["messageId"] as? Int {
        Int64(raw)
      } else if let raw = content.userInfo["messageId"] as? NSNumber {
        raw.int64Value
      } else {
        nil
      }

      guard let messageId else { return false }
      return messageId <= upToMessageId
    }

    UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
      let deliveredIds = delivered.compactMap { deliveredNotification -> String? in
        shouldRemove(deliveredNotification.request.content) ? deliveredNotification.request.identifier : nil
      }

      UNUserNotificationCenter.current().getPendingNotificationRequests { pending in
        let pendingIds = pending.compactMap { request -> String? in
          shouldRemove(request.content) ? request.identifier : nil
        }

        let center = UNUserNotificationCenter.current()
        if !deliveredIds.isEmpty {
          center.removeDeliveredNotifications(withIdentifiers: deliveredIds)
        }
        if !pendingIds.isEmpty {
          center.removePendingNotificationRequests(withIdentifiers: pendingIds)
        }
      }
    }
  }
}
