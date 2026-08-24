import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct GetChatsTransaction: Transaction2 {
  // Properties
  public var method: InlineProtocol.Method = .getChats
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {}

  enum CodingKeys: String, CodingKey {
    case context
  }

  // Private
  private var log = Log.scoped("Transactions/GetChats")

  public init() {
    context = Context()
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .getChats(.init())
  }

  // MARK: - Transaction Methods

  public func apply(_ rpcResult: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .getChats(result) = rpcResult else {
      throw TransactionExecutionError.invalid
    }

    log.trace(
      "getChats result counts" +
        " spaces=\(result.spaces.count)" +
        " users=\(result.users.count)" +
        " chats=\(result.chats.count)" +
        " messages=\(result.messages.count)" +
        " folders=\(result.folders.count)" +
        " dialogs=\(result.dialogs.count)"
    )

    // Apply to database/UI

    do {
      let importResult = try await AppDatabase.shared.dbWriter.write { db in
        try Self.applySnapshot(result, in: db)
      }
      await Api.realtime.installSnapshotBucketStates(importResult.bucketStates)
      Self.report(importResult.failures)
    } catch {
      Log.scoped("GetChatsSnapshot-transaction")
        .error("Failed to apply getChats snapshot", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  static func applySnapshot(
    _ result: InlineProtocol.GetChatsResult,
    in db: Database
  ) throws -> SnapshotImportResult {
    var bucketStates: [BucketKey: BucketState] = [:]
    var failures = SnapshotFailureAccumulator()

    for space in result.spaces {
      guard space.id > 0 else {
        failures.record(.spaces)
        continue
      }
      if try attempt(.spaces, in: db, failures: &failures, {
        let spaceModel = Space(from: space)
        try spaceModel.save(db)
        return spaceModel
      }) != nil, space.hasSeq {
        let key = BucketKey.space(id: space.id)
        if let state = try attempt(.spaceCursors, in: db, failures: &failures, {
          try GRDBSyncStorage.seedSnapshotBucketState(
            for: .space(id: space.id),
            seq: Int64(space.seq),
            in: db
          )
        }) {
          bucketStates[key] = state
        }
      }
    }

    for user in result.users {
      guard user.id > 0 else {
        failures.record(.users)
        continue
      }
      _ = try attempt(.users, in: db, failures: &failures) {
        _ = try User.save(db, user: user)
        return true
      }
    }

    var pendingChats: [PendingChat] = []
    var importedChats: [Int64: ImportedChat] = [:]
    var incompleteChatIDs: Set<Int64> = []
    for protocolChat in result.chats {
      guard protocolChat.id > 0 else {
        failures.record(.chats)
        incompleteChatIDs.insert(protocolChat.id)
        continue
      }
      guard validPeer(protocolChat.peerID) else {
        failures.record(.chats)
        incompleteChatIDs.insert(protocolChat.id)
        continue
      }

      var chat = Chat(from: protocolChat)
      let lastMsgId = chat.lastMsgId
      chat.lastMsgId = nil
      pendingChats.append(PendingChat(
        protocolChat: protocolChat,
        chat: chat,
        lastMsgId: lastMsgId
      ))
    }

    while !pendingChats.isEmpty {
      var deferredChats: [PendingChat] = []
      var attemptedCount = 0

      for pending in pendingChats {
        if let parentChatId = pending.chat.parentChatId,
           try Chat.fetchOne(db, key: parentChatId) == nil {
          deferredChats.append(pending)
          continue
        }

        attemptedCount += 1
        if let savedChat = try attempt(.chats, in: db, failures: &failures, {
          try pending.chat.saveFull(db)
        }) {
          importedChats[savedChat.id] = ImportedChat(
            chat: savedChat,
            lastMsgId: pending.lastMsgId,
            bucketKey: pending.protocolChat.hasSeq
              ? .chat(peer: pending.protocolChat.peerID)
              : nil,
            bucketSequence: pending.protocolChat.hasSeq
              ? Int64(pending.protocolChat.seq)
              : nil
          )
        } else {
          incompleteChatIDs.insert(pending.chat.id)
        }
      }

      guard attemptedCount > 0 else {
        failures.record(.chats, count: deferredChats.count)
        incompleteChatIDs.formUnion(deferredChats.map { $0.chat.id })
        break
      }
      pendingChats = deferredChats
    }

    for message in result.messages {
      guard message.id > 0, message.chatID > 0 else {
        failures.record(.messages)
        incompleteChatIDs.insert(message.chatID)
        continue
      }
      guard validPeer(message.peerID) else {
        failures.record(.messages)
        incompleteChatIDs.insert(message.chatID)
        continue
      }
      guard try Chat.fetchOne(db, key: message.chatID) != nil else {
        failures.record(.messages)
        incompleteChatIDs.insert(message.chatID)
        continue
      }

      if try attempt(.messages, in: db, failures: &failures, {
        try Message.save(db, protocolMessage: message, publishChanges: false)
      }) == nil {
        incompleteChatIDs.insert(message.chatID)
      }
    }

    for importedChat in importedChats.values {
      guard let lastMsgId = importedChat.lastMsgId else { continue }
      let hasLastMessage = try Message
        .filter(Column("chatId") == importedChat.chat.id)
        .filter(Column("messageId") == lastMsgId)
        .fetchCount(db) > 0
      guard hasLastMessage else {
        failures.record(.lastMessages)
        incompleteChatIDs.insert(importedChat.chat.id)
        continue
      }

      var updatedChat = importedChat.chat
      updatedChat.lastMsgId = lastMsgId
      if try attempt(.lastMessages, in: db, failures: &failures, {
        try updatedChat.saveFull(db)
      }) == nil {
        incompleteChatIDs.insert(importedChat.chat.id)
      }
    }

    for folder in result.folders {
      guard folder.id > 0, !folder.order.isEmpty else {
        failures.record(.folders)
        continue
      }
      _ = try attempt(.folders, in: db, failures: &failures) {
        try folder.saveFull(db)
      }
    }

    for dialog in result.dialogs {
      guard validPeer(dialog.peer) else {
        failures.record(.dialogs)
        continue
      }
      if try attempt(.dialogs, in: db, failures: &failures, {
        try dialog.saveFull(db)
      }) == nil, let chatId = referencedChatID(in: dialog) {
        incompleteChatIDs.insert(chatId)
      }
    }

    for importedChat in importedChats.values {
      guard !incompleteChatIDs.contains(importedChat.chat.id),
            let bucketKey = importedChat.bucketKey,
            let bucketSequence = importedChat.bucketSequence
      else { continue }

      if let state = try attempt(.chatCursors, in: db, failures: &failures, {
        try GRDBSyncStorage.seedSnapshotBucketState(
          for: bucketKey,
          seq: bucketSequence,
          in: db
        )
      }) {
        bucketStates[bucketKey] = state
      }
    }

    return SnapshotImportResult(
      bucketStates: bucketStates,
      failures: failures.reports
    )
  }

  private static func attempt<T>(
    _ phase: SnapshotImportPhase,
    in db: Database,
    failures: inout SnapshotFailureAccumulator,
    _ body: () throws -> T
  ) throws -> T? {
    do {
      var value: T?
      try db.inSavepoint {
        value = try body()
        return .commit
      }
      return value
    } catch {
      guard isRecoverableRecordError(error) else { throw error }
      failures.record(phase)
      return nil
    }
  }

  static func isRecoverableRecordError(_ error: any Error) -> Bool {
    guard let databaseError = error as? DatabaseError else { return false }
    return databaseError.resultCode == .SQLITE_CONSTRAINT ||
      databaseError.resultCode == .SQLITE_MISMATCH
  }

  private static func referencedChatID(in dialog: InlineProtocol.Dialog) -> Int64? {
    if dialog.hasChatID { return dialog.chatID }
    if case let .chat(chatPeer) = dialog.peer.type { return chatPeer.chatID }
    return nil
  }

  private static func validPeer(_ peer: InlineProtocol.Peer) -> Bool {
    switch peer.type {
    case let .user(user): user.userID > 0
    case let .chat(chat): chat.chatID > 0
    case .none: false
    }
  }

  private static func report(_ failures: [SnapshotImportFailure]) {
    for failure in failures {
      Log.scoped("GetChatsSnapshot-\(failure.phase.rawValue)")
        .error("Skipped invalid getChats records", error: failure)
    }
  }

  struct SnapshotImportResult: Sendable {
    var bucketStates: [BucketKey: BucketState]
    var failures: [SnapshotImportFailure]
  }

  struct SnapshotImportFailure: Error, Hashable, LocalizedError, Sendable {
    var phase: SnapshotImportPhase
    var count: Int

    var errorDescription: String? {
      "getChats skipped \(count) invalid \(phase.rawValue) record(s)"
    }
  }

  enum SnapshotImportPhase: String, Hashable, Sendable {
    case spaces
    case spaceCursors
    case users
    case chats
    case messages
    case lastMessages
    case folders
    case dialogs
    case chatCursors
  }

  private struct SnapshotFailureAccumulator {
    private var counts: [SnapshotImportPhase: Int] = [:]

    mutating func record(
      _ phase: SnapshotImportPhase,
      count: Int = 1
    ) {
      counts[phase, default: 0] += count
    }

    var reports: [SnapshotImportFailure] {
      counts.map { phase, count in
        SnapshotImportFailure(phase: phase, count: count)
      }
      .sorted { $0.phase.rawValue < $1.phase.rawValue }
    }
  }

  private struct PendingChat {
    var protocolChat: InlineProtocol.Chat
    var chat: Chat
    var lastMsgId: Int64?
  }

  private struct ImportedChat {
    var chat: Chat
    var lastMsgId: Int64?
    var bucketKey: BucketKey?
    var bucketSequence: Int64?
  }
}

// Helper

public extension Transaction2 where Self == GetChatsTransaction {
  static func getChats() -> GetChatsTransaction {
    GetChatsTransaction()
  }
}
