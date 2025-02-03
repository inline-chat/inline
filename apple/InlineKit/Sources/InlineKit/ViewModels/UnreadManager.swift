import Foundation
import GRDB

public final class UnreadManager: Sendable {
  public static let shared = UnreadManager()

  private let log = Log.scoped("UnreadManager", enableTracing: false)

  private init() {}

  private let apiClient = ApiClient.shared
  private let db = AppDatabase.shared

  // This is called when chat opens initially
  public func readMessages(_ maxId: Int64, in peerId: Peer, chatId: Int64) {
    log.debug("readMessages")
    // TODO: update local DB with locally computed new unread count
    // let's just zero it, until later when we need to calculate exactly how many messages are unread still locally and
    // avoid applying old remote unread count, etc.

    // update server
    // todo: add throttle
    Task {
      try? await apiClient.readMessages(peerId: peerId, maxId: maxId)
    }
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
          .updateAll(db, [Column("unreadCount").set(to: 0)])
      }
    } catch {
      log.error("Failed to update local DB with unread count: \(error)")
    }

    // Update remote server
    Task {
      try? await apiClient.readMessages(peerId: peerId, maxId: nil)
    }
  }
}
