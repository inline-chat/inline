import Foundation
import GRDB
import InlineProtocol
import Testing
@testable import InlineKit

@Suite("First-message history timestamp reconciliation")
struct FirstMessageHistoryTimestampRegressionTests {
  @Test("A delayed ID receipt followed by history reload keeps the first canonical row",
        arguments: [false, true], [false, true])
  @MainActor
  func delayedReceiptAcrossFirstHistoryPage(reversed: Bool, admitHistory: Bool) async throws {
    let fixture = try await FirstMessageTimestampFixture()
    // The actual new-thread route admits the pending write before cold navigation.
    // Use the cold production constructor, not an injected preloaded row or hole state.
    let model = fixture.model(reversed: reversed)
    defer { model.dispose() }
    #expect(model.messages.map(\.id) == [fixture.pending.id])
    #expect(model.messages.first?.message.messageId == -123)
    #expect(!model.historyCoverage.isAtCertifiedLiveEnd)
    model.setAtBottom(false)

    // Capture the ID receipt's database payload before the first history writer.
    // MessagesPublisher.messageUpdated suspends after its read before publishing;
    // this explicit delivery order models that supported asynchronous interval.
    let capturedReceipt = try await fixture.confirm()
    #expect(capturedReceipt.id == fixture.pending.id)
    #expect(capturedReceipt.message.date == fixture.pending.message.date)
    if admitHistory { try await fixture.admitFirstHistoryPage() }
    fixture.publish(capturedReceipt)
    #expect(model.messages.first?.message.messageId == 1)
    #expect(model.messages.first?.message.date == fixture.pending.message.date)
    #expect(model.historyCoverage.isAtCertifiedLiveEnd == admitHistory)

    let canonical = try await fixture.canonical()
    #expect(canonical.id == fixture.pending.id)
    #expect(canonical.message.date == (admitHistory ? fixture.serverDate : fixture.pending.message.date))
    try await fixture.reload(model)
    #expect(model.messages.map(\.id) == [canonical.id])
    #expect(model.messages.first?.message.messageId == 1)
    #expect(model.messages.first?.message.status == .sent)
    #expect(model.messages.first?.message.date == canonical.message.date)

    // An eventual update must not be relied upon to repopulate an emptied model.
    fixture.publish(canonical)
    #expect(model.messages.map(\.id) == [canonical.id])
    #expect(model.messages.first?.message.messageId == 1)
    let persisted = try await fixture.canonical()
    #expect(persisted.id == canonical.id)
  }

  @Test("A certified range reload still removes the shown far side of a sparse gap", arguments: [false, true])
  @MainActor
  func certifiedSparseGapKeepsProjectionAuthority(reversed: Bool) async throws {
    let fixture = try await FirstMessageTimestampFixture()
    let model = fixture.model(reversed: reversed)
    defer { model.dispose() }
    let receipt = try await fixture.confirm()
    fixture.publish(receipt)
    for id in Int64(100) ... 102 {
      let incoming = try await fixture.incoming(id: id)
      fixture.publisher.messageAddedSync(fullMessage: incoming, peer: .thread(id: 1))
    }
    let pending = try await fixture.nextPending()
    fixture.publisher.messageAddedSync(fullMessage: pending, peer: .thread(id: 1))
    let beforeIDs: [Int64] = [1, 100, 101, 102, -456]
    #expect(model.messages.map(\.message.messageId) == (reversed ? Array(beforeIDs.reversed()) : beforeIDs))
    #expect(!model.historyCoverage.isAtCertifiedLiveEnd)

    // Full latest page certifies only 100...tail: 1...99 remains unknown.
    // Refresh via a captured live row; do not inject a metadata/tail boolean.
    let capturedLiveRow = try await fixture.row(id: 102)
    try await fixture.admitTailHistoryPage()
    fixture.publish(capturedLiveRow)
    model.setAtBottom(false)
    #expect(model.historyCoverage.isAtCertifiedLiveEnd)
    #expect(!model.historyCoverage.isCertifiedContinuation(between: 1, and: 100))
    #expect(!model.historyCoverage.isCertifiedMessage(1))
    #expect(model.historyCoverage.isCertifiedMessage(100))
    #expect(model.historyCoverage.certifiedReadMaxID(after: 0, through: 102) == nil)
    try await fixture.reload(model)

    let afterIDs: [Int64] = [100, 101, 102, -456]
    #expect(model.messages.map(\.message.messageId) == (reversed ? Array(afterIDs.reversed()) : afterIDs))
    #expect(model.messages.first(where: { $0.message.messageId == -456 })?.id == pending.id)
    #expect(model.messages.first(where: { $0.message.messageId == 1 }) == nil)
    #expect(!model.historyCoverage.isCertifiedContinuation(between: 1, and: 100))
    #expect(model.historyCoverage.certifiedReadMaxID(after: 0, through: 102) == nil)
    let canonicalOld = try await fixture.canonical()
    #expect(canonicalOld.id == receipt.id)
    try await fixture.database.reader.read { db in
      for scope in MessageHistoryScope.allCases {
        let holes = try MessageHistoryCoverageStore.holes(db, chatId: 1, scope: scope)
        #expect(holes == [MessageHistoryHole(chatId: 1, scope: scope, lowerId: 1, upperId: 99)])
      }
    }
  }

