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

  /// Changes a stored row without publishing it, as a sync or history save does before its reload.
  func setText(_ text: String, of messageID: Int64) async throws {
    try await database.dbWriter.write { db in
      try db.execute(
        sql: "UPDATE message SET text = ? WHERE chatId = 1 AND messageId = ?",
        arguments: [text, messageID]
      )
    }
  }

  @MainActor func waitForReload(of model: MessagesProgressiveViewModel) async throws {
    for _ in 0 ..< 500 where model.hasPendingReload {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!model.hasPendingReload)
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

/// Window reads race with live traffic: an edit, a new message or a scroll anchor change that
/// lands while a read is in flight (2026-11-10 message list review).
@Suite("Window loads under live traffic")
struct WindowLoadLiveTrafficTests {
  @Test @MainActor
  func editDuringTheUnreadWindowReadKeepsTheLanding() async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    let latest = try await fixture.latest(60)
    let model = fixture.model(rows: latest)
    defer { model.dispose() }

    let load = Task { @MainActor in try await model.loadUnreadOpeningWindowAsync(boundary: 1_000) }
    await Task.yield()
    fixture.publisher.publisher.send(.update(.init(message: latest[59], animated: false, peer: .thread(id: 1))))

    #expect(try await load.value)
    #expect(ChatUnreadOpening.firstUnreadMessageId(in: model.messages, boundary: 1_000, of: model) == 1_001)
  }

  @Test @MainActor
  func editDuringAnOlderPageReadKeepsThePage() async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    let latest = try await fixture.latest(60)
    let model = fixture.model(rows: latest)
    defer { model.dispose() }
    #expect(model.canLoadOlderFromLocal)

    let load = Task { @MainActor in await model.loadBatchAsync(at: .older) }
    await Task.yield()
    fixture.publisher.publisher.send(.update(.init(message: latest[59], animated: false, peer: .thread(id: 1))))

    #expect(await load.value)
    #expect(model.messages.count > 60)
  }

  @Test @MainActor
  func scrollingDuringAnOlderPageReadKeepsThePage() async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    let latest = try await fixture.latest(60)
    let model = fixture.model(rows: latest)
    defer { model.dispose() }

    model.setAtBottom(false)
    model.setHistoryAnchor(2_350)
    let load = Task { @MainActor in await model.loadBatchAsync(at: .older) }
    await Task.yield()
    // The first visible row changes as the list keeps scrolling.
    model.setHistoryAnchor(2_349)

    #expect(await load.value)
    #expect(model.messages.count > 60)
  }

  /// Saving a fetched history page publishes a reload just before the list reads that page.
  @Test @MainActor
  func reloadDuringAnOlderPageReadKeepsThePage() async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    let model = fixture.model(rows: try await fixture.latest(60))
    defer { model.dispose() }
    model.setAtBottom(false)
    model.setHistoryAnchor(2_350)

    fixture.publisher.publisher.send(.reload(peer: .thread(id: 1), animated: false))
    let loaded = await model.loadBatchAsync(at: .older)
    while model.hasPendingReload {
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(loaded)
    #expect(model.messages.count > 60)
    #expect(model.messages.contains { $0.message.messageId == 2_340 })
  }

  @Test @MainActor
  func newMessageDuringTheReturnToLatestReadStillReturns() async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    let model = fixture.model(rows: try await fixture.latest(60))
    defer { model.dispose() }
    #expect(model.loadLocalWindowAroundMessage(messageId: 1_000, publish: false))
    #expect(!model.historyCoverage.isAtCertifiedLiveEnd)

    let live = try await fixture.addMessage(2_401)
    let load = Task { @MainActor in try await model.loadLatestWindowAsync() }
    await Task.yield()
    fixture.publisher.publisher.send(.add(.init(messages: [live], peer: .thread(id: 1))))

    #expect(try await load.value)
    #expect(model.historyCoverage.isAtCertifiedLiveEnd)
  }

  /// The list reports the first visible row on every scroll tick, so a reload published while
  /// scrolling (sync catch-up, a saved history page) must survive the anchor moving.
  @Test @MainActor
  func reloadWhileScrollingAtTheLiveEndStillLands() async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    let model = fixture.model(rows: try await fixture.latest(60))
    defer { model.dispose() }
    model.setAtBottom(false)
    model.setHistoryAnchor(2_350)

    try await fixture.setText("Edited", of: 2_360)
    fixture.publisher.publisher.send(.reload(peer: .thread(id: 1), animated: false))
    let generation = model.reloadGeneration
    model.setHistoryAnchor(2_349)
    #expect(model.hasPendingReload)
    #expect(model.reloadGeneration == generation)

    try await fixture.waitForReload(of: model)
    #expect(model.messages.first { $0.message.messageId == 2_360 }?.message.text == "Edited")
    #expect(model.messages.count == 60)
  }

  @Test @MainActor
  func reloadInsideHistoryKeepsReadingAsTheAnchorMoves() async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    let model = fixture.model(rows: try await fixture.latest(60))
    defer { model.dispose() }
    #expect(model.loadLocalWindowAroundMessage(messageId: 1_000, publish: false))
    #expect(!model.historyCoverage.isAtCertifiedLiveEnd)

    try await fixture.setText("Edited", of: 1_010)
    fixture.publisher.publisher.send(.reload(peer: .thread(id: 1), animated: false))
    let generation = model.reloadGeneration
    model.setHistoryAnchor(1_002)
    model.setHistoryAnchor(1_004)
    #expect(model.hasPendingReload)
    #expect(model.reloadGeneration == generation)

    try await fixture.waitForReload(of: model)
    #expect(model.messages.first { $0.message.messageId == 1_010 }?.message.text == "Edited")
    #expect(model.messages.contains { $0.message.messageId == 1_004 })
  }

  /// A reload scheduled at the bottom reads only the latest rows; once the user has scrolled
  /// into older loaded rows it is read again for the window they are in.
  @Test @MainActor
  func reloadScheduledAtTheBottomIsReadAgainAfterScrollingUp() async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    let model = fixture.model(rows: try await fixture.latest(200))
    defer { model.dispose() }
    #expect(model.historyCoverage.isAtCertifiedLiveEnd)

    try await fixture.setText("Edited", of: 2_250)
    fixture.publisher.publisher.send(.reload(peer: .thread(id: 1), animated: false))
    let generation = model.reloadGeneration
    model.setAtBottom(false)
    model.setHistoryAnchor(2_250)
    #expect(model.hasPendingReload)
    #expect(model.reloadGeneration != generation)

    try await fixture.waitForReload(of: model)
    #expect(model.messages.first { $0.message.messageId == 2_250 }?.message.text == "Edited")
    #expect(model.messages.count == 200)
  }

  @Test @MainActor
  func editOfALoadedRowUpdatesItInPlace() async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    let rows = try await fixture.latest(600)
    let model = fixture.model(rows: rows)
    defer { model.dispose() }
    var changes: [MessagesProgressiveViewModel.MessagesChangeSet] = []
    model.observe { changes.append($0) }
    let edges = (model.oldestLoadedMessageId, model.newestLoadedMessageId, model.canLoadOlderFromLocal)

    var edited = rows[300]
    edited.message.text = "Edited"
    fixture.publisher.publisher.send(.update(.init(message: edited, animated: false, peer: .thread(id: 1))))

    #expect(model.messages[300].message.text == "Edited")
    #expect(model.messagesByID[edited.id]?.message.text == "Edited")
    #expect(model.messagesByID.count == model.messages.count)
    #expect(model.messages.allSatisfy { model.messagesByID[$0.id] == $0 })
    #expect(model.oldestLoadedMessageId == edges.0)
    #expect(model.newestLoadedMessageId == edges.1)
    #expect(model.canLoadOlderFromLocal == edges.2)
    guard case let .updated(updated, indexSet, _) = changes.last else {
      Issue.record("expected an update")
      return
    }
    #expect(indexSet == [300])
    #expect(updated.map(\.message.text) == ["Edited"])
  }

  @Test @MainActor
  func confirmingASendMovesTheNewestEdge() async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    let model = fixture.model(rows: try await fixture.latest(60))
    defer { model.dispose() }

    let pending = try await fixture.database.dbWriter.write { db -> FullMessage in
      var message = Message(
        messageId: -5, randomId: 5, fromId: 1, date: Date(timeIntervalSince1970: 2_401), text: "Sending",
        peerUserId: nil, peerThreadId: 1, chatId: 1, out: true, status: .sending
      )
      try message.saveMessage(db)
      return try #require(try FullMessage.queryRequest(currentUserId: 1).filter(Column("messageId") == -5).fetchOne(db))
    }
    fixture.publisher.publisher.send(.add(.init(messages: [pending], peer: .thread(id: 1))))
    #expect(model.messages.last?.id == pending.id)
    #expect(model.newestLoadedMessageId == 2_400)

    let confirmed = try await fixture.database.dbWriter.write { db -> FullMessage in
      try db.execute(
        sql: "UPDATE message SET messageId = 2401, status = ? WHERE globalId = ?",
        arguments: [MessageSendingStatus.sent.rawValue, pending.id]
      )
      return try #require(try FullMessage.queryRequest(currentUserId: 1).filter(Column("messageId") == 2_401).fetchOne(db))
    }
    #expect(confirmed.id == pending.id)
    fixture.publisher.publisher.send(.update(.init(message: confirmed, animated: false, peer: .thread(id: 1))))

    #expect(model.messages.last?.message.messageId == 2_401)
    #expect(model.messagesByID[pending.id]?.message.messageId == 2_401)
    #expect(model.newestLoadedMessageId == 2_401)
    #expect(model.historyCoverage.isAtCertifiedLiveEnd)
  }

  @Test @MainActor
  func pinChangeUpdatesOnlyItsRows() async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    let model = fixture.model(rows: try await fixture.latest(60))
    defer { model.dispose() }

    fixture.publisher.publisher.send(.pinnedMessages(.init(chatId: 1, messageIds: [2_390], pinned: true)))

    #expect(model.messages.first { $0.message.messageId == 2_390 }?.message.pinned == true)
    #expect(model.messages.filter { $0.message.pinned == true }.count == 1)
    #expect(model.messagesByID.count == model.messages.count)
    #expect(model.messages.allSatisfy { model.messagesByID[$0.id] == $0 })
  }
}
