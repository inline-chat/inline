import Foundation
import GRDB
@testable import InlineKit
import InlineProtocol
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
}
