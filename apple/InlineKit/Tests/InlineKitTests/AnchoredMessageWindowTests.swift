import Foundation
import GRDB
@testable import InlineKit
import Testing

@Suite("Anchored message windows")
struct AnchoredMessageWindowTests {
  @Test @MainActor
  func liveWindowAppendsNewMessages() async throws {
    let fixture = try await Fixture()
    let model = fixture.model(rows: Array(fixture.messages[9 ... 19]))
    defer { model.dispose() }
    fixture.publisher.publisher.send(.add(.init(messages: [fixture.messages[99]], peer: .thread(id: 1))))
    #expect(model.messages.last?.message.messageId == 100)
    #expect(model.messages.count == 12)
  }

  @Test @MainActor
  func historicalWindowDoesNotAppendTheLiveTail() async throws {
    let fixture = try await Fixture()
    let model = fixture.model(rows: Array(fixture.messages[9 ... 19]))
    defer { model.dispose() }
    model.setHistoryAnchor(15)
    fixture.publisher.publisher.send(.add(.init(messages: [fixture.messages[99]], peer: .thread(id: 1))))
    #expect(model.messages.map(\.message.messageId) == Array(Int64(10) ... 20))
  }

  @Test @MainActor
  func aroundAndLatestReplacementKeepPreparedThreadContext() async throws {
    let fixture = try await Fixture()
    let parent = fixture.messages[0]
    let model = fixture.model(rows: Array(fixture.messages[9 ... 19]), parent: parent)
    defer { model.dispose() }
    #expect(model.loadLocalWindowAroundMessage(messageId: 50))
    #expect(model.messages.contains { $0.message.messageId == 50 })
    #expect(model.threadAnchor == parent.withoutAcknowledgements)
    #expect(try await model.loadLatestWindowAsync())
    #expect(model.messages.last?.message.messageId == 100)
    #expect(model.threadAnchor == parent.withoutAcknowledgements)
    #expect(model.historyCoverage.isAtCertifiedLiveEnd)
  }

  @Test @MainActor
  func historyRepairReloadStaysAroundTheVisibleCoordinate() async throws {
    let fixture = try await Fixture()
    let model = fixture.model(rows: Array(fixture.messages[9 ... 19]))
    defer { model.dispose() }
    model.setHistoryAnchor(15)
    var reloaded = false
    model.observe { if case .reload = $0 { reloaded = true } }
    fixture.publisher.messagesReload(peer: .thread(id: 1), animated: false)
    for _ in 0 ..< 100 where !reloaded {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(reloaded)
    #expect(model.messages.contains { $0.message.messageId == 15 })
    #expect(model.messages.last?.message.messageId != 100)
  }

  @Test @MainActor
  func latestReplacementSupersedesAnOlderPage() async throws {
    let fixture = try await Fixture()
    let model = fixture.model(rows: Array(fixture.messages[39 ... 49]))
    defer { model.dispose() }
    model.setHistoryAnchor(45)
    let older = Task { await model.loadBatchAsync(at: .older, allowUnavailableLocal: true) }
    await Task.yield()
    #expect(try await model.loadLatestWindowAsync())
    let latestIDs = model.messages.map(\.message.messageId)
    _ = await older.value
    #expect(model.messages.map(\.message.messageId) == latestIDs)
    #expect(model.messages.last?.message.messageId == 100)
    #expect(model.historyCoverage.isAtCertifiedLiveEnd)
  }

  @Test @MainActor
  func confirmingAnUnloadedSendRefreshesTheHistoricalTail() async throws {
    let fixture = try await Fixture()
    let rows = Array(fixture.messages[79 ... 99])
    let model = fixture.model(rows: rows)
    defer { model.dispose() }
    model.setHistoryAnchor(80)
    #expect(model.historyCoverage.isAtCertifiedLiveEnd)
    let confirmed = try await fixture.database.dbWriter.write { db in
      var message = Message(
        messageId: 101, fromId: 1, date: Date(timeIntervalSince1970: 101), text: "Confirmed outside window",
        peerUserId: nil, peerThreadId: 1, chatId: 1
      )
      try message.saveMessage(db)
      return try FullMessage.queryRequest(currentUserId: 1)
        .filter(Column("messageId") == 101).fetchOne(db)
    }
    try fixture.publisher.publisher.send(.update(.init(
      message: #require(confirmed), animated: false, peer: .thread(id: 1)
    )))
    #expect(model.messages == rows)
    #expect(model.canLoadNewerFromLocal)
    #expect(!model.historyCoverage.isAtCertifiedLiveEnd)
    #expect(try await model.loadLatestWindowAsync())
    #expect(model.messages.last?.message.messageId == 101)
  }

  @Test @MainActor
  func distantCoordinateSupportsBothPageDirections() async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    let model = fixture.model(rows: Array(fixture.messages.suffix(60)))
    defer { model.dispose() }
    model.setHistoryAnchor(1_200)
    #expect(model.loadLocalWindowAroundMessage(messageId: 1_200))
    let initialIDs = model.messages.map(\.message.messageId)
    #expect(initialIDs.contains(1_200))
    #expect(!initialIDs.contains(2_400))
    #expect(await model.loadBatchAsync(at: .older, publish: false))
    #expect(await model.loadBatchAsync(at: .newer, publish: false))
    let expandedIDs = model.messages.map(\.message.messageId)
    let initialFirst = try #require(initialIDs.first)
    let initialLast = try #require(initialIDs.last)
    #expect(try #require(expandedIDs.first) < initialFirst)
    #expect(try #require(expandedIDs.last) > initialLast)
    #expect(Set(initialIDs).isSubset(of: Set(expandedIDs)))
    #expect(Set(expandedIDs).count == expandedIDs.count)
    #expect(expandedIDs == expandedIDs.sorted())
  }

