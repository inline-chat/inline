import Auth
import Foundation
import GRDB
import Logger
import RealtimeV2

/// Asks the server for the read state of dialogs whose unread count older builds raised for a
/// service message. The server never counts those, automatic reads never cover them and chat list
/// snapshots kept the local count, so the extra unread stayed until something else was read.
///
/// Like Telegram's read-state validation, the server's dialog replaces the local count (through
/// `getChat`, which applies it only at the local chat cursor); nothing is recounted locally.
/// Runs once per account; a failed peer leaves it for the next connection.
enum UnreadCountValidation {
  private static let doneKeyPrefix = "unreadServiceCountValidation.v1."

  static func validateServiceCounts(realtime: RealtimeV2) async {
    let auth = Auth.shared.handle
    guard AppDatabase.shared.isPersistent,
          let userID = Auth.getCurrentUserId(),
          let account = try? auth.beginAccountMutation() else { return }
    let doneKey = doneKeyPrefix + String(userID)
    guard !UserDefaults.standard.bool(forKey: doneKey) else { return }

    do {
      let peers = try await AppDatabase.shared.reader.read { db in try candidatePeers(db) }
      var failed = false
      for peer in peers {
        try Task.checkCancellation()
        try auth.validateAccountMutation(account)
        do {
          _ = try await realtime.send(.getChat(peer: peer), expectedAccount: account)
        } catch {
          try Task.checkCancellation()
          failed = true
          Log.shared.error("Failed to validate a dialog's unread count", error: error)
        }
      }
      try auth.validateAccountMutation(account)
      if !failed {
        UserDefaults.standard.set(true, forKey: doneKey)
      }
    } catch {
      if error is CancellationError { return }
      Log.shared.error("Unread count validation interrupted", error: error)
    }
  }

  /// Dialogs showing unread that hold an incoming service message after their read cursor.
  static func candidatePeers(_ db: Database) throws -> [Peer] {
    let dialogs = try Dialog
      .filter(sql: #"COALESCE("unreadCount", 0) > 0 AND "chatId" IS NOT NULL"#)
      .order(Dialog.Columns.id)
      .fetchAll(db)
    return try dialogs.compactMap { dialog in
      guard let chatId = dialog.chatId else { return nil }
      let hasServiceRow = try Message
        .filter(Message.Columns.chatId == chatId)
        .filter(Message.Columns.messageId > (dialog.readInboxMaxId ?? 0))
        .filter(Message.Columns.out == false)
        .filter(Message.Columns.contentPayload != nil)
        .fetchAll(db)
        .contains { $0.contentPayload?.hasServiceMessage == true }
      return hasServiceRow ? dialog.peerId : nil
    }
  }
}
