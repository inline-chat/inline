import Foundation
import GRDB
import Logger

#if os(iOS)
import UIKit
#else
import AppKit
#endif

public final class UnreadManager: Sendable {
  public static let shared = UnreadManager()

  private let log = Log.scoped("UnreadManager", enableTracing: false)

  private init() {}

  private let apiClient = ApiClient.shared
  private let db = AppDatabase.shared

  private func sendReadMessagesToServer(peerId: Peer, maxId: Int64?) async {
    do {
      _ = try await Api.realtime.send(.readMessages(peerId: peerId, maxId: maxId))
    } catch {
      log.error("Realtime readMessages failed, falling back to HTTP route", error: error)
      do {
        _ = try await apiClient.readMessages(peerId: peerId, maxId: maxId)
      } catch {
        log.error("Failed to update remote server", error: error)
      }
    }
  }

  // This is called when chat opens initially
  public func readMessages(_ maxId: Int64, in peerId: Peer, chatId: Int64) {
    log.debug("readMessages")
    // TODO: update local DB with locally computed new unread count
    // let's just zero it, until later when we need to calculate exactly how many messages are unread still locally and
    // avoid applying old remote unread count, etc.

    // update server
    // TODO: add throttle
    Task {
      await sendReadMessagesToServer(peerId: peerId, maxId: maxId)
    }

#if os(iOS)
    NotificationCleanup.removeNotifications(threadId: "chat_\(chatId)", upToMessageId: maxId)
#endif
  }

  // Useful in context menu to mark all messages as read
  public func readAll(_ peerId: Peer, chatId: Int64) {
    log.debug("readAll")

    // update local DB
    do {
      try db.dbWriter.write { db in
        let localDialogId = Dialog.getDialogId(peerId: peerId)
        try Dialog
          .filter(id: localDialogId)
          .updateAll(db, [
            Column("unreadCount").set(to: 0),
            Column("unreadMark").set(to: false)
          ])
      }
    } catch {
      log.error("Failed to update local DB with unread count", error: error)
    }

    // Update remote server
    Task {
      await sendReadMessagesToServer(peerId: peerId, maxId: nil)
    }

#if os(iOS)
    NotificationCleanup.removeNotifications(threadId: "chat_\(chatId)", upToMessageId: nil)
#endif
  }
}
