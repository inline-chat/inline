import GRDB
import InlineProtocol
import RealtimeV2
import Testing

@testable import InlineKit

@Suite("GetChats snapshot")
struct GetChatsSnapshotTests {
  private func makeInMemoryDB() throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    return queue
  }

  @Test("child chats import even when they precede their parents")
  func unorderedParentChatsImportDependencyFirst() throws {
    let queue = try makeInMemoryDB()
    var result = InlineProtocol.GetChatsResult()
    result.chats = [
      makeChat(id: 11, parentChatID: 10, seq: 11),
      makeChat(id: 10, seq: 10),
    ]

    try queue.write { db in
      let imported = try GetChatsTransaction.applySnapshot(result, in: db)

      #expect(imported.failures.isEmpty)
      #expect(imported.bucketStates.count == 2)
      #expect(try Chat.fetchCount(db) == 2)
      #expect(try Chat.fetchOne(db, key: 11)?.parentChatId == 10)
      #expect(try DbBucketState.fetchCount(db) == 2)
    }
  }

  @Test("missing and cyclic chat parents skip only their dependent chats")
  func unavailableParentsDoNotEraseHealthyChats() throws {
    let queue = try makeInMemoryDB()
    var result = InlineProtocol.GetChatsResult()
    result.chats = [
      makeChat(id: 10, seq: 10),
      makeChat(id: 20, parentChatID: 999, seq: 20),
      makeChat(id: 21, parentChatID: 20, seq: 21),
      makeChat(id: 30, parentChatID: 31, seq: 30),
      makeChat(id: 31, parentChatID: 30, seq: 31),
    ]

    try queue.write { db in
      let imported = try GetChatsTransaction.applySnapshot(result, in: db)

      #expect(failureCount(in: imported, phase: .chats) == 4)
      #expect(try Chat.fetchAll(db).map(\.id) == [10])
      #expect(imported.bucketStates.count == 1)
      #expect(try DbBucketState.fetchCount(db) == 1)
    }
  }

  @Test("record failures are isolated across every snapshot phase")
  func rejectedRecordsDoNotRollBackHealthySiblings() throws {
    let queue = try makeInMemoryDB()
    try queue.writeWithoutTransaction { db in
      try installRejectingTriggers(db)
    }

    var result = InlineProtocol.GetChatsResult()
    result.spaces = [makeSpace(id: 1, seq: 7), makeSpace(id: 2, seq: 8)]
    result.users = [makeUser(id: 1), makeUser(id: 2)]
    result.chats = [makeChat(id: 10, seq: 10), makeChat(id: 20, seq: 20)]
    result.messages = [
      makeMessage(id: 1, chatID: 10, fromID: 1),
      makeMessage(id: 2, chatID: 20, fromID: 1),
    ]
    result.dialogs = [makeDialog(chatID: 10), makeDialog(chatID: 20)]

    try queue.write { db in
      let imported = try GetChatsTransaction.applySnapshot(result, in: db)

      #expect(failureCount(in: imported, phase: .spaces) == 1)
      #expect(failureCount(in: imported, phase: .users) == 1)
      #expect(failureCount(in: imported, phase: .messages) == 1)
      #expect(failureCount(in: imported, phase: .dialogs) == 1)
      #expect(try Space.fetchAll(db).map(\.id) == [1])
      #expect(try User.fetchAll(db).map(\.id) == [1])
      #expect(try Chat.fetchAll(db).map(\.id) == [10, 20])
      #expect(try Message.fetchAll(db).map(\.messageId) == [1])
      #expect(try Dialog.fetchAll(db).compactMap(\.peerThreadId) == [10])
      #expect(imported.bucketStates.count == 2)
      #expect(try DbBucketState.fetchCount(db) == 2)
    }
  }

  @Test("missing last messages leave chats usable and cursors unadvanced")
  func missingLastMessagesDoNotRejectChats() throws {
    let queue = try makeInMemoryDB()
    var goodChat = makeChat(id: 10, seq: 10)
    goodChat.lastMsgID = 1
    var incompleteChat = makeChat(id: 20, seq: 20)
    incompleteChat.lastMsgID = 99

    var result = InlineProtocol.GetChatsResult()
    result.users = [makeUser(id: 1)]
    result.chats = [goodChat, incompleteChat]
    result.messages = [makeMessage(id: 1, chatID: 10, fromID: 1)]

    try queue.write { db in
      let imported = try GetChatsTransaction.applySnapshot(result, in: db)

      #expect(failureCount(in: imported, phase: .lastMessages) == 1)
      #expect(try Chat.fetchOne(db, key: 10)?.lastMsgId == 1)
      #expect(try Chat.fetchOne(db, key: 20)?.lastMsgId == nil)
      #expect(imported.bucketStates.count == 1)
      #expect(try DbBucketState.fetchCount(db) == 1)
    }
  }

  @Test("invalid peers are reported instead of reaching fatal model initializers")
  func invalidPeersAreSkipped() throws {
    let queue = try makeInMemoryDB()
    var invalidChat = InlineProtocol.Chat()
    invalidChat.id = 20
    invalidChat.seq = 20

    var invalidMessage = InlineProtocol.Message()
    invalidMessage.id = 1
    invalidMessage.chatID = 10

    var result = InlineProtocol.GetChatsResult()
    result.chats = [makeChat(id: 10, seq: 10), invalidChat]
    result.messages = [invalidMessage]
    result.dialogs = [makeDialog(chatID: 10), InlineProtocol.Dialog()]

    try queue.write { db in
      let imported = try GetChatsTransaction.applySnapshot(result, in: db)

      #expect(failureCount(in: imported, phase: .chats) == 1)
      #expect(failureCount(in: imported, phase: .messages) == 1)
      #expect(failureCount(in: imported, phase: .dialogs) == 1)
      #expect(try Chat.fetchAll(db).map(\.id) == [10])
      #expect(try Dialog.fetchCount(db) == 1)
      #expect(try Message.fetchCount(db) == 0)
      #expect(imported.bucketStates.isEmpty)
    }
  }

  @Test("database infrastructure errors remain transaction-fatal")
  func infrastructureErrorsAreNotClassifiedAsBadRecords() throws {
    let foreignKey = DatabaseError(resultCode: .SQLITE_CONSTRAINT_FOREIGNKEY)
    #expect(GetChatsTransaction.isRecoverableRecordError(foreignKey))

    let busy = DatabaseError(resultCode: .SQLITE_BUSY)
    #expect(!GetChatsTransaction.isRecoverableRecordError(busy))

    struct ProgrammingError: Error {}
    #expect(!GetChatsTransaction.isRecoverableRecordError(ProgrammingError()))
  }

  @Test("snapshot installs resource cursors without regressing newer state")
  func snapshotSeedsMonotonicCursors() throws {
    let queue = try makeInMemoryDB()
    var result = InlineProtocol.GetChatsResult()
    result.spaces = [makeSpace(id: 1, seq: 7)]
    result.chats = [makeChat(id: 2, spaceID: 1, seq: 9)]

    try queue.write { db in
      _ = try GetChatsTransaction.applySnapshot(result, in: db)
      _ = try GRDBSyncStorage.seedSnapshotBucketState(for: .space(id: 1), seq: 6, in: db)
      _ = try GRDBSyncStorage.seedSnapshotBucketState(for: .chat(peer: makeChatPeer(id: 2)), seq: 8, in: db)

      let cursors = try DbBucketState.fetchAll(db)
      #expect(cursors.count == 2)
      #expect(cursors.first(where: { $0.bucketType == 3 })?.seq == 7)
      #expect(cursors.first(where: { $0.bucketType == 1 })?.seq == 9)
    }
  }

  private func installRejectingTriggers(_ db: Database) throws {
    try db.execute(sql: """
      CREATE TRIGGER reject_test_space BEFORE INSERT ON space
      WHEN NEW.id = 2 BEGIN SELECT RAISE(ABORT, 'reject test space'); END;
      CREATE TRIGGER reject_test_user BEFORE INSERT ON user
      WHEN NEW.id = 2 BEGIN SELECT RAISE(ABORT, 'reject test user'); END;
      CREATE TRIGGER reject_test_message BEFORE INSERT ON message
      WHEN NEW.messageId = 2 BEGIN SELECT RAISE(ABORT, 'reject test message'); END;
      CREATE TRIGGER reject_test_dialog BEFORE INSERT ON dialog
      WHEN NEW.peerThreadId = 20 BEGIN SELECT RAISE(ABORT, 'reject test dialog'); END;
      """)
  }

  private func failureCount(
    in result: GetChatsTransaction.SnapshotImportResult,
    phase: GetChatsTransaction.SnapshotImportPhase
  ) -> Int {
    result.failures.first { $0.phase == phase }?.count ?? 0
  }

  private func makeSpace(id: Int64, seq: Int32) -> InlineProtocol.Space {
    var space = InlineProtocol.Space()
    space.id = id
    space.name = "Space \(id)"
    space.date = 100
    space.seq = seq
    return space
  }

  private func makeUser(id: Int64) -> InlineProtocol.User {
    var user = InlineProtocol.User()
    user.id = id
    user.firstName = "User \(id)"
    return user
  }

  private func makeChat(
    id: Int64,
    spaceID: Int64? = nil,
    parentChatID: Int64? = nil,
    seq: Int32
  ) -> InlineProtocol.Chat {
    var chat = InlineProtocol.Chat()
    chat.id = id
    chat.title = "Chat \(id)"
    chat.date = 100
    if let spaceID { chat.spaceID = spaceID }
    if let parentChatID { chat.parentChatID = parentChatID }
    chat.peerID = makeChatPeer(id: id)
    chat.seq = seq
    return chat
  }

  private func makeMessage(
    id: Int64,
    chatID: Int64,
    fromID: Int64
  ) -> InlineProtocol.Message {
    var message = InlineProtocol.Message()
    message.id = id
    message.chatID = chatID
    message.fromID = fromID
    message.date = 100
    message.peerID = makeChatPeer(id: chatID)
    message.message = "test"
    return message
  }

  private func makeDialog(chatID: Int64) -> InlineProtocol.Dialog {
    var dialog = InlineProtocol.Dialog()
    dialog.peer = makeChatPeer(id: chatID)
    dialog.chatID = chatID
    return dialog
  }

  private func makeChatPeer(id: Int64) -> InlineProtocol.Peer {
    .with { $0.chat.chatID = id }
  }
}
