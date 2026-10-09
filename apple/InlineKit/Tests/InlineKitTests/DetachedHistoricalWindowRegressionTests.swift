import Foundation
import GRDB
import InlineProtocol
import Testing
@testable import InlineKit

@Suite("Detached historical window regressions")
struct DetachedHistoricalWindowRegressionTests {
  @Test("A historical component stays separate from newer cached rows across an unknown gap")
  @MainActor
  func detachedHistoricalWindowDoesNotFollowTheCachedTail() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let publisher = MessagesPublisher(database: database)
    let rows = try await queue.write { db in
      try User(id: 1, email: nil, firstName: "Historical sender").insert(db)
      try Chat(id: 1, date: Date(timeIntervalSince1970: 1), type: .thread,
               title: "Detached historical fixture", spaceId: nil).insert(db)
      var latest = GetChatHistoryTransaction(peer: .thread(id: 1), mode: .historyModeLatest, limit: 1)
      latest.context.admissionToken = try HistoryPageAdmissionToken.capture(db, chatId: 1)
      let tail = InlineProtocol.GetChatHistoryResult.with {
        $0.seq = 0
        $0.messages = [historicalProtocolMessage(100)]
      }
      try GetChatHistoryTransaction.apply(tail, context: latest.context, db: db)
      var older = GetChatHistoryTransaction(peer: .thread(id: 1), mode: .historyModeOlder, beforeID: 21, limit: 20)
      older.context.admissionToken = try HistoryPageAdmissionToken.capture(db, chatId: 1)
      let oldPage = InlineProtocol.GetChatHistoryResult.with {
        $0.seq = 0
        $0.messages = (Int64(1) ... 20).reversed().map(historicalProtocolMessage)
      }
      try GetChatHistoryTransaction.apply(oldPage, context: older.context, db: db)
      #expect(try MessageHistoryCoverageStore.intersects(db, chatId: 1, lowerId: 21, upperId: 99))
      return try FullMessage.queryRequest(currentUserId: 1)
        .filter(Column("chatId") == 1 && Column("messageId") >= 10 && Column("messageId") <= 20)
        .order(Column("messageId").asc).fetchAll(db)
    }
    let metadata = try await database.reader.read { db in
      try MessagesProgressiveViewModel.loadedWindowMetadata(db, peer: .thread(id: 1), messages: rows)
    }
    // The model cannot page across the hole even though a newer canonical row
    // is known. That should not turn this historical window into a live one.
    #expect(!metadata.canLoadNewerFromLocal)
    #expect(!metadata.historyCoverage.isAtCertifiedLiveEnd)
    let model = MessagesProgressiveViewModel(
      peer: .thread(id: 1), initialState: .init(messages: rows, loadedWindowMetadata: metadata),
      database: database, publisher: publisher, currentUserId: 1
    )
    defer { model.dispose() }
    model.setAtBottom(false)
    model.setHistoryAnchor(10)
    let incoming = try await database.dbWriter.write { db -> FullMessage in
      var message = Message(messageId: 101, fromId: 1, date: Date(timeIntervalSince1970: 101),
                            text: "Newer cached incoming", peerUserId: nil, peerThreadId: 1, chatId: 1)
      try message.saveMessage(db)
      let row = try FullMessage.queryRequest(currentUserId: 1)
        .filter(Column("chatId") == 1 && Column("messageId") == 101).fetchOne(db)
      return try #require(row)
    }
    publisher.publisher.send(.add(.init(messages: [incoming], peer: .thread(id: 1))))
    #expect(model.messages.map(\.message.messageId) == Array(Int64(10) ... 20))

    var reloaded = false
    model.observe { if case .reload = $0 { reloaded = true } }
    publisher.messagesReload(peer: .thread(id: 1), animated: false)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !reloaded, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(reloaded)
    let visible = model.messages.map(\.message.messageId)
    #expect(visible.contains(10))
    #expect(Set(Int64(10) ... 20).isSubset(of: Set(visible)))
    #expect(visible.allSatisfy { (1 ... 20).contains($0) })
    #expect(!visible.contains(100))
    #expect(!visible.contains(101))
    #expect(!model.canLoadNewerFromLocal)
    #expect(!model.historyCoverage.isAtCertifiedLiveEnd)
    #expect(!model.historyCoverage.isCertifiedContinuation(between: 20, and: 100))
    #expect(model.historyCoverage.certifiedReadMaxID(after: 20, through: 101) == nil)
    let canonical = try await database.reader.read { db -> [Int64] in
      #expect(try MessageHistoryCoverageStore.intersects(db, chatId: 1, lowerId: 21, upperId: 99))
      return try Message.filter(Column("chatId") == 1 && Column("messageId") >= 100)
        .order(Column("messageId").asc).fetchAll(db).map(\.messageId)
    }
    #expect(canonical == [100, 101])
  }
}

private func historicalProtocolMessage(_ id: Int64) -> InlineProtocol.Message {
  .with {
    $0.id = id
    $0.chatID = 1
    $0.fromID = 1
    $0.peerID = .with { $0.chat.chatID = 1 }
    $0.date = id
    $0.message = "Admitted historical row"
  }
}
