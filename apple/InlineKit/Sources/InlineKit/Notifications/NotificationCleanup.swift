import Auth
import Foundation
import GRDB
import InlineNotificationFence
@preconcurrency import UserNotifications

enum NotificationCleanup {
  static func shouldRemove(
    content: UNNotificationContent,
    threadId: String,
    upToMessageId: Int64?,
    recipientUserID: Int64? = nil
  ) -> Bool {
    if let recipientUserID, !NotificationSyncOps.belongs(content, to: recipientUserID) {
      return false
    }
    guard NotificationSyncOps.thread(of: content, is: threadId) else { return false }
    guard let upToMessageId else { return true }
    guard let messageId = NotificationSyncOps.messageID(content.userInfo["messageId"]) else { return false }
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

/// Removes notifications for messages read or deleted on the user's other devices once sync
/// applies that state locally. Like Telegram's ClearNotificationsManager, it batches for two
/// seconds and is flushed when the app leaves the foreground.
public actor NotificationSyncCleaner {
  public static let shared = NotificationSyncCleaner()
  static let batchInterval: Duration = .seconds(2)

  private var pending = NotificationSyncOps()
  private var account: AuthAccountMutationToken?
  private var timer: Task<Void, Never>?

  /// Call after the read or delete state is durably applied.
  public func enqueue(_ ops: NotificationSyncOps, account: AuthAccountMutationToken) {
    guard !ops.isEmpty else { return }
    if self.account != account {
      // Never apply one account's batch on behalf of another.
      pending = NotificationSyncOps()
      self.account = account
    }
    pending.merge(ops)
    timer?.cancel()
    timer = Task { [weak self] in
      do { try await Task.sleep(for: Self.batchInterval) } catch { return }
      await self?.flush()
    }
  }

  /// Applies the pending batch now and waits for the notification center lookups.
  public func flush() async {
    timer?.cancel()
    timer = nil
    guard let account, !pending.isEmpty else { return }
    let ops = pending
    pending = NotificationSyncOps()
    self.account = nil
    guard MessageNotificationAccount.isCurrent(account) else { return }
    await ops.removeCovered(recipientUserID: account.userID)
  }

  public static func isSyncPush(_ userInfo: [AnyHashable: Any]) -> Bool {
    NotificationSyncOps.isSyncPush(userInfo)
  }

  /// Applies a dedicated read/delete sync push the app received itself. Runs immediately: the
  /// app may be suspended again as soon as the push handler completes.
  public static func applySyncPush(_ userInfo: [AnyHashable: Any], account: AuthAccountMutationToken) async -> Bool {
    guard let ops = NotificationSyncOps(syncPushUserInfo: userInfo),
          MessageNotificationAccount.isCurrent(account)
    else { return false }
    return await ops.removeCovered(recipientUserID: account.userID) > 0
  }

  /// Enqueues from a database write; nothing is removed unless the transaction commits.
  nonisolated static func enqueueAfterCommit(_ db: Database, ops: NotificationSyncOps) {
    guard !ops.isEmpty else { return }
    db.afterNextTransaction { _ in
      guard let account = try? Auth.shared.handle.beginAccountMutation() else { return }
      Task { await NotificationSyncCleaner.shared.enqueue(ops, account: account) }
    }
  }
}
