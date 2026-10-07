import Foundation
import GRDB
@testable import InlineKit
import InlineProtocol
import RealtimeV2
import Testing

@Suite("Durable message history coverage")
struct MessageHistoryCoverageTests {
  @Test("new chats start unknown and proven ranges split holes")
  func subtractsProvenCoverage() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)

    try await queue.write { (db: Database) throws in
      try Chat(
        id: 7,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Coverage",
        spaceId: nil
      ).insert(db)

      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7) == [
        MessageHistoryHole(chatId: 7, lowerId: 1, upperId: MessageHistoryHole.positiveMessageIDMax),
      ])

      try MessageHistoryCoverageStore.subtract(db, chatId: 7, lowerId: 20, upperId: 40)
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7) == [
        MessageHistoryHole(chatId: 7, lowerId: 1, upperId: 19),
        MessageHistoryHole(chatId: 7, lowerId: 41, upperId: MessageHistoryHole.positiveMessageIDMax),
      ])
      #expect(try MessageHistoryCoverageStore.intersects(db, chatId: 7, lowerId: 25, upperId: 30) == false)
      #expect(try MessageHistoryCoverageStore.intersects(db, chatId: 7, lowerId: 18, upperId: 22))

      try MessageHistoryCoverageStore.subtract(db, chatId: 7, lowerId: 1, upperId: 60)
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7) == [
        MessageHistoryHole(chatId: 7, lowerId: 61, upperId: MessageHistoryHole.positiveMessageIDMax),
      ])
    }
  }

  @Test("ordinary pages prove every fixed tag scope")
  func historyResultClosesCoverage() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)

    try await queue.write { (db: Database) throws in
      try User(id: 1, email: "history@example.com", firstName: "History").insert(db)
      try Chat(
        id: 7,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Coverage",
        spaceId: nil,
        lastMsgId: 50
      ).insert(db)

      // A chat-list last message is data, not proof that the surrounding range was fetched.
      var cached = Message(
        messageId: 50,
        fromId: 1,
        date: Date(timeIntervalSince1970: 2),
        text: "cached",
        peerUserId: nil,
        peerThreadId: 7,
        chatId: 7
      )
      try cached.saveMessage(db)
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7).count == 1)

      var protocolMessage = InlineProtocol.Message()
      protocolMessage.id = 50
      protocolMessage.chatID = 7
      protocolMessage.fromID = 1
      protocolMessage.date = 2
      protocolMessage.message = "authoritative"
      protocolMessage.peerID = .with { $0.chat.chatID = 7 }
      var response = InlineProtocol.GetChatHistoryResult()
      response.messages = [protocolMessage]
      var transaction = GetChatHistoryTransaction(
        peer: .thread(id: 7),
        mode: .historyModeLatest,
        limit: 100
      )
      transaction.context.admissionToken = try HistoryPageAdmissionToken.capture(db, chatId: 7)
      response.seq = 0
      try GetChatHistoryTransaction.apply(response, context: transaction.context, db: db)

      for scope in MessageHistoryScope.allCases {
        #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7, scope: scope).isEmpty)
      }
    }
  }

  @Test("empty directional pages prove their complete numeric side")
  func emptyDirectionalCoverage() {
    let older = GetChatHistoryTransaction(
      peer: .thread(id: 7),
      mode: .historyModeOlder,
      beforeID: 50,
      limit: 100
    )
    #expect(GetChatHistoryTransaction.provenCoverage(context: older.context, messageIDs: []) == 1 ... 49)

    let newer = GetChatHistoryTransaction(
      peer: .thread(id: 7),
      mode: .historyModeNewer,
      afterID: 50,
      limit: 100
    )
    #expect(
      GetChatHistoryTransaction.provenCoverage(context: newer.context, messageIDs: []) ==
        51 ... MessageHistoryHole.positiveMessageIDMax
    )
  }

  @Test("matching released older cursors admit coverage while contradictory cursors cannot")
  func matchingOlderCursorCompatibility() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    try await queue.write { (db: Database) throws in
      try User(id: 1, email: nil, firstName: "History").insert(db)
      try Chat(id: 7, date: Date(timeIntervalSince1970: 1), type: .thread, title: "Coverage", spaceId: nil).insert(db)
      var transaction = GetChatHistoryTransaction(peer: .thread(id: 7), offsetID: 10, limit: 3)
      transaction.context.beforeID = 10
      transaction.context.admissionToken = try HistoryPageAdmissionToken.capture(db, chatId: 7)
      let page = InlineProtocol.GetChatHistoryResult.with {
        $0.seq = 0
        $0.messages = [9, 8, 7].map { id in
          .with {
            $0.id = Int64(id)
            $0.chatID = 7
            $0.fromID = 1
            $0.peerID = .with { $0.chat.chatID = 7 }
            $0.date = Int64(id)
          }
        }
      }
      try GetChatHistoryTransaction.apply(page, context: transaction.context, db: db)
      #expect(try Message.fetchCount(db) == 3)
      #expect(try MessageHistoryCoverageStore.intersects(db, chatId: 7, lowerId: 7, upperId: 9) == false)
      transaction.context.beforeID = 8
      #expect(GetChatHistoryTransaction.provenCoverages(context: transaction.context, messageIDs: [7]) == nil)
    }
  }

  @Test("non-positive message IDs reject the page without partial writes")
  func invalidMessageIDRollsBackPage() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)

    try await queue.write { (db: Database) throws in
      try User(id: 1, email: "history@example.com", firstName: "History").insert(db)
      try Chat(
        id: 7,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Coverage",
        spaceId: nil
      ).insert(db)
    }

    var valid = InlineProtocol.Message()
    valid.id = 50
    valid.chatID = 7
    valid.fromID = 1
    valid.date = 2
    valid.message = "valid"
    valid.peerID = .with { $0.chat.chatID = 7 }
    var invalid = valid
    invalid.id = 0
    var response = InlineProtocol.GetChatHistoryResult()
    response.messages = [valid, invalid]
    var transaction = GetChatHistoryTransaction(
      peer: .thread(id: 7),
      mode: .historyModeLatest,
      limit: 100
    )
    transaction.context.admissionToken = try await queue.read { try HistoryPageAdmissionToken.capture($0, chatId: 7) }
    response.seq = 0
    let invalidResponse = response
    let context = transaction.context

    #expect(throws: HistoryPageAdmissionError.self) {
      try queue.write { (db: Database) throws in
        try GetChatHistoryTransaction.apply(invalidResponse, context: context, db: db)
      }
    }

    let (messageCount, holes) = try await queue.read { (db: Database) throws in
      try (
        Message.fetchCount(db),
        MessageHistoryCoverageStore.holes(db, chatId: 7)
      )
    }
    #expect(messageCount == 0)
    #expect(holes == [
      MessageHistoryHole(chatId: 7, lowerId: 1, upperId: MessageHistoryHole.positiveMessageIDMax),
    ])
  }

  @Test("malformed directional pages do not certify coverage")
  func rejectsMalformedDirectionalCoverage() {
    let older = GetChatHistoryTransaction(
      peer: .thread(id: 7),
      mode: .historyModeOlder,
      beforeID: 50,
      limit: 100
    )
    #expect(GetChatHistoryTransaction.provenCoverage(context: older.context, messageIDs: [55]) == nil)

    let newer = GetChatHistoryTransaction(
      peer: .thread(id: 7),
      mode: .historyModeNewer,
      afterID: 50,
      limit: 100
    )
    #expect(GetChatHistoryTransaction.provenCoverage(context: newer.context, messageIDs: [45]) == nil)
    #expect(GetChatHistoryTransaction.provenCoverage(
      context: newer.context,
      messageIDs: [MessageHistoryHole.positiveMessageIDMax + 1]
    ) == nil)
  }

  @Test("latest certifies its tail and around coverage includes a deleted anchor")
  func nonEmptyCoverageExtrema() {
    let latest = GetChatHistoryTransaction(
      peer: .thread(id: 7),
      mode: .historyModeLatest,
      limit: 100
    )
    #expect(GetChatHistoryTransaction.provenCoverage(context: latest.context, messageIDs: [50, 40]) ==
      1 ... MessageHistoryHole.positiveMessageIDMax)

    let around = GetChatHistoryTransaction(
      peer: .thread(id: 7),
      mode: .historyModeAround,
      anchorID: 50,
      limit: 100
    )
    #expect(GetChatHistoryTransaction.provenCoverage(context: around.context, messageIDs: [60, 40]) ==
      1 ... MessageHistoryHole.positiveMessageIDMax)
    #expect(GetChatHistoryTransaction.provenCoverage(context: around.context, messageIDs: [40, 45]) ==
      1 ... MessageHistoryHole.positiveMessageIDMax)
    #expect(GetChatHistoryTransaction.provenCoverage(context: around.context, messageIDs: [55, 60]) ==
      1 ... MessageHistoryHole.positiveMessageIDMax)

    let fullWindow = GetChatHistoryTransaction(
      peer: .thread(id: 7), mode: .historyModeAround, anchorID: 50, limit: 5,
      beforeLimit: 2, afterLimit: 2
    )
    #expect(GetChatHistoryTransaction.provenCoverage(context: fullWindow.context, messageIDs: [40, 45, 55, 60]) ==
      40 ... 60)
    #expect(GetChatHistoryTransaction.provenCoverage(context: fullWindow.context, messageIDs: []) ==
      1 ... MessageHistoryHole.positiveMessageIDMax)
  }

  @Test("overlapping and adjacent persisted holes normalize during subtraction")
  func normalizesPersistedIntervals() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)

    try await queue.write { (db: Database) throws in
      try Chat(
        id: 7,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Coverage",
        spaceId: nil
      ).insert(db)
      try MessageHistoryHole.filter(MessageHistoryHole.Columns.chatId == 7).deleteAll(db)
      try MessageHistoryHole(chatId: 7, lowerId: 1, upperId: 10).insert(db)
      try MessageHistoryHole(chatId: 7, lowerId: 5, upperId: 20).insert(db)
      try MessageHistoryHole(chatId: 7, lowerId: 21, upperId: 30).insert(db)

      try MessageHistoryCoverageStore.subtract(db, chatId: 7, lowerId: 8, upperId: 22)
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7) == [
        MessageHistoryHole(chatId: 7, lowerId: 1, upperId: 7),
        MessageHistoryHole(chatId: 7, lowerId: 23, upperId: 30),
      ])
    }
  }

  @Test("new-chat trigger seeds coverage and chat deletion cascades it")
  func triggerAndCascade() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)

    try await queue.write { (db: Database) throws in
      try Chat(
        id: 7,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Coverage",
        spaceId: nil
      ).insert(db)
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7).count == 1)
      try Chat.deleteOne(db, id: 7)
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7).isEmpty)
    }
  }
}
