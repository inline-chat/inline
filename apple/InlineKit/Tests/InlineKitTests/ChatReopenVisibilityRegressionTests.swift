import Foundation
import GRDB
import InlineProtocol
import Testing
@testable import InlineKit

@Suite("Chat reopen preserves adjacent materialized messages")
struct ChatReopenVisibilityRegressionTests {
  @Test("A new model preserves the live transcript after dispose and a canonical database preload",
        arguments: [false, true], [false, true])
  @MainActor
  func adjacentLiveTranscriptSurvivesReopen(reversed: Bool, pendingAfterTranscript: Bool) async throws {
    let fixture = try await ReopenFixture()
    var original: MessagesProgressiveViewModel? = try await fixture.model(reversed: reversed)
    for id in Int64(1) ... 7 {
      if [Int64(1), 3, 5].contains(id) {
        let pending = try await fixture.pending(messageID: -100 - id, randomID: 100 + id, dateID: id)
        fixture.publisher.publisher.send(.add(.init(messages: [pending], peer: .thread(id: 1))))
        let confirmed = try await fixture.confirm(randomID: 100 + id, messageID: id)
        #expect(confirmed.id == pending.id)
        #expect(confirmed.message.status == .sent)
        fixture.publisher.publisher.send(.update(.init(message: confirmed, animated: false, peer: .thread(id: 1))))
      } else {
        let incoming = try await fixture.incoming(messageID: id)
        fixture.publisher.publisher.send(.add(.init(messages: [incoming], peer: .thread(id: 1))))
      }
    }
    if pendingAfterTranscript {
      let pending = try await fixture.pending(messageID: -108, randomID: 108, dateID: 8)
      fixture.publisher.publisher.send(.add(.init(messages: [pending], peer: .thread(id: 1))))
    }
    let ascendingIDs = Array(Int64(1) ... 7) + (pendingAfterTranscript ? [-108] : [])
    let expectedIDs = reversed ? Array(ascendingIDs.reversed()) : ascendingIDs
    #expect(original?.messages.map(\.message.messageId) == expectedIDs)
    let originalGlobalIDs = original?.messages.map(\.id)
    original?.dispose()
    original = nil

    // Match ChatOpenPreloader's ordinary date-descending bounded query and
    // its real loadedWindowMetadata read. No prior model/retained-ID state or
    // history admission is carried into the freshly constructed model.
    let snapshot = try await fixture.snapshot()
    #expect(snapshot.messages.map(\.message.messageId) == ascendingIDs)
    #expect(Set(snapshot.messages.map(\.id)).count == snapshot.messages.count)
    let reopened = MessagesProgressiveViewModel(
      peer: .thread(id: 1), reversed: reversed, initialState: snapshot,
      database: fixture.database, publisher: fixture.publisher, currentUserId: 1
    )
    defer { reopened.dispose() }
    print("reopen diagnostic reversed=\(reversed) pending=\(pendingAfterTranscript) canonical=\(snapshot.messages.map(\.message.messageId)) rendered=\(reopened.messages.map(\.message.messageId))")
    #expect(reopened.messages.map(\.message.messageId) == expectedIDs)
    #expect(reopened.messages.map(\.id) == originalGlobalIDs)
    #expect(reopened.oldestLoadedMessageId == 1)
    #expect(reopened.newestLoadedMessageId == 7)
    for id in [Int64(1), 3, 5] {
      #expect(reopened.messages.first(where: { $0.message.messageId == id })?.message.status == .sent)
    }
    if pendingAfterTranscript {
      #expect(reopened.messages.first(where: { $0.message.messageId == -108 })?.message.status == .sending)
      #expect(reopened.messages.first(where: { $0.message.messageId == -108 })?.message.randomId == 108)
    }
    // Display adjacency must not establish history, resource, read or head
    // authority. All persisted unknown intervals stay byte-for-byte equal.
    #expect(!reopened.historyCoverage.isAtCertifiedLiveEnd)
    #expect(!reopened.historyCoverage.hasCertifiedOlderEdge)
    #expect(!reopened.historyCoverage.hasCertifiedNewerEdge)
    #expect(!reopened.historyCoverage.isCertifiedContinuation(between: 1, and: 2))
    #expect(!reopened.historyCoverage.isCertifiedMessage(1))
    #expect(reopened.historyCoverage.certifiedReadMaxID(after: 0, through: 7) == nil)
    try await fixture.expectUnknownCoverage()
  }

