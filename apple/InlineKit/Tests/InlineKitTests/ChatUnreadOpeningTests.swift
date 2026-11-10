import Foundation
import GRDB
@testable import InlineKit
import Testing

@Suite("Opening a chat at its first unread message")
struct ChatUnreadOpeningTests {
  @Test func boundaryNeedsUnreadMessages() {
    #expect(ChatUnreadOpening.boundary(unreadCount: 0, readInboxMaxId: 40) == nil)
    #expect(ChatUnreadOpening.boundary(unreadCount: nil, readInboxMaxId: 40) == nil)
    #expect(ChatUnreadOpening.boundary(unreadCount: 3, readInboxMaxId: 40) == 40)
    #expect(ChatUnreadOpening.boundary(unreadCount: 3, readInboxMaxId: nil) == 0)
  }

  @Test func unreadLineSkipsOwnMessagesAfterTheReadMessage() throws {
    let rows = (1 ... 10).map { id in
      Self.message(id, out: id == 6 || id == 7 || id == 9)
    }
    #expect(ChatUnreadOpening.firstUnreadMessageId(in: rows, boundary: 5, reachesHistoryStart: false) == 8)
    // Display order does not matter.
    #expect(ChatUnreadOpening.firstUnreadMessageId(
      in: rows.reversed(), boundary: 5, reachesHistoryStart: false
    ) == 8)
  }

  @Test func unreadLineNeedsTheReadMessageOrTheHistoryStart() {
    let rows = (20 ... 30).map { Self.message($0) }
    #expect(ChatUnreadOpening.firstUnreadMessageId(in: rows, boundary: 5, reachesHistoryStart: false) == nil)
    #expect(ChatUnreadOpening.firstUnreadMessageId(in: rows, boundary: 5, reachesHistoryStart: true) == 20)
    #expect(ChatUnreadOpening.firstUnreadMessageId(in: rows, boundary: 0, reachesHistoryStart: true) == 20)
  }

  @Test func noUnreadLineWhenOnlyOwnMessagesFollow() {
    let rows = (1 ... 6).map { Self.message($0, out: $0 > 4) }
    #expect(ChatUnreadOpening.firstUnreadMessageId(in: rows, boundary: 4, reachesHistoryStart: false) == nil)
  }

  @Test func latestWindowReachesANearBoundary() {
    let latest = (60 ... 100).map { Self.message($0) }
    #expect(ChatUnreadOpening.windowReachesBoundary(latest, boundary: 97))
    #expect(ChatUnreadOpening.windowReachesBoundary(latest, boundary: 60))
    #expect(!ChatUnreadOpening.windowReachesBoundary(latest, boundary: 59))
  }

  @Test @MainActor
  func distantBoundaryOpensAroundTheReadMessage() async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    let window = try #require(try await fixture.database.reader.read { db in
      try ChatUnreadOpening.certifiedWindow(db, peer: .thread(id: 1), boundary: 1_000)
    })
    let ids = window.map(\.message.messageId)
    #expect(ids.contains(1_000))
    #expect(ids.filter { $0 < 1_000 }.count == 44)
    #expect(ids.filter { $0 > 1_000 }.count == 43)
    #expect(ChatUnreadOpening.firstUnreadMessageId(in: window, boundary: 1_000, reachesHistoryStart: false) == 1_001)

    // The view model keeps the whole window; anchored at the boundary, as the list does when
    // it opens inside history, it leaves the live tail to paging.
    let model = fixture.model(rows: window)
    defer { model.dispose() }
    #expect(model.messages.map(\.message.messageId) == ids)
    #expect(!model.historyCoverage.isAtCertifiedLiveEnd)
    model.setHistoryAnchor(1_000)
    let live = try await fixture.addMessage(2_401)
    fixture.publisher.publisher.send(.add(.init(messages: [live], peer: .thread(id: 1))))
    #expect(model.messages.map(\.message.messageId) == ids)
  }

  @Test @MainActor
  func nothingReadOpensAtTheStartOfHistory() async throws {
    let fixture = try await Fixture(messageCount: 300)
    let window = try #require(try await fixture.database.reader.read { db in
      try ChatUnreadOpening.certifiedWindow(db, peer: .thread(id: 1), boundary: 0)
    })
    #expect(window.first?.message.messageId == 1)
    #expect(ChatUnreadOpening.firstUnreadMessageId(in: window, boundary: 0, reachesHistoryStart: true) == 1)
  }

  @Test @MainActor
  func holeAcrossTheWindowNeedsAFetch() async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    try await fixture.database.dbWriter.write { db in
      try MessageHistoryCoverageStore.invalidate(db, chatId: 1)
      try MessageHistoryCoverageStore.subtract(db, chatId: 1, lowerId: 1, upperId: 1_010)
      try MessageHistoryCoverageStore.subtract(
        db, chatId: 1, lowerId: 1_030, upperId: MessageHistoryHole.positiveMessageIDMax
      )
      // The rows inside the hole are stale cache, not history.
      _ = try Message.filter(Column("messageId") > 1_010 && Column("messageId") < 1_030).deleteAll(db)
    }
    let window = try await fixture.database.reader.read { db in
      try ChatUnreadOpening.certifiedWindow(db, peer: .thread(id: 1), boundary: 1_000)
    }
    #expect(window == nil)
  }

  /// An uncached line opens on the latest messages; once its history is fetched the view model
  /// swaps to the window around the line and keeps it there as live messages arrive.
  @Test @MainActor
  func fetchedLineReplacesTheLatestWindow() async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    let model = fixture.model(rows: try await fixture.latest(60))
    defer { model.dispose() }
    #expect(model.historyCoverage.isAtCertifiedLiveEnd)

    #expect(try await model.loadUnreadOpeningWindowAsync(boundary: 1_000))
    let expected = try #require(try await fixture.database.reader.read { db in
      try ChatUnreadOpening.certifiedWindow(db, peer: .thread(id: 1), boundary: 1_000)
    })
    let ids = expected.map(\.message.messageId)
    #expect(model.messages.map(\.message.messageId) == ids)
    #expect(!model.historyCoverage.isAtCertifiedLiveEnd)
    #expect(ChatUnreadOpening.firstUnreadMessageId(in: model.messages, boundary: 1_000, of: model) == 1_001)

    let live = try await fixture.addMessage(2_401)
    fixture.publisher.publisher.send(.add(.init(messages: [live], peer: .thread(id: 1))))
    #expect(model.messages.map(\.message.messageId) == ids)
  }

  @Test @MainActor
  func lineStillUncachedKeepsTheLatestWindow() async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    try await fixture.database.dbWriter.write { db in
      try MessageHistoryCoverageStore.invalidate(db, chatId: 1)
      try MessageHistoryCoverageStore.subtract(
        db, chatId: 1, lowerId: 2_000, upperId: MessageHistoryHole.positiveMessageIDMax
      )
      // Dense ids prove themselves continuous; drop the stale rows so the hole is real.
      _ = try Message.filter(Column("messageId") > 1_000 && Column("messageId") < 2_000).deleteAll(db)
    }
    let latest = try await fixture.latest(60)
    let model = fixture.model(rows: latest)
    defer { model.dispose() }

    #expect(try await !model.loadUnreadOpeningWindowAsync(boundary: 1_000))
    #expect(model.messages.map(\.message.messageId) == latest.map(\.message.messageId))
  }

  private static func message(_ id: Int64, out: Bool = false) -> FullMessage {
    FullMessage(
      senderInfo: nil,
      message: Message(
        messageId: id, fromId: out ? 1 : 2, date: Date(timeIntervalSince1970: Double(id)), text: "Unread",
        peerUserId: nil, peerThreadId: 1, chatId: 1, out: out
      ),
      reactions: [],
      repliedToMessage: nil,
      attachments: []
    )
  }
}

