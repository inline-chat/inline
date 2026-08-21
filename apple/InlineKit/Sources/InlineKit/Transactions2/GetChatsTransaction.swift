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

    log.trace("getChats result: \(result)")

    // Apply to database/UI

    do {
      let bucketStates = try await AppDatabase.shared.dbWriter.write { db in
        try Self.applySnapshot(result, in: db)
      }
      await Api.realtime.installSnapshotBucketStates(bucketStates)
    } catch {
      Log.shared.error("Failed to apply getChats snapshot", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  static func applySnapshot(
    _ result: InlineProtocol.GetChatsResult,
    in db: Database
  ) throws -> [BucketKey: BucketState] {
    var bucketStates: [BucketKey: BucketState] = [:]

    // Save spaces
    for space in result.spaces {
      let spaceModel = Space(from: space)
      try spaceModel.save(db)
      if space.hasSeq {
        bucketStates[.space(id: space.id)] = try GRDBSyncStorage.seedSnapshotBucketState(
          for: .space(id: space.id),
          seq: Int64(space.seq),
          in: db
        )
      }
    }

    // Save users
    for user in result.users {
      _ = try User.save(db, user: user)
    }

    // First save chats without lastMsgId to avoid foreign key constraint
    var chatsToUpdate: [(Chat, Int64?)] = []
    for chat in result.chats {
      var chatModel = Chat(from: chat)
      let lastMsgId = chatModel.lastMsgId
      chatModel.lastMsgId = nil // Temporarily remove lastMsgId
      _ = try chatModel.saveFull(db)
      chatsToUpdate.append((chatModel, lastMsgId))
      if chat.hasSeq {
        bucketStates[.chat(peer: chat.peerID)] = try GRDBSyncStorage.seedSnapshotBucketState(
          for: .chat(peer: chat.peerID),
          seq: Int64(chat.seq),
          in: db
        )
      }
    }

    // Save messages
    for message in result.messages {
      _ = try Message.save(db, protocolMessage: message, publishChanges: false)
    }

    // Now update chats with lastMsgId since messages exist
    for (chat, lastMsgId) in chatsToUpdate {
      var updatedChat = chat
      updatedChat.lastMsgId = lastMsgId
      _ = try updatedChat.saveFull(db)
    }

    // Save folders before dialogs so dialog foreign keys resolve in the same snapshot.
    for folder in result.folders {
      try folder.saveFull(db)
    }

    // Save dialogs
    for dialog in result.dialogs {
      try dialog.saveFull(db)
    }

    return bucketStates
  }
}

// Helper

public extension Transaction2 where Self == GetChatsTransaction {
  static func getChats() -> GetChatsTransaction {
    GetChatsTransaction()
  }
}