  @Test("A canonical deletion is not resurrected while preserving a shown identity", arguments: [false, true])
  @MainActor
  func deletedCanonicalRowStaysDeleted(reversed: Bool) async throws {
    let fixture = try await FirstMessageTimestampFixture()
    let model = fixture.model(reversed: reversed)
    defer { model.dispose() }
    model.setAtBottom(false)
    let capturedReceipt = try await fixture.confirm()
    try await fixture.admitFirstHistoryPage()
    fixture.publish(capturedReceipt)
    #expect(model.messages.map(\.id) == [fixture.pending.id])
    #expect(model.historyCoverage.isAtCertifiedLiveEnd)
    try await fixture.database.dbWriter.write { db in
      try Message.deleteMessages(db, messageIds: [1], chatId: 1)
    }
    try await fixture.reload(model)
    #expect(model.messages.isEmpty)
    let persisted = try await fixture.database.reader.read { db in
      try Message.fetchCount(db)
    }
    #expect(persisted == 0)
  }
}

@MainActor
private final class FirstMessageTimestampFixture {
  let database: AppDatabase
  let publisher: MessagesPublisher
  let pending: FullMessage
  let serverDate = Date(timeIntervalSince1970: 1_000)

  init() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    database = try AppDatabase(queue)
    publisher = MessagesPublisher(database: database)
    pending = try await queue.write { db in
      try User(id: 1, email: nil, firstName: "Fixture sender").insert(db)
      try Chat(id: 1, date: Date(timeIntervalSince1970: 1), type: .thread,
               title: "First-message fixture", spaceId: nil).insert(db)
      var message = Message(messageId: -123, randomId: 123, fromId: 1,
                            date: Date(timeIntervalSince1970: 1_000.875), text: "Fixture first message",
                            peerUserId: nil, peerThreadId: 1, chatId: 1, out: true, status: .sending)
      try message.saveMessage(db)
      try Chat.updateLastMsgId(db, chatId: 1, lastMsgId: message.messageId, date: message.date)
      let row = try FullMessage.queryRequest(currentUserId: 1)
        .filter(Column("chatId") == 1 && Column("messageId") == -123).fetchOne(db)
      return try #require(row)
    }
  }

  func model(reversed: Bool) -> MessagesProgressiveViewModel {
    MessagesProgressiveViewModel(peer: .thread(id: 1), reversed: reversed,
                                 database: database, publisher: publisher, currentUserId: 1)
  }

  func confirm() async throws -> FullMessage {
    try await database.dbWriter.write { db in
      let update = InlineProtocol.UpdateMessageId.with { $0.randomID = 123; $0.messageID = 1 }
      try update.apply(db, currentUserId: 1)
      let row = try FullMessage.queryRequest(currentUserId: 1)
        .filter(Column("chatId") == 1 && Column("messageId") == 1).fetchOne(db)
      return try #require(row)
    }
  }

  func admitFirstHistoryPage() async throws {
    try await database.dbWriter.write { db in
      var transaction = GetChatHistoryTransaction(peer: .thread(id: 1), mode: .historyModeLatest, limit: 60)
      transaction.context.admissionToken = try HistoryPageAdmissionToken.capture(db, chatId: 1)
      try DbBucketState(bucketType: 1, entityId: -1, date: 1_000, seq: 2).save(db)
      let result = InlineProtocol.GetChatHistoryResult.with {
        $0.seq = 2
        $0.messages = [.with {
          $0.id = 1; $0.chatID = 1; $0.fromID = 1
          $0.peerID = .with { $0.chat.chatID = 1 }
          $0.date = 1_000; $0.message = "Fixture first message"; $0.out = true
        }]
      }
      try GetChatHistoryTransaction.apply(result, context: transaction.context, db: db)
    }
  }

  func incoming(id: Int64) async throws -> FullMessage {
    try await database.dbWriter.write { db in
      let update = InlineProtocol.UpdateNewMessage.with {
        $0.message = .with {
          $0.id = id; $0.chatID = 1; $0.fromID = 1
          $0.peerID = .with { $0.chat.chatID = 1 }
          $0.date = 1_000 + id; $0.message = "Fixture live row"; $0.out = true
        }
      }
      try update.apply(db, publishChanges: false, suppressNotifications: true,
                       materializeMissingReferences: true, incrementUnreadCount: false)
      let row = try FullMessage.queryRequest(currentUserId: 1)
        .filter(Column("chatId") == 1 && Column("messageId") == id).fetchOne(db)
      return try #require(row)
    }
  }

  func nextPending() async throws -> FullMessage {
    try await database.dbWriter.write { db in
      var message = Message(messageId: -456, randomId: 456, fromId: 1,
                            date: Date(timeIntervalSince1970: 1_200.875), text: "Fixture next pending",
                            peerUserId: nil, peerThreadId: 1, chatId: 1, out: true, status: .sending)
      try message.saveMessage(db)
      let row = try FullMessage.queryRequest(currentUserId: 1)
        .filter(Column("chatId") == 1 && Column("messageId") == -456).fetchOne(db)
      return try #require(row)
    }
  }

  func row(id: Int64) async throws -> FullMessage {
    try await database.reader.read { db in
      let row = try FullMessage.queryRequest(currentUserId: 1)
        .filter(Column("chatId") == 1 && Column("messageId") == id).fetchOne(db)
      return try #require(row)
    }
  }

  func admitTailHistoryPage() async throws {
    try await database.dbWriter.write { db in
      try DbBucketState(bucketType: 1, entityId: -1, date: 1_102, seq: 6).save(db)
      var transaction = GetChatHistoryTransaction(peer: .thread(id: 1), mode: .historyModeLatest, limit: 3)
      transaction.context.admissionToken = try HistoryPageAdmissionToken.capture(db, chatId: 1)
      let result = InlineProtocol.GetChatHistoryResult.with {
        $0.seq = 6
        $0.messages = [Int64(102), 101, 100].map { id in
          .with {
            $0.id = id; $0.chatID = 1; $0.fromID = 1
            $0.peerID = .with { $0.chat.chatID = 1 }
            $0.date = 1_000 + id; $0.message = "Fixture live row"; $0.out = true
          }
        }
      }
      try GetChatHistoryTransaction.apply(result, context: transaction.context, db: db)
    }
  }

  func canonical() async throws -> FullMessage {
    try await database.reader.read { db in
      let row = try FullMessage.queryRequest(currentUserId: 1)
        .filter(Column("chatId") == 1 && Column("messageId") == 1).fetchOne(db)
      return try #require(row)
    }
  }

  func publish(_ row: FullMessage) {
    publisher.publisher.send(.update(.init(message: row, animated: false, peer: .thread(id: 1))))
  }

  func reload(_ model: MessagesProgressiveViewModel) async throws {
    var didReload = false
    model.observe { if case .reload = $0 { didReload = true } }
    publisher.messagesReload(peer: .thread(id: 1), animated: false)
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !didReload && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(didReload)
  }
}
