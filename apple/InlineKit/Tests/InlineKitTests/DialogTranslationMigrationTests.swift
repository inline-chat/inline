import Combine
import Foundation
import GRDB
@testable import InlineKit
import InlineProtocol
import RealtimeV2
import Testing

@Suite("Dialog translation rollout")
struct DialogTranslationMigrationTests {
  private func upgradedDatabase() throws -> AppDatabase {
    let template = try AppDatabase(DatabaseQueue())
    var migrator = template.migrator
    migrator.eraseDatabaseOnSchemaChange = false
    let queue = try DatabaseQueue()
    try migrator.migrate(queue, upTo: "dialogTranslationEnabled")
    try queue.write { db in
      try InlineKit.User(id: 8_001, email: "enabled@example.com", firstName: "Enabled").insert(db)
      try InlineKit.User(id: 8_002, email: "disabled@example.com", firstName: "Disabled").insert(db)
      try InlineKit.User(id: 8_003, email: "unset@example.com", firstName: "Unset").insert(db)
      try db.execute(sql: """
      INSERT INTO dialog (id, peerUserId, translationEnabled) VALUES (8001, 8001, 1);
      INSERT INTO dialog (id, peerUserId, translationEnabled) VALUES (8002, 8002, 0);
      INSERT INTO dialog (id, peerUserId, translationEnabled) VALUES (8003, 8003, NULL);
      INSERT INTO chat (id, date) VALUES (9001, '2026-09-05 00:00:00');
      INSERT INTO message (messageId, chatId, date, text) VALUES (1, 9001, '2026-09-05 00:00:00', 'Original');
      INSERT INTO translation (messageId, chatId, date, language, translation)
        VALUES (1, 9001, '2026-09-05 00:00:00', 'en', 'Preserved translation');
      """)
    }
    try migrator.migrate(queue)
    return try AppDatabase(queue)
  }

