@testable import Auth
import Foundation
import GRDB
import InlineProtocol
import RealtimeV2
import Testing

@testable import InlineKit

@Suite("Chat bucket repair")
struct ChatRepairReplacementTests {
  @Test("overlays authoritative chat state without deleting cached history")
  func replacesStaleChatBucket() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let appDatabase = try AppDatabase(queue)
    let engine = makeEngine(database: appDatabase)

    try await queue.write { (db: Database) throws in
      try User(
        id: 1,
        email: "repair@example.com",
        firstName: "Repair",
        lastName: nil,
        username: "repair"
      ).insert(db)
      try Chat(
        id: 7,
        date: Date(timeIntervalSince1970: 10),
        type: .thread,
        title: "Stale",
        spaceId: nil,
        lastMsgId: 10,
        participantRosterComplete: true
      ).insert(db)
      try ChatParticipant(
        chatId: 7,
        userId: 1,
        date: Date(timeIntervalSince1970: 10)
      ).insert(db)
      var stale = Message(
        messageId: 10,
        fromId: 1,
        date: Date(timeIntervalSince1970: 10),
        text: "stale",
        peerUserId: nil,
        peerThreadId: 7,
        chatId: 7
      )
      try stale.saveMessage(db)
      var localDialogProto = InlineProtocol.Dialog()
      localDialogProto.peer = chatPeer(7)
      localDialogProto.chatID = 7
      var localDialog = Dialog(from: localDialogProto)
      localDialog.open = true
      localDialog.order = "local-order"
      localDialog.pinnedOrder = "local-pin"
      localDialog.collapsedMaxId = 4
      try localDialog.save(db)
      _ = try GRDBSyncStorage.advanceBucketState(
        for: .chat(peer: chatPeer(7)),
        state: BucketState(date: 10, seq: 1),
        in: db
      )
    }

    let target = BucketState(date: 20, seq: 5)
    let committed = await engine.applyChatRepair(ChatRepairSnapshot(
      peer: chatPeer(7),
      chat: repairedChatResult(),
      pinnedMessages: [],
      targetState: target,
      mutationToken: accountToken(),
      reason: "test"
    ))