private struct Fixture {
  let database: AppDatabase
  let publisher: MessagesPublisher

  @MainActor init(messageCount: Int64) async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    database = try AppDatabase(queue)
    publisher = MessagesPublisher(database: database)
    try await queue.write { db in
      try User(id: 1, email: nil, firstName: "Unread fixture").insert(db)
      try Chat(
        id: 1,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Unread",
        spaceId: nil,
        lastMsgId: messageCount
      ).insert(db)
      for id in Int64(1) ... messageCount {
        var message = Message(
          messageId: id, fromId: 1, date: Date(timeIntervalSince1970: Double(id)), text: "Fixture",
          peerUserId: nil, peerThreadId: 1, chatId: 1
        )
        try message.saveMessage(db)
      }
      try MessageHistoryCoverageStore.subtract(
        db,
        chatId: 1,
        lowerId: 1,
        upperId: MessageHistoryHole.positiveMessageIDMax
      )
    }
  }

  func addMessage(_ id: Int64) async throws -> FullMessage {
    try await database.dbWriter.write { db in
      var message = Message(
        messageId: id, fromId: 1, date: Date(timeIntervalSince1970: Double(id)), text: "Live",
        peerUserId: nil, peerThreadId: 1, chatId: 1
      )
      try message.saveMessage(db)
      return try #require(try FullMessage.queryRequest(currentUserId: 1).filter(Column("messageId") == id).fetchOne(db))
    }
  }

  func latest(_ limit: Int) async throws -> [FullMessage] {
    try await database.reader.read { db in
      try FullMessage.queryRequest(currentUserId: 1)
        .filter(Column("chatId") == 1)
        .order(Column("messageId").desc)
        .limit(limit)
        .fetchAll(db)
        .reversed()
    }
  }

  @MainActor func model(rows: [FullMessage]) -> MessagesProgressiveViewModel {
    let metadata = (try? database.reader.read { db in
      try MessagesProgressiveViewModel.loadedWindowMetadata(db, peer: .thread(id: 1), messages: rows)
    }) ?? .init(messages: rows, holes: [])
    return MessagesProgressiveViewModel(
      peer: .thread(id: 1),
      initialState: .init(messages: rows, threadAnchor: .resolved(nil), loadedWindowMetadata: metadata),
      database: database, publisher: publisher, currentUserId: 1
    )
  }
}