  @Test("Sparse cached coordinates do not become a continuous reopened transcript",
        arguments: [false, true])
  @MainActor
  func sparseCacheKeepsGapBoundary(reversed: Bool) async throws {
    let fixture = try await ReopenFixture()
    _ = try await fixture.incoming(messageID: 1)
    let tail = try await fixture.incoming(messageID: 100)
    let snapshot = try await fixture.snapshot()
    #expect(snapshot.messages.map(\.message.messageId) == [1, 100])
    let reopened = MessagesProgressiveViewModel(
      peer: .thread(id: 1), reversed: reversed, initialState: snapshot,
      database: fixture.database, publisher: fixture.publisher, currentUserId: 1
    )
    defer { reopened.dispose() }
    #expect(reopened.messages.map(\.message.messageId) == [100])
    #expect(reopened.messages.map(\.id) == [tail.id])
    #expect(!reopened.historyCoverage.isCertifiedContinuation(between: 1, and: 100))
    #expect(!reopened.historyCoverage.isAtCertifiedLiveEnd)
    #expect(reopened.historyCoverage.certifiedReadMaxID(after: 0, through: 100) == nil)
    #expect(!reopened.canLoadOlderFromLocal)
    #expect(!reopened.canLoadNewerFromLocal)
    try await fixture.expectUnknownCoverage()
  }
}

@MainActor
private final class ReopenFixture {
  let database: AppDatabase
  let publisher: MessagesPublisher

  init() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    database = try AppDatabase(queue)
    publisher = MessagesPublisher(database: database)
    try await queue.write { db in
      try User(id: 1, email: nil, firstName: "Own fixture sender").insert(db)
      try User(id: 2, email: nil, firstName: "Bot fixture sender").insert(db)
      try Chat(id: 1, date: Date(timeIntervalSince1970: 1), type: .thread,
               title: "Reopen fixture", spaceId: nil).insert(db)
      // Catalog/live materialization does not admit a historical page.
      try MessageHistoryCoverageStore.invalidateAll(db, chatId: 1)
    }
  }

  func snapshot() async throws -> MessagesProgressiveViewModel.InitialState {
    let limit = MessagesProgressiveViewModel.defaultInitialLimit()
    return try await database.reader.read { db in
      let batch = try FullMessage.queryRequest(currentUserId: 1)
        .filter(Column("peerThreadId") == 1)
        .order(Column("date").desc, Column("messageId").desc).limit(limit).fetchAll(db)
      let rows = Array(batch.reversed())
      let metadata = try MessagesProgressiveViewModel.loadedWindowMetadata(db, peer: .thread(id: 1), messages: rows)
      return .init(messages: rows, loadedWindowMetadata: metadata)
    }
  }

  func model(reversed: Bool) async throws -> MessagesProgressiveViewModel {
    let initial = try await snapshot()
    return MessagesProgressiveViewModel(
      peer: .thread(id: 1), reversed: reversed, initialState: initial,
      database: database, publisher: publisher, currentUserId: 1
    )
  }

  func pending(messageID: Int64, randomID: Int64, dateID: Int64) async throws -> FullMessage {
    try await database.dbWriter.write { db in
      var message = Message(messageId: messageID, randomId: randomID, fromId: 1,
                            date: Date(timeIntervalSince1970: Double(1_000 + dateID)), text: "Fixture pending",
                            peerUserId: nil, peerThreadId: 1, chatId: 1, out: true, status: .sending)
      try message.saveMessage(db)
      let row = try FullMessage.queryRequest(currentUserId: 1)
        .filter(Column("chatId") == 1 && Column("messageId") == messageID).fetchOne(db)
      return try #require(row)
    }
  }

  func confirm(randomID: Int64, messageID: Int64) async throws -> FullMessage {
    try await database.dbWriter.write { db in
      let update = InlineProtocol.UpdateMessageId.with { $0.randomID = randomID; $0.messageID = messageID }
      try update.apply(db, currentUserId: 1)
      let row = try FullMessage.queryRequest(currentUserId: 1)
        .filter(Column("chatId") == 1 && Column("messageId") == messageID).fetchOne(db)
      return try #require(row)
    }
  }

  func incoming(messageID: Int64) async throws -> FullMessage {
    try await database.dbWriter.write { db in
      let update = InlineProtocol.UpdateNewMessage.with {
        $0.message = .with {
          $0.id = messageID; $0.chatID = 1; $0.fromID = 2
          $0.peerID = .with { $0.chat.chatID = 1 }
          $0.date = 1_000 + messageID; $0.message = "Fixture incoming"; $0.out = false
        }
      }
      try update.apply(db, publishChanges: false, suppressNotifications: true,
                       materializeMissingReferences: true, incrementUnreadCount: false)
      let row = try FullMessage.queryRequest(currentUserId: 1)
        .filter(Column("chatId") == 1 && Column("messageId") == messageID).fetchOne(db)
      return try #require(row)
    }
  }

  func expectUnknownCoverage() async throws {
    try await database.reader.read { db in
      for scope in MessageHistoryScope.allCases {
        let holes = try MessageHistoryCoverageStore.holes(db, chatId: 1, scope: scope)
        #expect(holes == [MessageHistoryHole(chatId: 1, scope: scope, lowerId: 1,
                                           upperId: MessageHistoryHole.positiveMessageIDMax)])
      }
    }
  }
}