    #expect(committed?.seq == target.seq)
    #expect(committed?.date == target.date)
    try await queue.read { (db: Database) throws in
      #expect(try Chat.fetchOne(db, id: 7)?.title == "Repaired")
      #expect(try Message.filter(Message.Columns.chatId == 7).fetchCount(db) == 1)
      #expect(try Message
        .filter(Message.Columns.chatId == 7 && Message.Columns.messageId == 10)
        .fetchOne(db)?.text == "stale")
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7) == [
        MessageHistoryHole(
          chatId: 7,
          lowerId: 1,
          upperId: MessageHistoryHole.positiveMessageIDMax
        ),
      ])
      #expect(try Chat.fetchOne(db, id: 7)?.participantRosterComplete == false)
      #expect(try ChatParticipant.fetchAll(db).map(\.userId) == [1])
      let dialog = try #require(try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: .thread(id: 7))))
      #expect(dialog.open)
      #expect(dialog.order == "local-order")
      #expect(dialog.pinnedOrder == "local-pin")
      #expect(dialog.collapsedMaxId == 4)
      let state = try #require(try DbBucketState.fetchOne(db))
      #expect(state.seq == 5)
      #expect(state.date == 20)
    }

    try await queue.write { (db: Database) throws in
      var newer = Message(
        messageId: 11,
        fromId: 1,
        date: Date(timeIntervalSince1970: 21),
        text: "newer",
        peerUserId: nil,
        peerThreadId: 7,
        chatId: 7
      )
      try newer.saveMessage(db)
    }
    _ = await engine.applyChatRepair(ChatRepairSnapshot(
      peer: chatPeer(7),
      chat: repairedChatResult(),
      pinnedMessages: [],
      targetState: target,
      mutationToken: accountToken(),
      reason: "stale-repeat"
    ))
    try await queue.read { (db: Database) throws in
      let preserved = try Message
        .filter(Message.Columns.chatId == 7 && Message.Columns.messageId == 11)
        .fetchOne(db)
      #expect(preserved != nil)
    }
  }

  @Test("authoritative chat sequence wins admission even after the requested target was reached")
  func admitsSnapshotSequenceAboveDurableCursor() async throws {
    let (queue, engine) = try makeRepairDatabase(cursor: 11, title: "Live 11")
    var snapshot = repairedChatResult()
    snapshot.chat.seq = 12

    let committed = await engine.applyChatRepair(ChatRepairSnapshot(
      peer: chatPeer(7),
      chat: snapshot,
      pinnedMessages: [],
      targetState: BucketState(date: 20, seq: 10),
      mutationToken: accountToken(),
      reason: "snapshot-sequence-admission"
    ))

    #expect(committed?.seq == 12)
    try await queue.read { (db: Database) throws in
      #expect(try Chat.fetchOne(db, id: 7)?.title == "Repaired")
      #expect(try DbBucketState.fetchOne(db)?.seq == 12)
    }

    try await queue.write { (db: Database) throws in
      var chat = try #require(try Chat.fetchOne(db, id: 7))
      chat.title = "Live 13"
      try chat.update(db)
      _ = try GRDBSyncStorage.advanceBucketState(
        for: .chat(peer: chatPeer(7)),
        state: BucketState(date: 21, seq: 13),
        in: db
      )
    }

    let stale = await engine.applyChatRepair(ChatRepairSnapshot(
      peer: chatPeer(7),
      chat: snapshot,
      pinnedMessages: [],
      targetState: BucketState(date: 20, seq: 10),
      mutationToken: accountToken(),
      reason: "stale-snapshot"
    ))
    #expect(stale?.seq == 13)
    try await queue.read { (db: Database) throws in
      #expect(try Chat.fetchOne(db, id: 7)?.title == "Live 13")
      #expect(try DbBucketState.fetchOne(db)?.seq == 13)
    }
  }

  @Test("unresolved structural references retain the previous chat and cursor")
  func unresolvedStructuralReferencesDoNotAdvance() async throws {
    let (queue, engine) = try makeRepairDatabase(cursor: 1, title: "Stale")
    var snapshots: [InlineProtocol.GetChatResult] = []

    var missingSpace = repairedChatResult()
    missingSpace.chat.spaceID = 900
    snapshots.append(missingSpace)

    var missingCreator = repairedChatResult()
    missingCreator.chat.createdBy = 901
    snapshots.append(missingCreator)

    var missingParent = repairedChatResult()
    missingParent.chat.parentChatID = 902
    missingParent.chat.parentMessageID = 903
    snapshots.append(missingParent)

    for snapshot in snapshots {
      let committed = await engine.applyChatRepair(ChatRepairSnapshot(
        peer: chatPeer(7),
        chat: snapshot,
        pinnedMessages: [],
        targetState: BucketState(date: 20, seq: 5),
        mutationToken: accountToken(),
        reason: "missing-structural-reference"
      ))
      #expect(committed == nil)
    }

    try await queue.read { (db: Database) throws in
      let chat = try #require(try Chat.fetchOne(db, id: 7))
      #expect(chat.title == "Stale")
      #expect(chat.spaceId == nil)
      #expect(chat.createdBy == nil)
      #expect(chat.parentChatId == nil)
      #expect(try DbBucketState.fetchOne(db)?.seq == 1)
    }
  }

  @Test("a parent reference requires the exact parent message row")
  func missingParentMessageDoesNotAdvance() async throws {
    let (queue, engine) = try makeRepairDatabase(cursor: 1, title: "Stale")
    try await queue.write { (db: Database) throws in
      try Chat(
        id: 8,
        date: Date(timeIntervalSince1970: 10),
        type: .thread,
        title: "Parent",
        spaceId: nil
      ).insert(db)
    }
    var snapshot = repairedChatResult()
    snapshot.chat.parentChatID = 8
    snapshot.chat.parentMessageID = 55

    let missing = await engine.applyChatRepair(ChatRepairSnapshot(
      peer: chatPeer(7),
      chat: snapshot,
      pinnedMessages: [],
      targetState: BucketState(date: 20, seq: 5),
      mutationToken: accountToken(),
      reason: "missing-parent-message"
    ))
    #expect(missing == nil)
    try await queue.read { (db: Database) throws in
      #expect(try Chat.fetchOne(db, id: 7)?.title == "Stale")
      #expect(try DbBucketState
        .filter(DbBucketState.Columns.entityId == BucketKey.chat(peer: chatPeer(7)).getEntityId())
        .fetchOne(db)?.seq == 1)
    }

    try await queue.write { (db: Database) throws in
      try User(id: 1, email: "parent@example.com", firstName: "Parent").insert(db)
      var parentMessage = Message(
        messageId: 55,
        fromId: 1,
        date: Date(timeIntervalSince1970: 10),
        text: "parent",
        peerUserId: nil,
        peerThreadId: 8,
        chatId: 8
      )
      try parentMessage.saveMessage(db)
    }
    let committed = await engine.applyChatRepair(ChatRepairSnapshot(
      peer: chatPeer(7),
      chat: snapshot,
      pinnedMessages: [],
      targetState: BucketState(date: 20, seq: 5),
      mutationToken: accountToken(),
      reason: "resolved-parent-message"
    ))
    #expect(committed?.seq == 5)
    try await queue.read { (db: Database) throws in
      let repaired = try #require(try Chat.fetchOne(db, id: 7))
      #expect(repaired.parentChatId == 8)
      #expect(repaired.parentMessageId == 55)
    }
  }

  @Test("an exact authoritative anchor resolves the parent dependency")
  func anchorMessageResolvesParentReference() async throws {
    let (queue, engine) = try makeRepairDatabase(cursor: 1, title: "Stale")
    var snapshot = repairedChatResult()
    snapshot.chat.parentChatID = 8
    snapshot.chat.parentMessageID = 55
    snapshot.anchorMessage = protocolMessage(id: 55, chatID: 8, fromID: 1)

    let committed = await engine.applyChatRepair(ChatRepairSnapshot(
      peer: chatPeer(7),
      chat: snapshot,
      pinnedMessages: [],
      targetState: BucketState(date: 20, seq: 5),
      mutationToken: accountToken(),
      reason: "anchor-resolves-parent"
    ))

    #expect(committed?.seq == 5)
    try await queue.read { (db: Database) throws in
      let repaired = try #require(try Chat.fetchOne(db, id: 7))
      #expect(repaired.parentChatId == 8)
      #expect(repaired.parentMessageId == 55)
      #expect(try Message
        .filter(Message.Columns.chatId == 8 && Message.Columns.messageId == 55)
        .fetchCount(db) == 1)
    }
  }

  @Test("a missing or zero repair peer fails without synthesizing peer zero")
  func malformedPeerDoesNotAdvance() async throws {
    let (queue, engine) = try makeRepairDatabase(cursor: 1, title: "Stale")
    for peer in [InlineProtocol.Peer(), chatPeer(0)] {
      let committed = await engine.applyChatRepair(ChatRepairSnapshot(
        peer: peer,
        chat: repairedChatResult(),
        pinnedMessages: [],
        targetState: BucketState(date: 20, seq: 5),
        mutationToken: accountToken(),
        reason: "malformed-peer"
      ))
      #expect(committed == nil)
    }
    try await queue.read { (db: Database) throws in
      #expect(try Chat.fetchOne(db, id: 7)?.title == "Stale")
      #expect(try DbBucketState.fetchOne(db)?.seq == 1)
    }
  }

  @Test("a generation change inside the chat repair writer rolls back the snapshot")
  func mutationTokenIsRevalidatedInsideChatWriter() async throws {
    let validator = RepairMutationValidator(failingOnCall: 2)
    let (queue, engine) = try makeRepairDatabase(
      cursor: 1,
      title: "Stale",
      validateAccountMutation: { token in
        try validator.validate(token)
      }
    )
    let committed = await engine.applyChatRepair(ChatRepairSnapshot(
      peer: chatPeer(7),
      chat: repairedChatResult(),
      pinnedMessages: [],
      targetState: BucketState(date: 20, seq: 5),
      mutationToken: accountToken(),
      reason: "generation-changed-in-writer"
    ))

    #expect(committed == nil)
    #expect(validator.callCount() == 2)
    try await queue.read { (db: Database) throws in
      #expect(try Chat.fetchOne(db, id: 7)?.title == "Stale")
      #expect(try DbBucketState.fetchOne(db)?.seq == 1)
    }
  }

  @Test("an uncached authoritative pin retains the previous chat and cursor")
  func missingPinnedMessageDoesNotAdvance() async throws {
    let (queue, engine) = try makeRepairDatabase(cursor: 1, title: "Stale")
    try await queue.write { (db: Database) throws in
      // Chat insertion already seeds unknown history across the full ID range.
      try MessageHistoryCoverageStore.subtract(
        db,
        chatId: 7,
        lowerId: 101,
        upperId: MessageHistoryHole.positiveMessageIDMax
      )
    }
    var snapshot = repairedChatResult()
    snapshot.pinnedMessageIds = [999]

    let committed = await engine.applyChatRepair(ChatRepairSnapshot(
      peer: chatPeer(7),
      chat: snapshot,
      pinnedMessages: [],
      targetState: BucketState(date: 20, seq: 5),
      mutationToken: accountToken(),
      reason: "missing-pin"
    ))

    #expect(committed == nil)
    try await queue.read { (db: Database) throws in
      #expect(try Chat.fetchOne(db, id: 7)?.title == "Stale")
      #expect(try PinnedMessage.fetchCount(db) == 0)
      #expect(try DbBucketState.fetchOne(db)?.seq == 1)
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7) == [
        MessageHistoryHole(chatId: 7, lowerId: 1, upperId: 100),
      ])
    }
  }

  @Test("exact pin hydration saves the pin without claiming contiguous history")
  func exactPinnedMessageDoesNotCloseCoverage() async throws {
    let (queue, engine) = try makeRepairDatabase(cursor: 1, title: "Stale")
    var snapshot = repairedChatResult()
    snapshot.pinnedMessageIds = [20]
    let pinned = protocolMessage(id: 20, chatID: 7, fromID: 2)

    let committed = await engine.applyChatRepair(ChatRepairSnapshot(
      peer: chatPeer(7),
      chat: snapshot,
      pinnedMessages: [pinned],
      targetState: BucketState(date: 20, seq: 5),
      mutationToken: accountToken(),
      reason: "exact-pin"
    ))

    #expect(committed?.seq == 5)
    try await queue.read { (db: Database) throws in
      #expect(try Message
        .filter(Message.Columns.chatId == 7 && Message.Columns.messageId == 20)
        .fetchCount(db) == 1)
      #expect(try PinnedMessage.fetchAll(db).map(\.messageId) == [20])
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7) == [
        MessageHistoryHole(
          chatId: 7,
          lowerId: 1,
          upperId: MessageHistoryHole.positiveMessageIDMax
        ),
      ])
    }
  }

  private func chatPeer(_ chatID: Int64) -> InlineProtocol.Peer {
    .with { $0.chat.chatID = chatID }
  }

  private func repairedChatResult() -> InlineProtocol.GetChatResult {
    let peer = chatPeer(7)
    var chat = InlineProtocol.Chat()
    chat.id = 7
    chat.title = "Repaired"
    chat.peerID = peer
    chat.seq = 5

    var dialog = InlineProtocol.Dialog()
    dialog.chatID = 7
    dialog.peer = peer

    var result = InlineProtocol.GetChatResult()
    result.chat = chat
    result.dialog = dialog
    return result
  }

  private func protocolMessage(
    id: Int64,
    chatID: Int64,
    fromID: Int64
  ) -> InlineProtocol.Message {
    var message = InlineProtocol.Message()
    message.id = id
    message.chatID = chatID
    message.fromID = fromID
    message.date = 20
    message.message = "pinned"
    message.peerID = chatPeer(chatID)
    return message
  }

  private func makeRepairDatabase(
    cursor: Int64,
    title: String,
    validateAccountMutation: @escaping @Sendable (AuthAccountMutationToken) throws -> Void = { _ in }
  ) throws -> (DatabaseQueue, UpdatesEngine) {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let appDatabase = try AppDatabase(queue)
    try queue.write { (db: Database) throws in
      try Chat(
        id: 7,
        date: Date(timeIntervalSince1970: 10),
        type: .thread,
        title: title,
        spaceId: nil
      ).insert(db)
      _ = try GRDBSyncStorage.advanceBucketState(
        for: .chat(peer: chatPeer(7)),
        state: BucketState(date: 10, seq: cursor),
        in: db
      )
    }
    return (
      queue,
      makeEngine(
        database: appDatabase,
        validateAccountMutation: validateAccountMutation
      )
    )
  }

  private func makeEngine(
    database: AppDatabase,
    validateAccountMutation: @escaping @Sendable (AuthAccountMutationToken) throws -> Void = { _ in }
  ) -> UpdatesEngine {
    UpdatesEngine(
      database: database,
      authenticatedUserID: { 42 },
      validateAccountMutation: validateAccountMutation
    )
  }

  private func accountToken() -> AuthAccountMutationToken {
    AuthAccountMutationToken(generation: 1, userID: 42)
  }
}

