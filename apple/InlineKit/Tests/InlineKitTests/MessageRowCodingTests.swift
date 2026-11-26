import Foundation
import GRDB
@testable import InlineKit
import InlineProtocol
import Testing

/// `Message` decodes and encodes rows by hand (see `Message.init(row:)`). These pin that code to the
/// Codable keys and the table, so a new column can't be skipped silently.
@Suite("Message row coding")
struct MessageRowCodingTests {
  @Test("encodes exactly the message table's columns, the same set as its coding keys")
  func columnsMatchTableAndCodingKeys() throws {
    let database = AppDatabase.empty()
    var message = Self.fullyPopulated()
    message.peerUserId = 5 // storage allows both; set every column
    let encoded = try Set(message.databaseDictionary.keys)
    let tableColumns = try database.dbWriter.read { db in
      try Set(db.columns(in: "message").map(\.name))
    }
    #expect(encoded == tableColumns)

    // Every property is set, so the synthesized Codable encoding names every coding key.
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any] ?? [:]
    #expect(Set(json.keys) == encoded, "only JSON: \(Set(json.keys).subtracting(encoded)), only rows: \(encoded.subtracting(json.keys))")
  }

  @Test("a row written and read back equals the original, with every column set and with every optional nil")
  func roundTrip() throws {
    let database = AppDatabase.empty()
    let full = Self.fullyPopulated()
    var sparse = InlineKit.Message(
      messageId: 2, fromId: 0, date: Date(timeIntervalSince1970: 1_790_000_000), text: nil,
      peerUserId: nil, peerThreadId: 77, chatId: 77
    )
    sparse.resourceFlags = 0
    let (readFull, readSparse, rawFromID) = try database.dbWriter.writeWithoutTransaction { db in
      // The fixture points at photo, file and user rows that don't exist.
      try db.execute(sql: "PRAGMA foreign_keys = OFF")
      defer { try? db.execute(sql: "PRAGMA foreign_keys = ON") }
      try Chat(id: 77, date: Date(), type: .thread, title: "t", spaceId: nil).insert(db)
      var a = full, b = sparse
      try a.insert(db)
      try b.insert(db)
      let rawFromID = try Int64?.fetchOne(db, sql: "SELECT fromId FROM message WHERE messageId = 2")
      return (
        try InlineKit.Message.fetchOne(db, sql: "SELECT * FROM message WHERE messageId = 1"),
        try InlineKit.Message.fetchOne(db, sql: "SELECT * FROM message WHERE messageId = 2"),
        rawFromID
      )
    }
    var expectedFull = full
    expectedFull.globalId = readFull?.globalId
    #expect(readFull == expectedFull)
    #expect(readSparse?.text == nil && readSparse?.status == nil && readSparse?.entities == nil)
    #expect(readSparse?.fromId == 0)
    // fromId 0 is stored as 0, not NULL: the stored optional mirrors the Codable path.
    #expect(rawFromID == 0)
  }

  @Test("the fixture sets every stored property away from its default, so the round trip checks each decode")
  func fixtureSetsEveryProperty() {
    var populated = Self.fullyPopulated()
    populated.peerUserId = 5
    let bare = InlineKit.Message(
      messageId: 0, fromId: 0, date: Date(timeIntervalSince1970: 0), text: nil,
      peerUserId: nil, peerThreadId: 1, chatId: 0
    )
    let defaults = Dictionary(
      Mirror(reflecting: bare).children.compactMap { child in child.label.map { ($0, String(describing: child.value)) } },
      uniquingKeysWith: { first, _ in first }
    )
    for child in Mirror(reflecting: populated).children {
      guard let label = child.label else { continue }
      #expect(String(describing: child.value) != defaults[label], "fullyPopulated leaves \(label) at its default")
    }
  }

  // Rows read straight from a statement convert like SQLite does (text in an integer column reads as 0),
  // before and after hand-written coding. A copied row keeps the stored value, and then decoding throws.
  @Test("a copied row with a value that doesn't convert throws instead of decoding as nil")
  func conversionFailureThrows() throws {
    let database = AppDatabase.empty()
    try database.dbWriter.read { db in
      let row = try #require(try Row.fetchOne(db, sql: """
        SELECT 1 AS globalId, NULL AS randomId, 'not a number' AS messageId, '2026-01-01 00:00:00.000' AS date,
          NULL AS text, 1 AS peerUserId, NULL AS peerThreadId, 1 AS chatId, 1 AS fromId, NULL AS mentioned,
          NULL AS out, NULL AS pinned, NULL AS editDate, 0 AS rev, NULL AS fileId, NULL AS status,
          NULL AS repliedToMessageId, NULL AS forwardFromPeerUserId, NULL AS forwardFromPeerThreadId,
          NULL AS forwardFromMessageId, NULL AS forwardFromUserId, NULL AS photoId, NULL AS videoId,
          NULL AS documentId, NULL AS contentPayload, NULL AS blockContentPayload, NULL AS transactionId,
          NULL AS isSticker, NULL AS hasLink, NULL AS entities, 0 AS resourceFlags, NULL AS groupedId
        """))
      #expect(throws: (any Error).self) { try InlineKit.Message(row: row) }
    }
  }

  private static func fullyPopulated() -> InlineKit.Message {
    var message = InlineKit.Message(
      messageId: 1, fromId: 5, date: Date(timeIntervalSince1970: 1_790_000_000), text: "see https://inline.chat",
      peerUserId: nil, peerThreadId: 77, chatId: 77, out: true
    )
    message.globalId = 100
    message.randomId = 42
    message.mentioned = true
    message.pinned = false
    message.editDate = Date(timeIntervalSince1970: 1_790_000_100)
    message.rev = 3
    message.fileId = "file"
    message.status = .sent
    message.repliedToMessageId = 9
    message.forwardFromPeerUserId = 6
    message.forwardFromPeerThreadId = 78
    message.forwardFromMessageId = 4
    message.forwardFromUserId = 6
    message.photoId = 11
    message.videoId = 12
    message.documentId = 13
    message.actions = .with { $0.rows = [.with { $0.actions = [.with { $0.actionID = "a"; $0.text = "Tap" }] }] }
    message.entities = .with { $0.entities = [.with { $0.type = .url; $0.offset = 4; $0.length = 19 }] }
    message.blockContentPayload = BlockContentPayload(.with {
      $0.blocks = [.with { $0.paragraph = .with { $0.offset = 0; $0.length = 3 } }]
    })
    message.transactionId = "tx"
    message.isSticker = false
    message.hasLink = true
    message.resourceFlags = 1
    message.groupedId = 8
    return message
  }
}