  @Test("a message sent or received while scrolled up at the live end is shown and survives a reload")
  @MainActor
  func scrolledUpLiveWindowStillShowsNewMessages() async throws {
    let fixture = try await Fixture()
    let model = fixture.model(rows: Array(fixture.messages[79 ... 99]))
    defer { model.dispose() }
    // The list reports a visible row as soon as the user scrolls off the bottom.
    model.setAtBottom(false)
    model.setHistoryAnchor(90)

    let pending = try await fixture.database.dbWriter.write { db -> FullMessage in
      var message = Message(
        messageId: -5, randomId: 5, fromId: 1, date: Date(timeIntervalSince1970: 200), text: "Sent while scrolled up",
        peerUserId: nil, peerThreadId: 1, chatId: 1, out: true, status: .sending
      )
      try message.saveMessage(db)
      let row = try FullMessage.queryRequest(currentUserId: 1).filter(Column("messageId") == -5).fetchOne(db)
      return try #require(row)
    }
    fixture.publisher.publisher.send(.add(.init(messages: [pending], peer: .thread(id: 1))))
    #expect(model.messages.last?.id == pending.id)

    var reloaded = false
    model.observe { if case .reload = $0 { reloaded = true } }
    fixture.publisher.messagesReload(peer: .thread(id: 1), animated: false)
    for _ in 0 ..< 200 where !reloaded { try await Task.sleep(for: .milliseconds(10)) }
    #expect(reloaded)
    #expect(model.messages.contains { $0.id == pending.id })

    let incoming = try await fixture.database.dbWriter.write { db -> FullMessage in
      var message = Message(
        messageId: 101, fromId: 1, date: Date(timeIntervalSince1970: 201), text: "Incoming",
        peerUserId: nil, peerThreadId: 1, chatId: 1
      )
      try message.saveMessage(db)
      let row = try FullMessage.queryRequest(currentUserId: 1).filter(Column("messageId") == 101).fetchOne(db)
      return try #require(row)
    }
    fixture.publisher.publisher.send(.add(.init(messages: [incoming], peer: .thread(id: 1))))
    #expect(model.messages.contains { $0.message.messageId == 101 })
    #expect(model.messages.contains { $0.id == pending.id })
  }
}

private struct Fixture {
  let database: AppDatabase
  let publisher: MessagesPublisher
  let messages: [FullMessage]

  @MainActor init(messageCount: Int64 = 100) async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    database = try AppDatabase(queue)
    publisher = MessagesPublisher(database: database)
    messages = try await queue.write { db in
      try User(id: 1, email: nil, firstName: "Window fixture").insert(db)
      try Chat(
        id: 1,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Window",
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
      return try FullMessage.queryRequest(currentUserId: 1).order(Column("messageId").asc).fetchAll(db)
    }
  }

  /// The prepared first frame carries the database's own paging edges.
  private func metadata(for rows: [FullMessage]) -> MessagesProgressiveViewModel.LoadedWindowMetadata {
    (try? database.reader.read { db in
      try MessagesProgressiveViewModel.loadedWindowMetadata(db, peer: .thread(id: 1), messages: rows)
    }) ?? .init(messages: rows, holes: [])
  }

  @MainActor func model(rows: [FullMessage], parent: FullMessage? = nil) -> MessagesProgressiveViewModel {
    MessagesProgressiveViewModel(
      peer: .thread(id: 1),
      initialState: .init(messages: rows, threadAnchor: parent, loadedWindowMetadata: metadata(for: rows)),
      database: database, publisher: publisher, currentUserId: 1
    )
  }
}