@Suite("Space bucket repair")
struct SpaceRepairReplacementTests {
  @Test("persists the requesting membership without claiming a complete roster")
  func persistsRequestingMembership() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let appDatabase = try AppDatabase(queue)
    let validator = RepairMutationValidator()
    let engine = UpdatesEngine(
      database: appDatabase,
      authenticatedUserID: { 2 },
      validateAccountMutation: { token in
        try validator.validate(token)
      }
    )

    try await queue.write { (db: Database) throws in
      try User(id: 1, email: "stale@example.com", firstName: "Stale").insert(db)
      try User(id: 2, email: "current@example.com", firstName: "Current").insert(db)
      try Space(
        id: 7,
        name: "Stale Space",
        date: Date(timeIntervalSince1970: 10),
        seq: 1,
        memberRosterComplete: true
      ).insert(db)
      try Member(
        id: 101,
        date: Date(timeIntervalSince1970: 10),
        userId: 1,
        spaceId: 7
      ).insert(db)
      _ = try GRDBSyncStorage.advanceBucketState(
        for: .space(id: 7),
        state: BucketState(date: 10, seq: 1),
        in: db
      )
    }

    var space = InlineProtocol.Space()
    space.id = 7
    space.name = "Repaired Space"
    space.date = 20
    space.seq = 5
    var membership = InlineProtocol.Member()
    membership.id = 202
    membership.spaceID = 7
    membership.userID = 2
    membership.date = 20
    var snapshot = InlineProtocol.GetSpaceResult()
    snapshot.space = space
    snapshot.membership = membership

