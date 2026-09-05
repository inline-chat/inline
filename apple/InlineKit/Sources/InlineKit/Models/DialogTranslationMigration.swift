import Auth
import Foundation
import GRDB
import Logger
import RealtimeV2

/// Imports enabled choices preserved by the local database migration. The
/// server merges these without ever overriding an explicit synced disable.
enum DialogTranslationMigration {
  static func importPending(realtime: RealtimeV2) async {
    let auth = Auth.shared.handle
    guard AppDatabase.shared.isPersistent,
          let account = try? auth.beginAccountMutation() else { return }
    do {
      let peers = try await AppDatabase.shared.reader.read { db in
        try pendingPeers(db)
      }
      for peer in peers {
        try Task.checkCancellation()
        try auth.validateAccountMutation(account)
        // Re-read the marker: a full sync or an explicit choice may already
        // have resolved it while the preceding peer was being imported.
        let pending = try await AppDatabase.shared.reader.read { db in
          try Bool.fetchOne(
            db,
            sql: "SELECT translationLegacyImportPending FROM dialog WHERE id = ?",
            arguments: [Dialog.getDialogId(peerId: peer)]
          ) == true
        }
        guard pending else { continue }
        do {
          _ = try await realtime.send(
            UpdateDialogTranslationTransaction(
              peer: peer, enabled: true, intent: UUID(), importLegacyEnabled: true
            ),
            expectedAccount: account
          )
        } catch {
          try Task.checkCancellation()
          // Keep the durable marker for reconnect/relaunch. No failure path
          // sends false or erases the device's preserved translation choice.
          try auth.validateAccountMutation(account)
          Log.shared.error("Failed to import a legacy translation preference", error: error)
        }
      }
    } catch {
      if error is CancellationError { return }
      Log.shared.error("Legacy translation import interrupted", error: error)
    }
  }

  static func pendingPeers(_ db: Database) throws -> [Peer] {
    try Row.fetchAll(
      db,
      sql: "SELECT peerUserId, peerThreadId FROM dialog WHERE translationLegacyImportPending = 1 ORDER BY id"
    ).compactMap { row in
      if let userID = row["peerUserId"] as Int64? { return .user(id: userID) }
      if let threadID = row["peerThreadId"] as Int64? { return .thread(id: threadID) }
      return nil
    }
  }
}
