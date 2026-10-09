import Foundation
import GRDB
import InlineProtocol
import Testing
@testable import InlineKit

@Suite("Scrolled cached-live window regressions")
struct ScrolledLiveWindowRegressionTests {
  @Test("A distant viewport anchor cannot drop a shown send after positive ID confirmation",
        arguments: [false, true], [false, true])
  @MainActor
  func confirmedSendSurvivesReload(reversed: Bool, confirmationBehindReload: Bool) async throws {
    let fixture = try await ScrolledLiveFixture()
    let model = try await fixture.model(reversed: reversed)
    defer { model.dispose() }
    let confirmedID = fixture.nextMessageID
    #expect(model.newestLoadedMessageId == confirmedID - 1)
    #expect(model.historyCoverage.isAtCertifiedLiveEnd)
    model.setAtBottom(false)
    model.setHistoryAnchor(10)

    let pending = try await fixture.insert(messageID: -5, randomID: 5, out: true)
    fixture.publisher.publisher.send(.add(.init(messages: [pending], peer: .thread(id: 1))))
    #expect(model.messages.contains { $0.id == pending.id })
    let confirmed = try await fixture.database.dbWriter.write { db -> FullMessage in
      // Invoke the same ID remap reducer used by a real send response. The
      // fixture publisher below routes that canonical row to this model.
      var update = InlineProtocol.UpdateMessageId()
      update.randomID = 5
      update.messageID = confirmedID
      try update.apply(db, currentUserId: 1)
      let row = try FullMessage.queryRequest(currentUserId: 1)
        .filter(Column("globalId") == pending.id).fetchOne(db)
      let confirmed = try #require(row)
      #expect(confirmed.message.messageId == confirmedID)
      #expect(confirmed.message.status == .sent)
      return confirmed
    }

    var reloads = 0
    model.observe { if case .reload = $0 { reloads += 1 } }
    // Both variants are synchronous MainActor publication bursts. In the
    // second, the positive-ID publication invalidates a pending read and
    // exercises its required reconciliation reschedule.
    if confirmationBehindReload {
      fixture.publisher.messagesReload(peer: .thread(id: 1), animated: false)
    }
    fixture.publisher.publisher.send(.update(.init(message: confirmed, animated: false, peer: .thread(id: 1))))
    #expect(model.messages.first(where: { $0.id == pending.id })?.message.messageId == confirmedID)
    if !confirmationBehindReload {
      fixture.publisher.messagesReload(peer: .thread(id: 1), animated: false)
    }
    try await waitForScrolledReload { reloads > 0 }
    #expect(reloads > 0)
    #expect(model.messages.first(where: { $0.id == pending.id })?.message.messageId == confirmedID)
    #expect(model.messages.first(where: { $0.id == pending.id })?.message.status == .sent)
    #expect(Set(model.messages.map(\.id)).count == model.messages.count)
    let expectedTail: [Int64] = reversed ? [confirmedID, confirmedID - 1] : [confirmedID - 1, confirmedID]
    #expect(model.messages.filter { $0.message.messageId >= confirmedID - 1 }.map(\.message.messageId) == expectedTail)
    let canonical = try await fixture.database.reader.read { db in
      try Message.fetchOne(db, key: ["chatId": 1, "messageId": confirmedID])
    }
    #expect(canonical?.globalId == pending.id)
  }

  @Test("An incoming cached-tail row survives a reload while the viewport is far above it",
        arguments: [false, true])
  @MainActor
  func incomingTailSurvivesReload(reversed: Bool) async throws {
    let fixture = try await ScrolledLiveFixture()
    let model = try await fixture.model(reversed: reversed)
    defer { model.dispose() }
    model.setAtBottom(false)
    model.setHistoryAnchor(10)
    let confirmedID = fixture.nextMessageID
    let incoming = try await fixture.insert(messageID: confirmedID, randomID: nil, out: false)
    fixture.publisher.publisher.send(.add(.init(messages: [incoming], peer: .thread(id: 1))))
    #expect(model.messages.contains { $0.id == incoming.id })

    var reloads = 0
    model.observe { if case .reload = $0 { reloads += 1 } }
    fixture.publisher.messagesReload(peer: .thread(id: 1), animated: false)
    try await waitForScrolledReload { reloads > 0 }
    #expect(reloads > 0)
    #expect(model.messages.contains { $0.id == incoming.id })
    let expectedTail: [Int64] = reversed ? [confirmedID, confirmedID - 1] : [confirmedID - 1, confirmedID]
    #expect(model.messages.filter { $0.message.messageId >= confirmedID - 1 }.map(\.message.messageId) == expectedTail)
    let canonical = try await fixture.database.reader.read { db in
      try Message.fetchOne(db, key: ["chatId": 1, "messageId": confirmedID])
    }
    #expect(canonical?.globalId == incoming.id)
  }
}

