import Foundation
import GRDB
import InlineProtocol
import Testing
@testable import InlineKit

@Suite("New-thread message visibility")
struct NewThreadMessageVisibilityTests {
  @Test("The video's alternating live and optimistic sequence keeps the whole transcript", arguments: [false, true])
  @MainActor
  func alternatingConfirmationSequence(bounded: Bool) async throws {
    let fixture = try await Fixture()
    let first = try await fixture.confirmFirst()
    try await fixture.invalidateCoverage()
    let model = fixture.model(rows: [first], unknownHistory: true, bounded: bounded)
    defer { model.dispose() }

    let bot = try await fixture.insert(messageID: 2)
    fixture.publisher.publisher.send(.add(.init(messages: [bot], peer: .thread(id: 1))))
    let pending = try await fixture.insert(messageID: -456, dateOffset: 3)
    fixture.publisher.publisher.send(.add(.init(messages: [pending], peer: .thread(id: 1))))
    try await fixture.reload(model, expecting: [1, 2, -456])

    let confirmed = try await fixture.database.dbWriter.write { db in
      var message = pending.message
      message.messageId = 3
      message.status = .sent
      message.randomId = nil
      try message.saveMessage(db)
      let row = try FullMessage.queryRequest(currentUserId: 1).filter(Column("globalId") == pending.id).fetchOne(db)
      return try #require(row)
    }
    fixture.publisher.publisher.send(.update(.init(message: confirmed, animated: false, peer: .thread(id: 1))))
    let nextBot = try await fixture.insert(messageID: 4)
    fixture.publisher.publisher.send(.add(.init(messages: [nextBot], peer: .thread(id: 1))))
    try await fixture.reload(model, expecting: [1, 2, 3, 4])
    #expect(model.messages.first(where: { $0.message.messageId == 3 })?.id == pending.id)
    #expect(model.historyCoverage.certifiedReadMaxID(after: 0, through: 4) == nil)
  }

  @Test("Reload after a full or partial clear removes database-deleted live rows", arguments: [false, true], [false, true])
  @MainActor
  func historyClearReload(partial: Bool, anchored: Bool) async throws {
    let fixture = try await Fixture()
    let first = try await fixture.confirmFirst()
    try await fixture.invalidateCoverage()
    let model = fixture.model(rows: [first], unknownHistory: true)
    defer { model.dispose() }
    for id in Int64(2) ... 3 {
      let row = try await fixture.insert(messageID: id)
      fixture.publisher.publisher.send(.add(.init(messages: [row], peer: .thread(id: 1))))
    }
    if anchored { model.setHistoryAnchor(1) }
    try await fixture.database.dbWriter.write { db in
      var clear = InlineProtocol.UpdateClearChatHistory()
      clear.peerID.chat.chatID = 1
      if partial { clear.beforeDate = 1_003 }
      try clear.apply(db, publishChanges: false)
    }
    try await fixture.reload(model, expecting: partial ? [3] : [])
  }

  @Test("An unanchored live window stays bounded even while history is unknown")
  @MainActor
  func unknownLiveWindowStaysBounded() async throws {
    let fixture = try await Fixture()
    let first = try await fixture.confirmFirst()
    try await fixture.invalidateCoverage()
    let model = fixture.model(rows: [first], unknownHistory: true, bounded: true)
    defer { model.dispose() }
    let rows = try await fixture.database.dbWriter.write { db in
      for id in Int64(2) ... 402 {
        var message = Message(
          messageId: id, fromId: 1, date: first.message.date.addingTimeInterval(Double(id)),
          text: "Live message", peerUserId: nil, peerThreadId: 1, chatId: 1, out: true
        )
        try message.saveMessage(db)
      }
      return try FullMessage.queryRequest(currentUserId: 1)
        .filter(Column("messageId") > 1).order(Column("messageId").asc).fetchAll(db)
    }
    fixture.publisher.publisher.send(.add(.init(messages: rows, peer: .thread(id: 1))))
    #expect(model.messages.count == 400)
    #expect(model.messages.map(\.message.messageId) == Array(Int64(3) ... 402))
    _ = try await fixture.insert(messageID: 403)
    try await fixture.reload(model, expecting: Array(Int64(4) ... 403))
    #expect(model.messages.count == 400)
    try await fixture.database.dbWriter.write { db in
      for id in Int64(404) ... 463 {
        var message = Message(
          messageId: id, fromId: 1, date: first.message.date.addingTimeInterval(Double(id)),
          text: "Cached message", peerUserId: nil, peerThreadId: 1, chatId: 1, out: true
        )
        try message.saveMessage(db)
      }
    }
    let expected = Array(Int64(5) ... 403) + [463]
    try await fixture.reload(model, expecting: expected)
  }

