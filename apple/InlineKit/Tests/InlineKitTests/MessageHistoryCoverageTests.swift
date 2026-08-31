import Foundation
import GRDB
import InlineProtocol
import RealtimeV2
import Testing

@testable import InlineKit

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

  @Test("only GET_CHAT_HISTORY results certify numeric coverage")
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
      let transaction = GetChatHistoryTransaction(
        peer: .thread(id: 7),
        mode: .historyModeLatest,
        limit: 100
      )
      try GetChatHistoryTransaction.apply(response, context: transaction.context, db: db)

      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7) == [
        MessageHistoryHole(chatId: 7, lowerId: 1, upperId: 49),
      ])
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
    let transaction = GetChatHistoryTransaction(
      peer: .thread(id: 7),
      mode: .historyModeLatest,
      limit: 100
    )
    let invalidResponse = response
    let context = transaction.context

    #expect(throws: TransactionExecutionError.self) {
      try queue.write { (db: Database) throws in
        try GetChatHistoryTransaction.apply(invalidResponse, context: context, db: db)
      }
    }

    let (messageCount, holes) = try await queue.read { (db: Database) throws in
      (
        try Message.fetchCount(db),
        try MessageHistoryCoverageStore.holes(db, chatId: 7)
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
      40 ... MessageHistoryHole.positiveMessageIDMax)

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
      peer: .thread(id: 7), mode: .historyModeAround, anchorID: 50, limit: 4
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