@MainActor
private func waitForScrolledReload(_ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while !condition(), ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
}

private struct ScrolledLiveFixture {
  let database: AppDatabase
  let publisher: MessagesPublisher
  let messages: [FullMessage]
  let nextMessageID: Int64

  @MainActor
  init() async throws {
    let messageCount = Int64(max(100, MessagesProgressiveViewModel.defaultInitialLimit() * 2))
    nextMessageID = messageCount + 1
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    database = try AppDatabase(queue)
    publisher = MessagesPublisher(database: database)
    messages = try await queue.write { db in
      try User(id: 1, email: nil, firstName: "Own sender").insert(db)
      try User(id: 2, email: nil, firstName: "Incoming sender").insert(db)
      try Chat(id: 1, date: Date(timeIntervalSince1970: 1), type: .thread,
               title: "Scrolled fixture", spaceId: nil).insert(db)
      // Build a long continuous window through actual admitted pages. Its
      // size exceeds the model's initial page size, independent of screen
      // metrics; the viewport remains near its oldest end.
      var beforeID: Int64? = nil
      while true {
        var transaction = beforeID.map {
          GetChatHistoryTransaction(peer: .thread(id: 1), mode: .historyModeOlder, beforeID: $0, limit: 100)
        } ?? GetChatHistoryTransaction(peer: .thread(id: 1), mode: .historyModeLatest, limit: 100)
        transaction.context.admissionToken = try HistoryPageAdmissionToken.capture(db, chatId: 1)
        let upper = (beforeID ?? (messageCount + 1)) - 1
        let lower = max(1, upper - 99)
        let page = InlineProtocol.GetChatHistoryResult.with {
          $0.seq = 0
          $0.messages = (lower ... upper).reversed().map { id in
            .with {
              $0.id = id
              $0.chatID = 1
              $0.fromID = 2
              $0.peerID = .with { $0.chat.chatID = 1 }
              $0.date = id
              $0.message = "Admitted cached row"
            }
          }
        }
        try GetChatHistoryTransaction.apply(page, context: transaction.context, db: db)
        if lower == 1 { break }
        beforeID = lower
      }
      return try FullMessage.queryRequest(currentUserId: 1)
        .filter(Column("chatId") == 1).order(Column("messageId").asc).fetchAll(db)
    }
  }

  @MainActor
  func model(reversed: Bool) async throws -> MessagesProgressiveViewModel {
    let rows = messages
    let metadata = try await database.reader.read { db in
      try MessagesProgressiveViewModel.loadedWindowMetadata(db, peer: .thread(id: 1), messages: rows)
    }
    return MessagesProgressiveViewModel(
      peer: .thread(id: 1), reversed: reversed,
      initialState: .init(messages: rows, loadedWindowMetadata: metadata),
      database: database, publisher: publisher, currentUserId: 1
    )
  }

  func insert(messageID: Int64, randomID: Int64?, out: Bool) async throws -> FullMessage {
    try await database.dbWriter.write { db in
      var message = Message(
        messageId: messageID, randomId: randomID, fromId: out ? 1 : 2,
        date: Date(timeIntervalSince1970: Double(nextMessageID) + 100), text: "New tail message",
        peerUserId: nil, peerThreadId: 1, chatId: 1, out: out,
        status: messageID < 0 ? .sending : .sent
      )
      try message.saveMessage(db)
      let row = try FullMessage.queryRequest(currentUserId: 1)
        .filter(Column("chatId") == 1 && Column("messageId") == messageID).fetchOne(db)
      return try #require(row)
    }
  }
}