    let committed = await engine.applySpaceRepair(SpaceRepairSnapshot(
      spaceID: 7,
      snapshot: snapshot,
      targetState: BucketState(date: 20, seq: 5),
      mutationToken: AuthAccountMutationToken(generation: 1, userID: 2),
      reason: "test"
    ))

    #expect(committed?.date == 20)
    #expect(committed?.seq == 5)
    #expect(validator.callCount() == 2)
    try await queue.read { (db: Database) throws in
      #expect(try Space.fetchOne(db, id: 7)?.name == "Repaired Space")
      #expect(try Space.fetchOne(db, id: 7)?.memberRosterComplete == false)
      #expect(try Member.order(Member.Columns.userId).fetchAll(db).map(\.userId) == [1, 2])
      let state = try #require(try DbBucketState.fetchOne(db))
      #expect(state.seq == 5)
      #expect(state.date == 20)
    }
  }
}

private enum RepairMutationValidationError: Error {
  case staleGeneration
}

private final class RepairMutationValidator: @unchecked Sendable {
  private let lock = NSLock()
  private let failingOnCall: Int?
  private var calls = 0

  init(failingOnCall: Int? = nil) {
    self.failingOnCall = failingOnCall
  }

  func validate(_: AuthAccountMutationToken) throws {
    lock.lock()
    defer { lock.unlock() }
    calls += 1
    if let failingOnCall, calls == failingOnCall {
      throw RepairMutationValidationError.staleGeneration
    }
  }

  func callCount() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return calls
  }
}
