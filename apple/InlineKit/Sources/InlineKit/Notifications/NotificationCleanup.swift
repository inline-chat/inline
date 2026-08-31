import Auth
import Foundation
@preconcurrency import UserNotifications

enum NotificationCleanup {
  static func shouldRemove(
    content: UNNotificationContent,
    threadId: String,
    upToMessageId: Int64?,
    recipientUserID: Int64? = nil
  ) -> Bool {
    if let recipientUserID,
       !MessageNotificationAccount.matchesRecipient(
         userInfo: content.userInfo,
         currentUserID: recipientUserID
       ) {
      return false
    }

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

  static func removeNotifications(
    threadId: String,
    upToMessageId: Int64?,
    expectedAccount: AuthAccountMutationToken
  ) {
    guard MessageNotificationAccount.isCurrent(expectedAccount) else { return }
    let threadId = threadId
    let upToMessageId = upToMessageId
    let recipientUserID = expectedAccount.userID

    let shouldRemove: @Sendable (UNNotificationContent) -> Bool = { content in
      self.shouldRemove(
        content: content,
        threadId: threadId,
        upToMessageId: upToMessageId,
        recipientUserID: recipientUserID
      )
    }

    UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
      guard MessageNotificationAccount.isCurrent(expectedAccount) else { return }
      let deliveredIds = delivered.compactMap { deliveredNotification -> String? in
        shouldRemove(deliveredNotification.request.content) ? deliveredNotification.request.identifier : nil
      }

      UNUserNotificationCenter.current().getPendingNotificationRequests { pending in
        guard MessageNotificationAccount.isCurrent(expectedAccount) else { return }
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
