import Foundation
import GRDB
@testable import InlineKit
import Testing

@Suite("Opt-in anchored message windows")
struct AnchoredMessageWindowTests {
  @Test @MainActor
  func historicalWindowDoesNotAppendTheLiveTail() async throws {
    let fixture = try await Fixture()
    let model = fixture.model(rows: Array(fixture.messages[9 ... 19]), limit: 60)
    defer { model.dispose() }
    model.setHistoryAnchor(15)
    fixture.publisher.publisher.send(.add(.init(messages: [fixture.messages[99]], peer: .thread(id: 1))))
    #expect(model.messages.map(\.message.messageId) == Array(Int64(10) ... 20))
  }

  @Test @MainActor
  func legacyConsumerKeepsItsExistingAppendBehavior() async throws {
    let fixture = try await Fixture()
    let model = fixture.model(rows: Array(fixture.messages[9 ... 19]), limit: nil)
    defer { model.dispose() }
    model.setHistoryAnchor(15) // ignored without the experimental window limit
    fixture.publisher.publisher.send(.add(.init(messages: [fixture.messages[99]], peer: .thread(id: 1))))
    #expect(model.messages.last?.message.messageId == 100)
    #expect(model.messages.count == 12)
  }

  @Test @MainActor
  func aroundAndLatestReplacementKeepPreparedThreadContext() async throws {
    let fixture = try await Fixture()
    let parent = fixture.messages[0]
    let model = fixture.model(rows: Array(fixture.messages[9 ... 19]), limit: 60, parent: parent)
    defer { model.dispose() }
    #expect(try await model.loadLocalWindowAroundMessageAsync(messageId: 50))
    #expect(model.messages.contains { $0.message.messageId == 50 })
    #expect(model.messages.count <= 60)
    #expect(model.threadAnchor == parent.withoutAcknowledgements)
    #expect(try await model.loadLatestWindowAsync())
    #expect(model.messages.last?.message.messageId == 100)
    #expect(model.threadAnchor == parent.withoutAcknowledgements)
    #expect(model.historyCoverage.isAtCertifiedLiveEnd)
  }

  @Test @MainActor
  func historyRepairReloadStaysAroundTheVisibleCoordinate() async throws {
    let fixture = try await Fixture()
    let model = fixture.model(rows: Array(fixture.messages[9 ... 19]), limit: 60)
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
    #expect(model.messages.count <= 60)
  }

  @Test @MainActor
  func liveWindowRetainsABoundedTail() async throws {
    let fixture = try await Fixture()
    let model = fixture.model(rows: Array(fixture.messages[39 ... 98]), limit: 60)
    defer { model.dispose() }
    model.setAtBottom(true)
    fixture.publisher.publisher.send(.add(.init(messages: [fixture.messages[99]], peer: .thread(id: 1))))
    #expect(model.messages.count == 60)
    #expect(model.messages.first?.message.messageId == 41)
    #expect(model.messages.last?.message.messageId == 100)
  }

  @Test @MainActor
  func latestReplacementSupersedesAnOlderPage() async throws {
    let fixture = try await Fixture()
    let model = fixture.model(rows: Array(fixture.messages[39 ... 49]), limit: 60)
    defer { model.dispose() }
    model.setHistoryAnchor(45)
    let older = Task { await model.loadBatchAsync(at: .older, allowUnavailableLocal: true) }
    await Task.yield()
    #expect(try await model.loadLatestWindowAsync())
    _ = await older.value
    #expect(model.messages.count <= 60)
    #expect(model.messages.last?.message.messageId == 100)
    #expect(model.messages.first?.message.messageId == 41)
  }

  @Test @MainActor
  func switchingToLiveBottomInvalidatesPendingHistoricalReload() async throws {
    let fixture = try await Fixture()
    let rows = Array(fixture.messages[79 ... 99])
    let model = fixture.model(rows: rows, limit: 60)
    defer { model.dispose() }
    model.setHistoryAnchor(80)
    fixture.publisher.messagesReload(peer: .thread(id: 1), animated: false)
    model.setAtBottom(true)
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.messages == rows)
  }

  @Test @MainActor
  func confirmingAnUnloadedSendRefreshesTheHistoricalTail() async throws {
    let fixture = try await Fixture()
    let rows = Array(fixture.messages[79 ... 99])
    let model = fixture.model(rows: rows, limit: 60)
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
    var metadataDelivered = false
    model.observe { if case .reload = $0 { metadataDelivered = true } }
    try fixture.publisher.publisher.send(.update(.init(
      message: #require(confirmed), animated: false, peer: .thread(id: 1)
    )))
    for _ in 0 ..< 100 where !metadataDelivered {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(metadataDelivered)
    #expect(model.messages == rows)
    #expect(model.canLoadNewerFromLocal)
    #expect(!model.historyCoverage.isAtCertifiedLiveEnd)
    #expect(try await model.loadLatestWindowAsync())
    #expect(model.messages.last?.message.messageId == 101)
  }

  @Test @MainActor
  func distantCoordinateSupportsBothPageDirections() async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    let model = fixture.model(rows: Array(fixture.messages.suffix(60)), limit: 400)
    defer { model.dispose() }
    model.setHistoryAnchor(1_200)
    #expect(try await model.loadLocalWindowAroundMessageAsync(messageId: 1_200, limit: 60))
    let initialIDs = model.messages.map(\.message.messageId)
    #expect(initialIDs.count == 60)
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
    #expect(try await model.loadLocalWindowAroundMessageAsync(messageId: 1_200, limit: 400))
    #expect(model.messages.count == 400)
    #expect(model.messages.contains { $0.message.messageId == 1_200 })
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

  @MainActor func model(rows: [FullMessage], limit: Int?, parent: FullMessage? = nil) -> MessagesProgressiveViewModel {
    MessagesProgressiveViewModel(
      peer: .thread(id: 1),
      initialState: .init(messages: rows, threadAnchor: parent, loadedWindowMetadata: .init(messages: rows, holes: [])),
      maximumWindowCount: limit, database: database, publisher: publisher, currentUserId: 1
    )
  }
}
