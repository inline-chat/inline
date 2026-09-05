import Combine
import Foundation
import GRDB
@testable import InlineKit
import InlineProtocol
import Testing

@Suite("Dialog translation sync")
struct DialogTranslationTests {
  private func database() throws -> DatabaseQueue {
    let db = try DatabaseQueue()
    try db.write { db in
      try db.execute(sql: """
      CREATE TABLE dialog (
        id INTEGER PRIMARY KEY, peerUserId INTEGER, peerThreadId INTEGER,
        translationEnabled BOOLEAN, unreadCount INTEGER DEFAULT 0
      );
      INSERT INTO dialog (id, peerThreadId, translationEnabled) VALUES (-1000, 1000, 1);
      INSERT INTO dialog (id, peerThreadId, translationEnabled) VALUES (20, 20, 0);
      INSERT INTO dialog (id, peerUserId, translationEnabled) VALUES (2000, 2000, 0);
      """)
    }
    return db
  }

  @Test("Persisted values are ready when database initialization returns")
  func initialSnapshot() throws {
    let db = try database()
    let preferences = DialogTranslationPreferences()
    try preferences.observe(db)
    #expect(preferences.isEnabled(for: .thread(id: 1_000)))
    #expect(!preferences.isEnabled(for: .user(id: 2_000)))
  }

  @Test("Remote commits update both values and peer-specific subscribers synchronously")
  func remoteChanges() throws {
    let db = try database()
    let preferences = DialogTranslationPreferences()
    try preferences.observe(db)
    var events: [(InlineKit.Peer, Bool)] = []
    let subscription = preferences.changes.sink { events.append($0) }
    defer { subscription.cancel() }
    try db.write { db in
      try db.execute(sql: "UPDATE dialog SET translationEnabled = 0 WHERE id = -1000")
      try db.execute(sql: "UPDATE dialog SET translationEnabled = 1 WHERE id = 20")
    }
    #expect(!preferences.isEnabled(for: .thread(id: 1_000)))
    #expect(preferences.isEnabled(for: .thread(id: 20)))
    #expect(events.contains { $0.0 == .thread(id: 20) && $0.1 })
    #expect(events.contains { $0.0 == .thread(id: 1_000) && !$0.1 })
    let count = events.count
    try db.write { db in try db.execute(sql: "UPDATE dialog SET unreadCount = 1 WHERE id = 20") }
    #expect(events.count == count)
  }

  @Test("Rolled-back writes never enter the render projection")
  func rollback() throws {
    let db = try database()
    let preferences = DialogTranslationPreferences()
    try preferences.observe(db)
    try db.inTransaction { db in
      try db.execute(sql: "UPDATE dialog SET translationEnabled = 0 WHERE id = -1000")
      return .rollback
    }
    #expect(preferences.isEnabled(for: .thread(id: 1_000)))
  }

  @Test("Earlier replies cannot replace a newer local toggle; failure restores committed state")
  func latestIntent() throws {
    let db = try database()
    let preferences = DialogTranslationPreferences()
    try preferences.observe(db)
    let peer = InlineKit.Peer.user(id: 2_000)
    let first = UUID()
    let second = UUID()
    preferences.begin(true, for: peer, intent: first)
    preferences.begin(false, for: peer, intent: second)
    try db.write { db in try db.execute(sql: "UPDATE dialog SET translationEnabled = 1 WHERE id = 2000") }
    preferences.finish(for: peer, intent: first)
    #expect(!preferences.isEnabled(for: peer))
    preferences.finish(for: peer, intent: second)
    #expect(preferences.isEnabled(for: peer))
  }

  @Test("Database replacement clears account state and pending choices")
  func accountBoundary() throws {
    let first = try database()
    let second = try database()
    try second.write { db in try db.execute(sql: "UPDATE dialog SET translationEnabled = 0") }
    let preferences = DialogTranslationPreferences()
    try preferences.observe(first)
    preferences.begin(true, for: .user(id: 2_000), intent: UUID())
    try preferences.observe(second)
    #expect(!preferences.isEnabled(for: .thread(id: 1_000)))
    #expect(!preferences.isEnabled(for: .user(id: 2_000)))
    try first.write { db in try db.execute(sql: "UPDATE dialog SET translationEnabled = 1 WHERE id = 2000") }
    #expect(!preferences.isEnabled(for: .user(id: 2_000)))
  }

  @Test("A failed database replacement cannot retain the previous account's choices")
  func failedAccountReplacement() throws {
    let db = try database()
    let preferences = DialogTranslationPreferences()
    try preferences.observe(db)
    let unavailableSchema = try DatabaseQueue()
    #expect(throws: (any Error).self) { try preferences.observe(unavailableSchema) }
    #expect(!preferences.isEnabled(for: .thread(id: 1_000)))
  }

  @Test("Disable retains wire presence and mutations serialize by peer")
  func transactionContract() throws {
    let transaction = UpdateDialogTranslationTransaction(peer: .user(id: 2_000), enabled: false, intent: UUID())
    guard case let .updateDialogTranslation(input) = transaction.input(from: transaction.context) else {
      Issue.record("Missing translation input")
      return
    }
    let decoded = try InlineProtocol.UpdateDialogTranslationInput(serializedBytes: input.serializedData())
    #expect(decoded.hasEnabled)
    #expect(!decoded.enabled)
    let next = UpdateDialogTranslationTransaction(peer: .user(id: 2_000), enabled: true, intent: UUID())
    let other = UpdateDialogTranslationTransaction(peer: .thread(id: 2_000), enabled: true, intent: UUID())
    #expect(transaction.executionKey == next.executionKey)
    #expect(transaction.executionKey != other.executionKey)
  }
}