  @Test("Live messages retain earlier rendered messages while history is unknown", arguments: [false, true])
  @MainActor
  func liveSequenceSurvivesUnknownCoverage(bounded: Bool) async throws {
    let fixture = try await Fixture()
    let first = try await fixture.confirmFirst()
    try await fixture.database.dbWriter.write { db in
      try MessageHistoryCoverageStore.invalidate(db, chatId: 1)
    }
    let model = fixture.model(rows: [first], unknownHistory: true, bounded: bounded)
    defer { model.dispose() }

    for id in Int64(2) ... 4 {
      let next = try await fixture.database.dbWriter.write { db in
        var message = Message(
          messageId: id, fromId: 1, date: first.message.date.addingTimeInterval(Double(id)),
          text: "Next live message", peerUserId: nil, peerThreadId: 1, chatId: 1, out: true
        )
        try message.saveMessage(db)
        return try FullMessage.queryRequest(currentUserId: 1).filter(Column("messageId") == id).fetchOne(db)
      }
      fixture.publisher.publisher.send(.add(.init(messages: [try #require(next)], peer: .thread(id: 1))))
      try await waitUntil { model.newestLoadedMessageId == id }
      #expect(model.messages.map(\.message.messageId) == Array(Int64(1) ... id))
      #expect(!model.historyCoverage.isAtCertifiedLiveEnd)
      #expect(model.historyCoverage.unknownAdjacencyBoundaries.count == Int(id - 1))
      #expect(model.historyCoverage.certifiedReadMaxID(after: 0, through: id) == nil)
    }
    try await fixture.reload(model)
    #expect(model.messages.map(\.message.messageId) == [1, 2, 3, 4])
  }

  @Test("Unpublished cached rows still require a continuous history component")
  @MainActor
  func cachedRowsAreStillProjectedThroughCoverage() async throws {
    let fixture = try await Fixture()
    let first = try await fixture.confirmFirst()
    var later = first
    later.message.globalId = 2
    later.message.messageId = 100
    let model = fixture.model(rows: [first, later], unknownHistory: true)
    defer { model.dispose() }
    #expect(model.messages.map(\.message.messageId) == [100])
    #expect(!model.historyCoverage.isAtCertifiedLiveEnd)
    #expect(!model.historyCoverage.isCertifiedMessage(100))
  }

  @Test("History reload retains the pending first message while away from the bottom")
  @MainActor
  func pendingFirstMessageSurvivesRangeReload() async throws {
    let fixture = try await Fixture()
    let model = fixture.model()
    defer { model.dispose() }
    model.setAtBottom(false)
    try await fixture.reload(model)
    #expect(model.messages.map(\.id) == [fixture.first.id])
    #expect(model.messages.first?.message.status == .sending)
  }

  @Test("Certifying an empty new thread does not hide its pending first message")
  @MainActor
  func emptyHistoryThenReloadRetainsFirstMessage() async throws {
    let fixture = try await Fixture()
    let model = fixture.model(unknownHistory: true)
    defer { model.dispose() }
    model.setAtBottom(true)
    let metadata = try await fixture.database.reader.read { db in
      try MessagesProgressiveViewModel.loadedWindowMetadata(db, peer: .thread(id: 1), messages: [fixture.first])
    }
    #expect(model.applyLoadedWindowMetadata(metadata, for: model.beginLoadedWindowMetadataRequest()))
    #expect(model.historyCoverage.isAtCertifiedLiveEnd)
    try await fixture.reload(model)
    #expect(model.messages.map(\.id) == [fixture.first.id])
  }

  @Test("The first message stays visible when its optimistic ID is confirmed")
  @MainActor
  func firstMessageConfirmationAfterHistoryReload() async throws {
    let fixture = try await Fixture()
    let model = fixture.model()
    defer { model.dispose() }
    model.setAtBottom(false)
    try await fixture.reload(model)
    let confirmed = try await fixture.database.dbWriter.write { db in
      var message = fixture.first.message
      message.messageId = 1
      message.status = .sent
      message.randomId = nil
      try message.saveMessage(db)
      return try FullMessage.queryRequest(currentUserId: 1).fetchOne(db)
    }
    fixture.publisher.publisher.send(.update(.init(
      message: try #require(confirmed), animated: false, peer: .thread(id: 1)
    )))
    #expect(model.messages.map(\.id) == [fixture.first.id])
    #expect(model.messages.first?.message.messageId == 1)
    #expect(model.messages.first?.message.status == .sent)
  }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(10))
  while !condition(), ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
}

private struct Fixture {
  let database: AppDatabase
  let publisher: MessagesPublisher
  let first: FullMessage

  @MainActor
  init() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    database = try AppDatabase(queue)
    publisher = MessagesPublisher(database: database)
    first = try await queue.write { db in
      try User(id: 1, email: nil, firstName: "Author").insert(db)
      try Chat(id: 1, date: Date(), type: .thread, title: "New thread", spaceId: nil).insert(db)
      var message = Message(
        messageId: -123, randomId: 123, fromId: 1, date: Date(timeIntervalSince1970: 1_000), text: "First message",
        peerUserId: nil, peerThreadId: 1, chatId: 1, out: true, status: .sending
      )
      try message.saveMessage(db)
      try Chat.updateLastMsgId(db, chatId: 1, lastMsgId: message.messageId, date: message.date)
      try MessageHistoryCoverageStore.subtract(db, chatId: 1, lowerId: 1, upperId: MessageHistoryHole.positiveMessageIDMax)
      let fullMessage = try FullMessage.queryRequest(currentUserId: 1).fetchOne(db)
      return try #require(fullMessage)
    }
  }

  @MainActor
  func model(rows: [FullMessage]? = nil, unknownHistory: Bool = false, bounded: Bool = false) -> MessagesProgressiveViewModel {
    let rows = rows ?? [first]
    return MessagesProgressiveViewModel(
      peer: .thread(id: 1),
      initialState: .init(messages: rows, loadedWindowMetadata: .init(
        messages: rows,
        holes: unknownHistory ? [.init(chatId: 1, lowerId: 1, upperId: MessageHistoryHole.positiveMessageIDMax)] : []
      )),
      maximumWindowCount: bounded ? 400 : nil,
      database: database, publisher: publisher, currentUserId: 1
    )
  }

  func confirmFirst() async throws -> FullMessage {
    try await database.dbWriter.write { db in
      var message = first.message
      message.messageId = 1
      message.randomId = nil
      message.status = .sent
      try message.saveMessage(db)
      let fullMessage = try FullMessage.queryRequest(currentUserId: 1).filter(Column("messageId") == 1).fetchOne(db)
      return try #require(fullMessage)
    }
  }

  func invalidateCoverage() async throws {
    try await database.dbWriter.write { db in
      try MessageHistoryCoverageStore.invalidate(db, chatId: 1)
    }
  }

  func insert(messageID: Int64, dateOffset: Double? = nil) async throws -> FullMessage {
    try await database.dbWriter.write { db in
      var message = Message(
        messageId: messageID, randomId: messageID < 0 ? -messageID : nil, fromId: 1,
        date: first.message.date.addingTimeInterval(dateOffset ?? Double(messageID)),
        text: "Next message", peerUserId: nil, peerThreadId: 1, chatId: 1, out: true,
        status: messageID < 0 ? .sending : .sent
      )
      try message.saveMessage(db)
      let row = try FullMessage.queryRequest(currentUserId: 1).filter(Column("messageId") == messageID).fetchOne(db)
      return try #require(row)
    }
  }

  @MainActor
  func reload(_ model: MessagesProgressiveViewModel, expecting messageIDs: [Int64]? = nil) async throws {
    var didReload = false
    model.observe { if case .reload = $0 { didReload = true } }
    publisher.messagesReload(peer: .thread(id: 1), animated: false)
    try await waitUntil {
      didReload && (messageIDs == nil || model.messages.map(\.message.messageId) == messageIDs)
    }
    #expect(didReload)
    if let messageIDs { #expect(model.messages.map(\.message.messageId) == messageIDs) }
  }
}