  @Test("Upgrade preserves enabled and disabled choices and imports only enabled peers")
  func enabledWinsMigration() throws {
    let database = try upgradedDatabase()
    #expect(database.translationPreferences.isEnabled(for: .user(id: 8_001)))
    #expect(!database.translationPreferences.isEnabled(for: .user(id: 8_002)))
    #expect(!database.translationPreferences.isEnabled(for: .user(id: 8_003)))
    let pending = try database.reader.read { db in try DialogTranslationMigration.pendingPeers(db) }
    #expect(pending == [.user(id: 8_001)])
    #expect(try database.reader.read { db in
      try String.fetchOne(db, sql: "SELECT translation FROM translation WHERE chatId = 9001 AND messageId = 1")
    } == "Preserved translation")
    let restarted = try AppDatabase(database.dbWriter)
    #expect(restarted.translationPreferences.isEnabled(for: .user(id: 8_001)))
    #expect(try restarted.reader.read { db in try DialogTranslationMigration.pendingPeers(db) } == pending)
  }

  @Test("An older server snapshot cannot erase an enabled choice or its retry marker")
  func oldServerSnapshot() throws {
    let database = try upgradedDatabase()
    try database.dbWriter.write { db in
      let snapshot = InlineProtocol.Dialog.with { $0.peer.user.userID = 8_001 }
      _ = try snapshot.saveFull(db)
    }
    #expect(database.translationPreferences.isEnabled(for: .user(id: 8_001)))
    #expect(try database.reader.read { db in try DialogTranslationMigration.pendingPeers(db) } == [.user(id: 8_001)])
  }

  @Test("Authoritative on and explicit off resolve the import without changing other dialogs", arguments: [true, false])
  func authoritativeSnapshot(enabled: Bool) throws {
    let database = try upgradedDatabase()
    try database.dbWriter.write { db in
      let snapshot = InlineProtocol.Dialog.with {
        $0.peer.user.userID = 8_001
        $0.translationEnabled = enabled
      }
      _ = try snapshot.saveFull(db)
    }
    #expect(database.translationPreferences.isEnabled(for: .user(id: 8_001)) == enabled)
    #expect(!database.translationPreferences.isEnabled(for: .user(id: 8_002)))
    #expect(try database.reader.read { db in try DialogTranslationMigration.pendingPeers(db) }.isEmpty)
  }

  @Test("An imported realtime update resolves the pending marker")
  func authoritativeUpdate() throws {
    let database = try upgradedDatabase()
    try database.dbWriter.write { db in
      try InlineProtocol.UpdateDialogTranslation.with {
        $0.peerID.user.userID = 8_001
        $0.enabled = true
      }.apply(db)
    }
    #expect(database.translationPreferences.isEnabled(for: .user(id: 8_001)))
    #expect(try database.reader.read { db in try DialogTranslationMigration.pendingPeers(db) }.isEmpty)
  }

  @Test("Legacy imports and deliberate choices share a lane but retain distinct wire semantics")
  func importWireContract() throws {
    let imported = UpdateDialogTranslationTransaction(
      peer: .user(id: 8_001), enabled: true, intent: UUID(), importLegacyEnabled: true
    )
    let explicit = UpdateDialogTranslationTransaction(peer: .user(id: 8_001), enabled: false, intent: UUID())
    #expect(imported.executionKey == explicit.executionKey)
    guard case let .updateDialogTranslation(input) = imported.input(from: imported.context) else {
      Issue.record("Missing import input")
      return
    }
    let decoded = try InlineProtocol.UpdateDialogTranslationInput(serializedBytes: input.serializedData())
    #expect(decoded.hasEnabled && decoded.enabled && decoded.importLegacyEnabled)
    let restored = try JSONDecoder().decode(
      UpdateDialogTranslationTransaction.self,
      from: JSONEncoder().encode(imported)
    )
    #expect(restored.context.importLegacyEnabled == true)
  }

  @Test("An unsupported server preserves an enabled choice without flashing off, including after relaunch")
  func unsupportedServerKeepsLocalChoice() throws {
    let database = try upgradedDatabase()
    let preferences = database.translationPreferences
    let peer = InlineKit.Peer.user(id: 8_002)
    let transaction = UpdateDialogTranslationTransaction(peer: peer, enabled: true, intent: UUID())
    var values: [Bool] = []
    let observation = preferences.changes.sink { changedPeer, enabled in
      if changedPeer == peer { values.append(enabled) }
    }
    defer { observation.cancel() }
    preferences.begin(true, for: peer, intent: transaction.context.intent)
    let saved = try database.dbWriter.write { db in
      try UpdateDialogTranslationTransaction.preserveLocalChoice(transaction.context, preferences: preferences, in: db)
    }
    #expect(saved)
    #expect(preferences.finish(for: peer, intent: transaction.context.intent))
    #expect(!values.isEmpty && values.allSatisfy { $0 })
    let restarted = try AppDatabase(database.dbWriter)
    #expect(restarted.translationPreferences.isEnabled(for: peer))
    #expect(try restarted.reader.read { db in try DialogTranslationMigration.pendingPeers(db) }.contains(peer))
    #expect(try restarted.reader.read { db in
      try String.fetchOne(db, sql: "SELECT translation FROM translation WHERE chatId = 9001 AND messageId = 1")
    } == "Preserved translation")
  }

  @Test("An unsupported server's local disable is never imported as a shared disable")
  func unsupportedServerLocalDisable() throws {
    let database = try upgradedDatabase()
    let preferences = database.translationPreferences
    let peer = InlineKit.Peer.user(id: 8_001)
    let transaction = UpdateDialogTranslationTransaction(peer: peer, enabled: false, intent: UUID())
    preferences.begin(false, for: peer, intent: transaction.context.intent)
    #expect(try database.dbWriter.write { db in
      try UpdateDialogTranslationTransaction.preserveLocalChoice(transaction.context, preferences: preferences, in: db)
    })
    preferences.finish(for: peer, intent: transaction.context.intent)
    #expect(!preferences.isEnabled(for: peer))
    #expect(try database.reader.read { db in try DialogTranslationMigration.pendingPeers(db) }.isEmpty)
  }

  @Test("An old failure cannot overwrite a newer local choice or resurrect a deleted dialog")
  func unsupportedServerStaleFailure() throws {
    let database = try upgradedDatabase()
    let preferences = database.translationPreferences
    let peer = InlineKit.Peer.user(id: 8_002)
    let first = UpdateDialogTranslationTransaction(peer: peer, enabled: true, intent: UUID())
    preferences.begin(true, for: peer, intent: first.context.intent)
    let next = UUID()
    preferences.begin(false, for: peer, intent: next)
    #expect(try database.dbWriter.write { db in
      try !UpdateDialogTranslationTransaction.preserveLocalChoice(first.context, preferences: preferences, in: db)
    })
    #expect(!preferences.finish(for: peer, intent: first.context.intent))
    #expect(!preferences.isEnabled(for: peer))
    try database.dbWriter.write { db in
      try db.execute(sql: "DELETE FROM dialog WHERE id = 8002")
    }
    #expect(try database.dbWriter.write { db in
      try !UpdateDialogTranslationTransaction.preserveLocalChoice(first.context, preferences: preferences, in: db)
    })
  }

  @Test("Only an explicit unsupported translation method response enables local compatibility")
  func unsupportedServerErrorContract() {
    let unsupported = InlineProtocol.RpcError.with {
      $0.errorCode = .badRequest
      $0.code = 400
      $0.message = "Unsupported RPC method: 141"
    }
    #expect(UpdateDialogTranslationTransaction.isUnsupportedSync(.rpcError(unsupported)))
    var wrongMethod = unsupported
    wrongMethod.message = "Unsupported RPC method: 142"
    #expect(!UpdateDialogTranslationTransaction.isUnsupportedSync(.rpcError(wrongMethod)))
    var badRequest = unsupported
    badRequest.message = "Bad request"
    #expect(!UpdateDialogTranslationTransaction.isUnsupportedSync(.rpcError(badRequest)))
    var internalError = unsupported
    internalError.errorCode = .internalError
    internalError.code = 500
    #expect(!UpdateDialogTranslationTransaction.isUnsupportedSync(.rpcError(internalError)))
    #expect(!UpdateDialogTranslationTransaction.isUnsupportedSync(.timeout))
  }
}
