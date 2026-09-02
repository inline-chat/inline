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

  @Test("snapshot import failures expose stable Sentry categories")
  func snapshotFailureCategory() {
    let failure = GetChatsTransaction.SnapshotImportFailure(phase: .dialogs, count: 3)
    #expect(failure.privacySafeErrorCategory == "snapshot_import:dialogs")
  }

  @Test("child chats import even when they precede their parents")
  func unorderedParentChatsImportDependencyFirst() throws {
    let queue = try makeInMemoryDB()
    var result = InlineProtocol.GetChatsResult()
    result.chats = [
      makeChat(id: 11, parentChatID: 10, seq: 11),
      makeChat(id: 10, seq: 10),
    ]

    try queue.write { (db: Database) throws in
      let imported = try GetChatsTransaction.applySnapshot(result, in: db)

      #expect(imported.failures.isEmpty)
      #expect(imported.seededStates.count == 2)
      #expect(imported.catchUpTargets.isEmpty)
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

    try queue.write { (db: Database) throws in
      let imported = try GetChatsTransaction.applySnapshot(result, in: db)

      #expect(failureCount(in: imported, phase: .chats) == 4)
      #expect(try Chat.fetchAll(db).map(\.id) == [10])
      #expect(imported.seededStates.count == 1)
      #expect(try DbBucketState.fetchCount(db) == 1)
    }
  }

  @Test("record failures are isolated across every snapshot phase")
  func rejectedRecordsDoNotRollBackHealthySiblings() throws {
    let queue = try makeInMemoryDB()
    try queue.writeWithoutTransaction { (db: Database) throws in
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

    try queue.write { (db: Database) throws in
      let imported = try GetChatsTransaction.applySnapshot(
        result,
        userProjectionAdmission: .alreadyValidated,
        in: db
      )

      #expect(failureCount(in: imported, phase: .spaces) == 1)
      #expect(failureCount(in: imported, phase: .users) == 1)
      #expect(failureCount(in: imported, phase: .messages) == 1)
      #expect(failureCount(in: imported, phase: .dialogs) == 1)
      #expect(try Space.fetchAll(db).map(\.id) == [1])
      #expect(try User.fetchAll(db).map(\.id) == [1])
      #expect(try Chat.fetchAll(db).map(\.id) == [10, 20])
      #expect(try Message.fetchAll(db).map(\.messageId) == [1])
      #expect(try Dialog.fetchAll(db).compactMap(\.peerThreadId) == [10])
      #expect(imported.seededStates.count == 2)
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

    try queue.write { (db: Database) throws in
      let imported = try GetChatsTransaction.applySnapshot(result, in: db)

      #expect(failureCount(in: imported, phase: .lastMessages) == 1)
      #expect(try Chat.fetchOne(db, key: 10)?.lastMsgId == 1)
      #expect(try Chat.fetchOne(db, key: 20)?.lastMsgId == nil)
      #expect(imported.seededStates.count == 1)
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

    try queue.write { (db: Database) throws in
      let imported = try GetChatsTransaction.applySnapshot(
        result,
        userProjectionAdmission: .alreadyValidated,
        in: db
      )

      #expect(failureCount(in: imported, phase: .chats) == 1)
      #expect(failureCount(in: imported, phase: .messages) == 1)
      #expect(failureCount(in: imported, phase: .dialogs) == 1)
      #expect(try Chat.fetchAll(db).map(\.id) == [10])
      #expect(try Dialog.fetchCount(db) == 1)
      #expect(try Message.fetchCount(db) == 0)
      #expect(imported.seededStates.isEmpty)
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

  @Test("pristine child snapshots save models and seed cursors together")
  func pristineChildrenSaveAndSeedTogether() throws {
    let queue = try makeInMemoryDB()
    var result = InlineProtocol.GetChatsResult()
    result.spaces = [makeSpace(id: 1, seq: 7)]
    result.chats = [makeChat(id: 2, spaceID: 1, seq: 9)]

    try queue.write { (db: Database) throws in
      let imported = try GetChatsTransaction.applySnapshot(result, in: db)

      let spaceKey = BucketKey.space(id: 1)
      let chatKey = BucketKey.chat(peer: makeChatPeer(id: 2))
      #expect(try Space.fetchOne(db, key: 1)?.name == "Space 1")
      #expect(try Chat.fetchOne(db, key: 2)?.title == "Chat 2")
      #expect(try bucketState(for: spaceKey, in: db)?.seq == 7)
      #expect(try bucketState(for: chatKey, in: db)?.seq == 9)
      #expect(imported.seededStates[spaceKey]?.seq == 7)
      #expect(imported.seededStates[chatKey]?.seq == 9)
      #expect(imported.catchUpTargets.isEmpty)
    }
  }

  @Test("stale snapshots cannot overlay newer local child models")
  func staleSnapshotsPreserveNewerLocalChildren() throws {
    let queue = try makeInMemoryDB()
    let spaceKey = BucketKey.space(id: 1)
    let chatKey = BucketKey.chat(peer: makeChatPeer(id: 2))

    try queue.write { (db: Database) throws in
      try Space(from: makeSpace(id: 1, seq: 8, name: "Local Space")).save(db)
      try Chat(from: makeChat(id: 2, spaceID: 1, seq: 10, title: "Local Chat")).saveFull(db)
      _ = try GRDBSyncStorage.seedSnapshotBucketState(for: spaceKey, seq: 8, in: db)
      _ = try GRDBSyncStorage.seedSnapshotBucketState(for: chatKey, seq: 10, in: db)

      var result = InlineProtocol.GetChatsResult()
      result.spaces = [makeSpace(id: 1, seq: 7, name: "Stale Space")]
      result.chats = [makeChat(id: 2, spaceID: 1, seq: 9, title: "Stale Chat")]
      let imported = try GetChatsTransaction.applySnapshot(result, in: db)

      #expect(try Space.fetchOne(db, key: 1)?.name == "Local Space")
      #expect(try Chat.fetchOne(db, key: 2)?.title == "Local Chat")
      #expect(try bucketState(for: spaceKey, in: db)?.seq == 8)
      #expect(try bucketState(for: chatKey, in: db)?.seq == 10)
      #expect(imported.seededStates.isEmpty)
      #expect(imported.catchUpTargets.isEmpty)
    }
  }

  @Test("populated children preserve local state and coalesce newer snapshot targets")
  func populatedChildProducesCatchUpTarget() throws {
    let queue = try makeInMemoryDB()
    let chatKey = BucketKey.chat(peer: makeChatPeer(id: 2))

    try queue.write { (db: Database) throws in
      try Chat(from: makeChat(id: 2, seq: 10, title: "Local Chat")).saveFull(db)
      _ = try GRDBSyncStorage.seedSnapshotBucketState(for: chatKey, seq: 10, in: db)

      var snapshot20 = makeChat(id: 2, seq: 20, title: "Snapshot 20")
      snapshot20.lastMsgID = 1
      var snapshot30 = makeChat(id: 2, seq: 30, title: "Snapshot 30")
      snapshot30.lastMsgID = 1
      var result = InlineProtocol.GetChatsResult()
      result.users = [makeUser(id: 1)]
      result.chats = [snapshot20, snapshot30]
      result.messages = [makeMessage(id: 1, chatID: 2, fromID: 1)]
      result.dialogs = [makeDialog(chatID: 2)]

      let imported = try GetChatsTransaction.applySnapshot(
        result,
        userProjectionAdmission: .alreadyValidated,
        in: db
      )

      #expect(try Chat.fetchOne(db, key: 2)?.title == "Local Chat")
      #expect(try Chat.fetchOne(db, key: 2)?.lastMsgId == nil)
      #expect(try Message.fetchOne(db, key: ["chatId": 2, "messageId": 1]) != nil)
      #expect(try Dialog.fetchCount(db) == 1)
      #expect(try bucketState(for: chatKey, in: db)?.seq == 10)
      #expect(imported.seededStates.isEmpty)
      #expect(imported.catchUpTargets[chatKey] == 30)
    }
  }

  @Test("ordinary catalogs expose only pristine seeds to sync actors")
  func ordinaryCatalogActorStatesExcludeRepairTargets() throws {
    let queue = try makeInMemoryDB()
    let populatedKey = BucketKey.chat(peer: makeChatPeer(id: 2))
    let pristineKey = BucketKey.chat(peer: makeChatPeer(id: 3))

    try queue.write { (db: Database) throws in
      try Chat(from: makeChat(id: 2, seq: 10, title: "Local Chat")).saveFull(db)
      _ = try GRDBSyncStorage.seedSnapshotBucketState(for: populatedKey, seq: 10, in: db)

      var result = InlineProtocol.GetChatsResult()
      result.chats = [
        makeChat(id: 2, seq: 30, title: "Repair Target"),
        makeChat(id: 3, seq: 20, title: "Pristine Seed"),
      ]
      let imported = try GetChatsTransaction.applySnapshot(result, in: db)

      #expect(imported.catchUpTargets[populatedKey] == 30)
      #expect(imported.seededStates[pristineKey]?.seq == 20)
      #expect(imported.catalogActorStates[pristineKey]?.seq == 20)
      #expect(imported.catalogActorStates[populatedKey] == nil)
    }
  }

  @Test("a model without a cursor is uncertain and catches up from zero")
  func modelWithoutCursorDoesNotBecomeSeeded() throws {
    let queue = try makeInMemoryDB()
    let chatKey = BucketKey.chat(peer: makeChatPeer(id: 2))

    try queue.write { (db: Database) throws in
      try Chat(from: makeChat(id: 2, seq: 0, title: "Cached Chat")).saveFull(db)

      var result = InlineProtocol.GetChatsResult()
      result.chats = [makeChat(id: 2, seq: 30, title: "Snapshot Chat")]
      let imported = try GetChatsTransaction.applySnapshot(result, in: db)

      #expect(try Chat.fetchOne(db, key: 2)?.title == "Cached Chat")
      #expect(try bucketState(for: chatKey, in: db) == nil)
      #expect(imported.seededStates.isEmpty)
      #expect(imported.catchUpTargets[chatKey] == 30)
    }
  }

  @Test("children omitted from a snapshot remain untouched")
  func omittedChildrenRemainUntouched() throws {
    let queue = try makeInMemoryDB()
    let spaceKey = BucketKey.space(id: 1)
    let chatKey = BucketKey.chat(peer: makeChatPeer(id: 2))

    try queue.write { (db: Database) throws in
      try Space(from: makeSpace(id: 1, seq: 8, name: "Local Space")).save(db)
      try Chat(from: makeChat(id: 2, spaceID: 1, seq: 10, title: "Local Chat")).saveFull(db)
      _ = try GRDBSyncStorage.seedSnapshotBucketState(for: spaceKey, seq: 8, in: db)
      _ = try GRDBSyncStorage.seedSnapshotBucketState(for: chatKey, seq: 10, in: db)

      let imported = try GetChatsTransaction.applySnapshot(.init(), in: db)

      #expect(try Space.fetchOne(db, key: 1)?.name == "Local Space")
      #expect(try Chat.fetchOne(db, key: 2)?.title == "Local Chat")
      #expect(try bucketState(for: spaceKey, in: db)?.seq == 8)
      #expect(try bucketState(for: chatKey, in: db)?.seq == 10)
      #expect(imported.seededStates.isEmpty)
      #expect(imported.catchUpTargets.isEmpty)
    }
  }

  @Test("duplicate child projections choose the freshest explicit sequence")
  func duplicateChildrenChooseFreshestProjection() throws {
    let queue = try makeInMemoryDB()
    let spaceKey = BucketKey.space(id: 1)
    let chatKey = BucketKey.chat(peer: makeChatPeer(id: 2))
    var result = InlineProtocol.GetChatsResult()
    result.spaces = [
      makeSpace(id: 1, seq: nil, name: "Unsequenced Space"),
      makeSpace(id: 1, seq: 30, name: "Fresh Space"),
      makeSpace(id: 1, seq: 20, name: "Stale Space"),
    ]
    result.chats = [
      makeChat(id: 2, spaceID: 1, seq: nil, title: "Unsequenced Chat"),
      makeChat(id: 2, spaceID: 1, seq: 30, title: "Fresh Chat"),
      makeChat(id: 2, spaceID: 1, seq: 20, title: "Stale Chat"),
    ]

    try queue.write { (db: Database) throws in
      let imported = try GetChatsTransaction.applySnapshot(result, in: db)

      #expect(imported.failures.isEmpty)
      #expect(try Space.fetchOne(db, key: 1)?.name == "Fresh Space")
      #expect(try Chat.fetchOne(db, key: 2)?.title == "Fresh Chat")
      #expect(try bucketState(for: spaceKey, in: db)?.seq == 30)
      #expect(try bucketState(for: chatKey, in: db)?.seq == 30)
      #expect(imported.seededStates[spaceKey]?.seq == 30)
      #expect(imported.seededStates[chatKey]?.seq == 30)
      #expect(imported.catchUpTargets.isEmpty)
    }
  }

  @Test("duplicate chat ids with conflicting peer identities are rejected")
  func conflictingDuplicateChatPeersAreRejected() throws {
    let queue = try makeInMemoryDB()
    var conflicting = makeChat(id: 2, seq: 30, title: "Conflicting Chat")
    conflicting.peerID = makeUserPeer(id: 7)
    var result = InlineProtocol.GetChatsResult()
    result.chats = [
      makeChat(id: 2, seq: 20, title: "Thread Chat"),
      conflicting,
    ]

    try queue.write { (db: Database) throws in
      let imported = try GetChatsTransaction.applySnapshot(result, in: db)

      #expect(failureCount(in: imported, phase: .chats) == 1)
      #expect(try Chat.fetchOne(db, key: 2) == nil)
      #expect(try DbBucketState.fetchCount(db) == 0)
      #expect(imported.seededStates.isEmpty)
      #expect(imported.catchUpTargets.isEmpty)
    }
  }

  @Test("different chat ids cannot claim the same bucket peer")
  func conflictingChatIDsForOnePeerAreRejected() throws {
    let queue = try makeInMemoryDB()
    var original = makeChat(id: 2, seq: 20, title: "Original Chat")
    original.peerID = makeUserPeer(id: 7)
    var conflicting = makeChat(id: 3, seq: 30, title: "Conflicting Chat")
    conflicting.peerID = makeUserPeer(id: 7)
    var result = InlineProtocol.GetChatsResult()
    result.chats = [original, conflicting]

    try queue.write { (db: Database) throws in
      let imported = try GetChatsTransaction.applySnapshot(result, in: db)

      #expect(failureCount(in: imported, phase: .chats) == 1)
      #expect(try Chat.fetchCount(db) == 0)
      #expect(try DbBucketState.fetchCount(db) == 0)
      #expect(imported.seededStates.isEmpty)
      #expect(imported.catchUpTargets.isEmpty)
    }
  }

  @Test("negative sequences are rejected before duplicate freshness selection")
  func malformedSequenceCannotSuppressValidDuplicate() throws {
    let queue = try makeInMemoryDB()
    let spaceKey = BucketKey.space(id: 1)
    let chatKey = BucketKey.chat(peer: makeChatPeer(id: 2))
    var result = InlineProtocol.GetChatsResult()
    result.spaces = [
      makeSpace(id: 1, seq: -1, name: "Malformed Space"),
      makeSpace(id: 1, seq: nil, name: "Unsequenced Space"),
      makeSpace(id: 1, seq: 20, name: "Valid Space"),
    ]
    result.chats = [
      makeChat(id: 2, spaceID: 1, seq: -1, title: "Malformed Chat"),
      makeChat(id: 2, spaceID: 1, seq: nil, title: "Unsequenced Chat"),
      makeChat(id: 2, spaceID: 1, seq: 20, title: "Valid Chat"),
    ]

    try queue.write { (db: Database) throws in
      let imported = try GetChatsTransaction.applySnapshot(result, in: db)

      #expect(failureCount(in: imported, phase: .spaceCursors) == 1)
      #expect(failureCount(in: imported, phase: .chatCursors) == 1)
      #expect(try Space.fetchOne(db, key: 1)?.name == "Valid Space")
      #expect(try Chat.fetchOne(db, key: 2)?.title == "Valid Chat")
      #expect(try bucketState(for: spaceKey, in: db)?.seq == 20)
      #expect(try bucketState(for: chatKey, in: db)?.seq == 20)
      #expect(imported.seededStates[spaceKey]?.seq == 20)
      #expect(imported.seededStates[chatKey]?.seq == 20)
    }
  }

  @Test("space snapshots target only cursors they are ahead of")
  func spaceTargetsRespectCurrentSequence() throws {
    let queue = try makeInMemoryDB()
    let behindKey = BucketKey.space(id: 1)
    let equalKey = BucketKey.space(id: 2)

    try queue.write { (db: Database) throws in
      try Space(from: makeSpace(id: 1, seq: 10, name: "Behind Local")).save(db)
      try Space(from: makeSpace(id: 2, seq: 10, name: "Equal Local")).save(db)
      _ = try GRDBSyncStorage.seedSnapshotBucketState(for: behindKey, seq: 10, in: db)
      _ = try GRDBSyncStorage.seedSnapshotBucketState(for: equalKey, seq: 10, in: db)

      var result = InlineProtocol.GetChatsResult()
      result.spaces = [
        makeSpace(id: 1, seq: 30, name: "Ahead Snapshot"),
        makeSpace(id: 2, seq: 10, name: "Equal Snapshot"),
      ]
      let imported = try GetChatsTransaction.applySnapshot(result, in: db)

      #expect(try Space.fetchOne(db, key: 1)?.name == "Behind Local")
      #expect(try Space.fetchOne(db, key: 2)?.name == "Equal Local")
      #expect(try bucketState(for: behindKey, in: db)?.seq == 10)
      #expect(try bucketState(for: equalKey, in: db)?.seq == 10)
      #expect(imported.catchUpTargets[behindKey] == 30)
      #expect(imported.catchUpTargets[equalKey] == nil)
      #expect(imported.seededStates.isEmpty)
    }
  }

  @Test("a cursor without a model is uncertain and is never filled by getChats")
  func cursorWithoutModelDoesNotAdmitSnapshot() throws {
    let queue = try makeInMemoryDB()
    let chatKey = BucketKey.chat(peer: makeChatPeer(id: 2))

    try queue.write { (db: Database) throws in
      _ = try GRDBSyncStorage.seedSnapshotBucketState(for: chatKey, seq: 10, in: db)

      var result = InlineProtocol.GetChatsResult()
      result.chats = [makeChat(id: 2, seq: 30, title: "Snapshot Chat")]
      let imported = try GetChatsTransaction.applySnapshot(result, in: db)

      #expect(try Chat.fetchOne(db, key: 2) == nil)
      #expect(try bucketState(for: chatKey, in: db)?.seq == 10)
      #expect(imported.seededStates.isEmpty)
      #expect(imported.catchUpTargets.isEmpty)
      #expect(failureCount(in: imported, phase: .chats) == 1)
    }
  }

  @Test("fresh unsequenced children import catalog models and request latest repair")
  func freshUnsequencedChildrenImportWithoutCursor() throws {
    let queue = try makeInMemoryDB()
    let spaceKey = BucketKey.space(id: 1)
    let chatKey = BucketKey.chat(peer: makeChatPeer(id: 2))
    var result = InlineProtocol.GetChatsResult()
    result.spaces = [makeSpace(id: 1, seq: nil, name: "Fresh Space")]
    result.chats = [makeChat(id: 2, spaceID: 1, seq: nil, title: "Fresh Chat")]

    try queue.write { (db: Database) throws in
      let imported = try GetChatsTransaction.applySnapshot(result, in: db)

      #expect(imported.failures.isEmpty)
      #expect(try Space.fetchOne(db, key: 1)?.name == "Fresh Space")
      #expect(try Chat.fetchOne(db, key: 2)?.title == "Fresh Chat")
      #expect(try bucketState(for: spaceKey, in: db) == nil)
      #expect(try bucketState(for: chatKey, in: db) == nil)
      #expect(imported.seededStates.isEmpty)
      #expect(imported.catchUpTargets[spaceKey] == 0)
      #expect(imported.catchUpTargets[chatKey] == 0)
    }
  }

  @Test("existing unsequenced children preserve local state and request latest repair")
  func existingUnsequencedChildrenRemainUntouched() throws {
    let queue = try makeInMemoryDB()
    let spaceKey = BucketKey.space(id: 1)
    let chatKey = BucketKey.chat(peer: makeChatPeer(id: 2))

    try queue.write { (db: Database) throws in
      try Space(from: makeSpace(id: 1, seq: 10, name: "Local Space")).save(db)
      try Chat(from: makeChat(id: 2, spaceID: 1, seq: 10, title: "Local Chat")).saveFull(db)
      _ = try GRDBSyncStorage.seedSnapshotBucketState(for: spaceKey, seq: 10, in: db)
      _ = try GRDBSyncStorage.seedSnapshotBucketState(for: chatKey, seq: 10, in: db)

      var result = InlineProtocol.GetChatsResult()
      result.spaces = [makeSpace(id: 1, seq: nil, name: "Snapshot Space")]
      result.chats = [makeChat(id: 2, spaceID: 1, seq: nil, title: "Snapshot Chat")]
      let imported = try GetChatsTransaction.applySnapshot(result, in: db)

      #expect(imported.failures.isEmpty)
      #expect(try Space.fetchOne(db, key: 1)?.name == "Local Space")
      #expect(try Chat.fetchOne(db, key: 2)?.title == "Local Chat")
      #expect(try bucketState(for: spaceKey, in: db)?.seq == 10)
      #expect(try bucketState(for: chatKey, in: db)?.seq == 10)
      #expect(imported.seededStates.isEmpty)
      #expect(imported.catchUpTargets[spaceKey] == 0)
      #expect(imported.catchUpTargets[chatKey] == 0)
    }
  }

  @Test("dialog failure does not block an otherwise complete child seed")
  func dialogFailureDoesNotPoisonChildCursor() throws {
    let queue = try makeInMemoryDB()
    let chatKey = BucketKey.chat(peer: makeChatPeer(id: 20))
    try queue.writeWithoutTransaction { (db: Database) throws in
      try installRejectingTriggers(db)
    }

    var result = InlineProtocol.GetChatsResult()
    result.chats = [makeChat(id: 20, seq: 20)]
    result.dialogs = [makeDialog(chatID: 20)]

    try queue.write { (db: Database) throws in
      let imported = try GetChatsTransaction.applySnapshot(
        result,
        userProjectionAdmission: .alreadyValidated,
        in: db
      )

      #expect(failureCount(in: imported, phase: .dialogs) == 1)
      #expect(try Chat.fetchOne(db, key: 20) != nil)
      #expect(try Dialog.fetchCount(db) == 0)
      #expect(try bucketState(for: chatKey, in: db)?.seq == 20)
      #expect(imported.seededStates[chatKey]?.seq == 20)
    }
  }

  @Test("snapshot messages remain revision gated for populated children")
  func populatedChildMessageSnapshotCannotRegressRevision() throws {
    let queue = try makeInMemoryDB()
    let chatKey = BucketKey.chat(peer: makeChatPeer(id: 2))

    try queue.write { (db: Database) throws in
      try Chat(from: makeChat(id: 2, seq: 10, title: "Local Chat")).saveFull(db)
      _ = try GRDBSyncStorage.seedSnapshotBucketState(for: chatKey, seq: 10, in: db)
      _ = try User.save(db, user: makeUser(id: 1))
      _ = try Message.save(
        db,
        protocolMessage: makeMessage(
          id: 1,
          chatID: 2,
          fromID: 1,
          text: "Newer Message",
          revision: 5
        )
      )

      var result = InlineProtocol.GetChatsResult()
      result.chats = [makeChat(id: 2, seq: 30, title: "Snapshot Chat")]
      result.messages = [makeMessage(
        id: 1,
        chatID: 2,
        fromID: 1,
        text: "Stale Message",
        revision: 4
      )]
      let imported = try GetChatsTransaction.applySnapshot(result, in: db)
      let message = try #require(try Message.fetchOne(
        db,
        key: ["chatId": 2, "messageId": 1]
      ))

      #expect(message.text == "Newer Message")
      #expect(message.rev == 5)
      #expect(imported.catchUpTargets[chatKey] == 30)
      #expect(imported.seededStates.isEmpty)
    }
  }

  @Test("stale or unsequenced catalogs cannot resurrect a deleted message")
  func staleMessageSnapshotCannotResurrectDeletion() throws {
    let queue = try makeInMemoryDB()
    let chatKey = BucketKey.chat(peer: makeChatPeer(id: 2))
    try queue.write { (db: Database) throws in
      try Chat(from: makeChat(id: 2, seq: 11)).saveFull(db)
      _ = try GRDBSyncStorage.seedSnapshotBucketState(for: chatKey, seq: 11, in: db)
      _ = try User.save(db, user: makeUser(id: 1))

      for sequence in [Int32(10), nil] as [Int32?] {
        var result = InlineProtocol.GetChatsResult()
        result.chats = [makeChat(id: 2, seq: sequence)]
        result.messages = [makeMessage(id: 1, chatID: 2, fromID: 1, revision: 1)]
        _ = try GetChatsTransaction.applySnapshot(result, in: db)
        #expect(try Message.fetchOne(db, key: ["chatId": 2, "messageId": 1]) == nil)
        #expect(try bucketState(for: chatKey, in: db)?.seq == 11)
      }
    }
  }

  @Test("cursor-only children require admitted equal-sequence model reconstruction")
  func cursorOnlyChildrenNeedExactAdmittedSnapshot() throws {
    let queue = try makeInMemoryDB()
    let spaceKey = BucketKey.space(id: 1)
    let chatKey = BucketKey.chat(peer: makeChatPeer(id: 2))
    try queue.write { (db: Database) throws in
      _ = try GRDBSyncStorage.seedSnapshotBucketState(for: spaceKey, seq: 10, in: db)
      _ = try GRDBSyncStorage.seedSnapshotBucketState(for: chatKey, seq: 10, in: db)
      var result = InlineProtocol.GetChatsResult()
      result.spaces = [makeSpace(id: 1, seq: 10)]
      result.chats = [makeChat(id: 2, spaceID: 1, seq: 10)]

      let catalog = try GetChatsTransaction.applySnapshot(result, in: db)
      #expect(failureCount(in: catalog, phase: .spaces) == 1)
      #expect(failureCount(in: catalog, phase: .chats) == 1)
      #expect(try Space.fetchOne(db, key: 1) == nil)
      #expect(try Chat.fetchOne(db, key: 2) == nil)

      let repaired = try GetChatsTransaction.applySnapshot(
        result, userProjectionAdmission: .alreadyValidated, in: db
      )
      #expect(repaired.failures.isEmpty)
      #expect(repaired.seededStates.isEmpty)
      #expect(repaired.catchUpTargets.isEmpty)
      #expect(try Space.fetchOne(db, key: 1) != nil)
      #expect(try Chat.fetchOne(db, key: 2) != nil)
      #expect(try bucketState(for: spaceKey, in: db)?.seq == 10)
      #expect(try bucketState(for: chatKey, in: db)?.seq == 10)
    }
  }

  @Test("cursor-only children reject snapshots on either side of their retained sequence")
  func cursorOnlyChildrenRejectDifferentSequence() throws {
    let queue = try makeInMemoryDB()
    try queue.write { (db: Database) throws in
      _ = try GRDBSyncStorage.seedSnapshotBucketState(for: .space(id: 1), seq: 10, in: db)
      _ = try GRDBSyncStorage.seedSnapshotBucketState(for: .chat(peer: makeChatPeer(id: 2)), seq: 10, in: db)
      for sequence: Int32 in [9, 11] {
        var result = InlineProtocol.GetChatsResult()
        result.spaces = [makeSpace(id: 1, seq: sequence)]
        result.chats = [makeChat(id: 2, spaceID: 1, seq: sequence)]
        let imported = try GetChatsTransaction.applySnapshot(
          result, userProjectionAdmission: .alreadyValidated, in: db
        )
        #expect(failureCount(in: imported, phase: .spaces) == 1)
        #expect(failureCount(in: imported, phase: .chats) == 1)
        #expect(try Space.fetchOne(db, key: 1) == nil)
        #expect(try Chat.fetchOne(db, key: 2) == nil)
      }
    }
  }

  @Test("cursor failure rolls back a fresh chat model acknowledgements and messages")
  func cursorFailureRollsBackWholeFreshChat() throws {
    let queue = try makeInMemoryDB()
    let failedKey = BucketKey.chat(peer: makeChatPeer(id: 20))
    let healthyKey = BucketKey.chat(peer: makeChatPeer(id: 10))
    try queue.writeWithoutTransaction { (db: Database) throws in
      try installRejectingChatCursorTrigger(db, chatID: 20)
    }

    var failedChat = makeChat(id: 20, seq: 20)
    failedChat.lastMsgID = 1
    failedChat.acknowledgements.cursors = [InlineProtocol.ChatAcknowledgement.with {
      $0.chatID = 20
      $0.userID = 1
      $0.maxID = 1
      $0.revision = 1
    }]
    var result = InlineProtocol.GetChatsResult()
    result.users = [makeUser(id: 1)]
    result.chats = [failedChat, makeChat(id: 10, seq: 10)]
    result.messages = [makeMessage(id: 1, chatID: 20, fromID: 1)]

    try queue.write { (db: Database) throws in
      let imported = try GetChatsTransaction.applySnapshot(result, in: db)

      #expect(failureCount(in: imported, phase: .chatCursors) == 1)
      #expect(try Chat.fetchOne(db, key: 20) == nil)
      #expect(try Message.fetchOne(db, key: ["chatId": 20, "messageId": 1]) == nil)
      #expect(try Acknowledgement.fetchCount(db) == 0)
      #expect(try bucketState(for: failedKey, in: db) == nil)
      #expect(imported.seededStates[failedKey] == nil)

      #expect(try Chat.fetchOne(db, key: 10) != nil)
      #expect(try bucketState(for: healthyKey, in: db)?.seq == 10)
      #expect(imported.seededStates[healthyKey]?.seq == 10)
    }
  }

  @Test("warm catalogs hydrate dependencies without replacing user-owned rows")
  func warmCatalogUsesMissingOnlyUserProjection() throws {
    let queue = try makeInMemoryDB()
    let childKey = BucketKey.chat(peer: makeChatPeer(id: 20))

    try queue.write { (db: Database) throws in
      _ = try GRDBSyncStorage.advanceBucketState(for: .user, state: BucketState(date: 100, seq: 10), in: db)
      _ = try User.save(db, user: makeUser(id: 1, name: "Live User"))
      try Chat(from: makeChat(id: 10, seq: 10)).saveFull(db)
      try makeFolder(id: 7, title: "Live Folder").saveFull(db)
      try makeDialog(chatID: 10, folderID: 7, pinned: true).saveFull(db)

      var child = makeChat(id: 20, seq: 20)
      child.acknowledgements.cursors = [.with {
        $0.chatID = 20
        $0.userID = 1
        $0.maxID = 1
        $0.revision = 1
        $0.user = makeUser(id: 1, name: "Stale ACK User")
      }]
      var result = InlineProtocol.GetChatsResult()
      result.users = [
        makeUser(id: 1, name: "Stale User"),
        makeUser(id: 2, name: "Missing Dependency"),
      ]
      result.chats = [child]
      result.folders = [
        makeFolder(id: 7, title: "Stale Folder"),
        makeFolder(id: 8, title: "Unadmitted Folder"),
      ]
      result.dialogs = [
        makeDialog(chatID: 10, folderID: 7, pinned: false),
        makeDialog(chatID: 20, folderID: 8, pinned: false),
      ]

      let imported = try GetChatsTransaction.applySnapshot(result, in: db)

      #expect(imported.userProjectionDisposition == .missingOnly)
      #expect(try User.fetchOne(db, key: 1)?.firstName == "Live User")
      #expect(try User.fetchOne(db, key: 2)?.firstName == "Missing Dependency")
      #expect(try DialogFolder.fetchOne(db, key: 7)?.title == "Live Folder")
      #expect(try DialogFolder.fetchOne(db, key: 8) == nil)
      #expect(try Dialog.fetchOne(db, key: 10)?.pinned == true)
      #expect(try Dialog.fetchOne(db, key: 20) == nil)
      #expect(try Acknowledgement.fetchCount(db) == 0)
      #expect(try bucketState(for: childKey, in: db) == nil)
      #expect(imported.seededStates.isEmpty)
    }
  }

  @Test("matching user cursor admits profiles dialogs and folders")
  func matchingUserCursorAdmitsUserProjection() throws {
    let queue = try makeInMemoryDB()
    let expected = GetChatsTransaction.ExpectedUserBucketState(
      BucketState(date: 100, seq: 10)
    )

    try queue.write { (db: Database) throws in
      _ = try GRDBSyncStorage.advanceBucketState(
        for: .user,
        state: BucketState(date: 100, seq: 10),
        in: db
      )
      _ = try User.save(db, user: makeUser(id: 1, name: "Before User"))
      try Chat(from: makeChat(id: 10, seq: 10)).saveFull(db)
      try makeFolder(id: 7, title: "Before Folder").saveFull(db)
      try makeDialog(chatID: 10, folderID: 7, pinned: true).saveFull(db)

      var result = InlineProtocol.GetChatsResult()
      result.users = [makeUser(id: 1, name: "Snapshot User")]
      result.folders = [makeFolder(id: 7, title: "Snapshot Folder")]
      result.dialogs = [makeDialog(chatID: 10, folderID: 7, pinned: false)]
      let imported = try GetChatsTransaction.applySnapshot(
        result,
        userProjectionAdmission: .compareAndSwap(expected: expected),
        in: db
      )

      #expect(imported.userProjectionDisposition == .applied)
      #expect(try User.fetchOne(db, key: 1)?.firstName == "Snapshot User")
      #expect(try DialogFolder.fetchOne(db, key: 7)?.title == "Snapshot Folder")
      #expect(try Dialog.fetchOne(db, key: 10)?.pinned == false)
    }
  }

  @Test("live user advance prevents stale user projection and apparent pristine child resurrection")
  func liveUserInterleavePreservesProjectionAndRemovedChildren() throws {
    let queue = try makeInMemoryDB()
    let expected = GetChatsTransaction.ExpectedUserBucketState(
      BucketState(date: 100, seq: 10)
    )
    let actual = GetChatsTransaction.ExpectedUserBucketState(
      BucketState(date: 200, seq: 11)
    )
    let childKey = BucketKey.chat(peer: makeChatPeer(id: 20))

    try queue.write { (db: Database) throws in
      _ = try GRDBSyncStorage.advanceBucketState(
        for: .user,
        state: BucketState(date: 100, seq: 10),
        in: db
      )
      // This models the live update committing after preflight capture and
      // before the GET_CHATS response enters its writer.
      _ = try GRDBSyncStorage.advanceBucketState(
        for: .user,
        state: BucketState(date: 200, seq: 11),
        in: db
      )
      _ = try User.save(db, user: makeUser(id: 1, name: "Live User"))
      try Chat(from: makeChat(id: 10, seq: 10)).saveFull(db)
      try makeFolder(id: 7, title: "Live Folder").saveFull(db)
      try makeDialog(chatID: 10, folderID: 7, pinned: true).saveFull(db)

      var result = InlineProtocol.GetChatsResult()
      result.users = [
        makeUser(id: 1, name: "Stale User"),
        makeUser(id: 2, name: "Missing Dependency"),
      ]
      result.chats = [makeChat(id: 20, seq: 20)]
      result.folders = [makeFolder(id: 7, title: "Stale Folder")]
      result.dialogs = [makeDialog(chatID: 10, folderID: 7, pinned: false)]
      let imported = try GetChatsTransaction.applySnapshot(
        result,
        userProjectionAdmission: .compareAndSwap(expected: expected),
        in: db
      )

      #expect(imported.userProjectionDisposition == .superseded(
        expected: expected,
        actual: actual
      ))
      #expect(try User.fetchOne(db, key: 1)?.firstName == "Live User")
      #expect(try User.fetchOne(db, key: 2)?.firstName == "Missing Dependency")
      #expect(try DialogFolder.fetchOne(db, key: 7)?.title == "Live Folder")
      #expect(try Dialog.fetchOne(db, key: 10)?.pinned == true)
      #expect(try Chat.fetchOne(db, key: 20) == nil)
      #expect(try bucketState(for: childKey, in: db) == nil)
      #expect(imported.seededStates.isEmpty)
    }
  }

  @Test("typed account catalog replacement hides omissions without deleting cached history")
  func accountCatalogReplacementPreservesCachedRows() throws {
    let queue = try makeInMemoryDB()
    try queue.write { (db: Database) throws in
      _ = try User.save(db, user: makeUser(id: 1))
      for id: Int64 in [1, 2] {
        try Space(from: makeSpace(id: id, seq: 5)).save(db)
        try Chat(from: makeChat(id: id * 10, spaceID: id, seq: 5)).saveFull(db)
        _ = try GRDBSyncStorage.seedSnapshotBucketState(
          for: .space(id: id),
          seq: 5,
          in: db
        )
        _ = try GRDBSyncStorage.seedSnapshotBucketState(
          for: .chat(peer: makeChatPeer(id: id * 10)),
          seq: 5,
          in: db
        )
        _ = try Message.save(
          db,
          protocolMessage: makeMessage(id: 5, chatID: id * 10, fromID: 1),
          publishChanges: false
        )
        var dialog = makeDialog(chatID: id * 10)
        if id == 1 {
          dialog.readMaxID = 4
          dialog.unreadCount = 8
          dialog.unreadMark = true
        } else {
          dialog.readMaxID = 3
          dialog.unreadCount = 7
        }
        try dialog.saveFull(db)
      }
      try makeFolder(id: 1, title: "Active").saveFull(db)
      try makeFolder(id: 2, title: "Omitted").saveFull(db)
      try DialogCatalogStore.exclude(dialogID: 10, in: db)

      var activeChat = makeChat(id: 10, spaceID: 1, seq: 6, title: "Rebased Chat")
      activeChat.lastMsgID = 5
      var result = InlineProtocol.GetChatsResult()
      result.spaces = [makeSpace(id: 1, seq: 6, name: "Rebased Space")]
      result.chats = [activeChat]
      result.messages = [makeMessage(id: 5, chatID: 10, fromID: 1)]
      result.dialogs = [makeDialog(chatID: 10, folderID: 1)]
      result.folders = [makeFolder(id: 1, title: "Active")]

      let imported = try GetChatsTransaction.applySnapshot(
        result,
        userProjectionAdmission: .alreadyValidated,
        replacesActiveCatalog: true,
        in: db
      )

      #expect(imported.failures.isEmpty)
      #expect(imported.catchUpTargets.isEmpty)
      #expect(imported.seededStates[.space(id: 1)]?.seq == 6)
      #expect(imported.seededStates[.chat(peer: makeChatPeer(id: 10))]?.seq == 6)
      #expect(imported.retiredBucketKeys == Set([
        .space(id: 2),
        .chat(peer: makeChatPeer(id: 20)),
      ]))
      #expect(try Space.fetchCount(db) == 2)
      #expect(try Chat.fetchCount(db) == 2)
      #expect(try Message.fetchCount(db) == 2)
      #expect(try Space.fetchOne(db, key: 1)?.name == "Rebased Space")
      #expect(try Chat.fetchOne(db, key: 10)?.title == "Rebased Chat")
      #expect(try bucketState(for: .space(id: 1), in: db)?.seq == 6)
      #expect(try bucketState(for: .chat(peer: makeChatPeer(id: 10)), in: db)?.seq == 6)
      #expect(try bucketState(for: .space(id: 2), in: db)?.seq == 5)
      #expect(try bucketState(for: .chat(peer: makeChatPeer(id: 20)), in: db)?.seq == 5)
      #expect(try Space.catalogActive().fetchAll(db).map(\.id) == [1])
      let activeDialog = try #require(try Dialog.fetchOne(db, key: 10))
      #expect(activeDialog.readInboxMaxId == 4)
      #expect(activeDialog.unreadCount == 8)
      #expect(activeDialog.unreadMark == true)
      let retainedDialog = try #require(try Dialog.fetchOne(db, key: 20))
      #expect(retainedDialog.readInboxMaxId == 3)
      #expect(retainedDialog.unreadCount == 7)
      #expect(try Dialog.catalogActive().fetchAll(db).map(\.id) == [10])
      #expect(try DialogCatalogExclusion.fetchOne(db, key: 10) == nil)
      #expect(try DialogCatalogExclusion.fetchOne(db, key: 20) != nil)
      #expect(try DialogFolder.fetchOne(db, key: 1) != nil)
      #expect(try DialogFolder.fetchOne(db, key: 2) == nil)
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 10) == [
        MessageHistoryHole(chatId: 10, lowerId: 1, upperId: 4),
      ])
    }
  }

  @Test("ordinary catalog application never treats omission as deletion")
  func ordinaryCatalogOmissionIsInert() throws {
    let queue = try makeInMemoryDB()
    try queue.write { (db: Database) throws in
      try Space(from: makeSpace(id: 1, seq: 5)).save(db)
      try Chat(from: makeChat(id: 10, spaceID: 1, seq: 5)).saveFull(db)
      try makeDialog(chatID: 10).saveFull(db)

      _ = try GetChatsTransaction.applySnapshot(
        .init(),
        userProjectionAdmission: .alreadyValidated,
        in: db
      )

      #expect(try Space.catalogActive().fetchCount(db) == 1)
      #expect(try Dialog.fetchOne(db, key: 10) != nil)
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

  private func installRejectingChatCursorTrigger(_ db: Database, chatID: Int64) throws {
    try db.execute(sql: """
      CREATE TRIGGER reject_test_chat_cursor BEFORE INSERT ON sync_bucket_state
      WHEN NEW.bucketType = 1 AND NEW.entityId = \(-chatID)
      BEGIN SELECT RAISE(ABORT, 'reject test chat cursor'); END;
      """)
  }

  private func failureCount(
    in result: GetChatsTransaction.SnapshotImportResult,
    phase: GetChatsTransaction.SnapshotImportPhase
  ) -> Int {
    result.failures.first { $0.phase == phase }?.count ?? 0
  }

  private func bucketState(for key: BucketKey, in db: Database) throws -> DbBucketState? {
    try DbBucketState
      .filter(
        DbBucketState.Columns.bucketType == key.getBucket()
          && DbBucketState.Columns.entityId == key.getEntityId()
      )
      .fetchOne(db)
  }

  private func makeSpace(
    id: Int64,
    seq: Int32?,
    name: String? = nil
  ) -> InlineProtocol.Space {
    var space = InlineProtocol.Space()
    space.id = id
    space.name = name ?? "Space \(id)"
    space.date = 100
    if let seq { space.seq = seq }
    return space
  }

  private func makeUser(
    id: Int64,
    name: String? = nil
  ) -> InlineProtocol.User {
    var user = InlineProtocol.User()
    user.id = id
    user.firstName = name ?? "User \(id)"
    return user
  }

  private func makeFolder(
    id: Int64,
    title: String
  ) -> InlineProtocol.DialogFolder {
    .with {
      $0.id = id
      $0.title = title
      $0.order = "folder-\(id)"
    }
  }

  private func makeChat(
    id: Int64,
    spaceID: Int64? = nil,
    parentChatID: Int64? = nil,
    seq: Int32?,
    title: String? = nil
  ) -> InlineProtocol.Chat {
    var chat = InlineProtocol.Chat()
    chat.id = id
    chat.title = title ?? "Chat \(id)"
    chat.date = 100
    if let spaceID { chat.spaceID = spaceID }
    if let parentChatID { chat.parentChatID = parentChatID }
    chat.peerID = makeChatPeer(id: id)
    if let seq { chat.seq = seq }
    return chat
  }

  private func makeMessage(
    id: Int64,
    chatID: Int64,
    fromID: Int64,
    text: String = "test",
    revision: Int64? = nil
  ) -> InlineProtocol.Message {
    var message = InlineProtocol.Message()
    message.id = id
    message.chatID = chatID
    message.fromID = fromID
    message.date = 100
    message.peerID = makeChatPeer(id: chatID)
    message.message = text
    if let revision { message.rev = revision }
    return message
  }

  private func makeDialog(
    chatID: Int64,
    folderID: Int64? = nil,
    pinned: Bool? = nil
  ) -> InlineProtocol.Dialog {
    var dialog = InlineProtocol.Dialog()
    dialog.peer = makeChatPeer(id: chatID)
    dialog.chatID = chatID
    dialog.open = true
    dialog.order = "dialog-\(chatID)"
    if let folderID { dialog.folderID = folderID }
    if let pinned { dialog.pinned = pinned }
    return dialog
  }

  private func makeChatPeer(id: Int64) -> InlineProtocol.Peer {
    .with { $0.chat.chatID = id }
  }

  private func makeUserPeer(id: Int64) -> InlineProtocol.Peer {
    .with { $0.user.userID = id }
  }
}
