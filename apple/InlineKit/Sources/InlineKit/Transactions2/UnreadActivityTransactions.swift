import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

/// Reads mentions and reactions: the messages seen on screen, or every unread one of a kind.
/// Applied locally first; the server's update on the ordered stream confirms, a failure rolls back.
public struct ReadActivityTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .readActivity
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    let peerId: Peer
    let chatId: Int64
    let messageIds: [Int64]
    let allMentions: Bool
    let allReactions: Bool
    /// Upper bound for the "all" reads, captured when the user asked.
    var maxId: Int64?
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  private var log = Log.scoped("Transactions/ReadActivity")

  public init(peerId: Peer, chatId: Int64, messageIds: [Int64]) {
    context = Context(peerId: peerId, chatId: chatId, messageIds: messageIds, allMentions: false, allReactions: false)
  }

  public init(allIn peerId: Peer, chatId: Int64, kinds: [ChatActivityItem.Kind], maxId: Int64?) {
    context = Context(
      peerId: peerId,
      chatId: chatId,
      messageIds: [],
      allMentions: kinds.contains(.mention),
      allReactions: kinds.contains(.reaction),
      maxId: maxId
    )
  }

  private var allKinds: [ChatActivityItem.Kind] {
    (context.allMentions ? [.mention] : []) + (context.allReactions ? [.reaction] : [])
  }

  public var reconnectReplayPolicy: TransactionReconnectPolicy? { .replaySafe }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .readActivity(.with {
      $0.peerID = context.peerId.toInputPeer()
      $0.messageIds = context.messageIds
      $0.allMentions = context.allMentions
      $0.allReactions = context.allReactions
      if let maxId = context.maxId, context.allMentions || context.allReactions { $0.maxID = maxId }
    })
  }

  public func optimistic() async {
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        try ChatActivityItem.markPendingRead(db, chatId: context.chatId, messageIds: context.messageIds)
        if !allKinds.isEmpty {
          try ChatActivityItem.markAllPendingRead(db, chatId: context.chatId, kinds: allKinds, maxId: context.maxId)
        }
      }
    } catch {
      log.error("Failed to mark activity read locally", error: error)
    }
  }

  /// The result is empty by design; the ordered user stream carries the change.
  public func apply(_ rpcResult: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .readActivity = rpcResult else {
      throw TransactionExecutionError.invalid
    }
  }

  public func failed(error: TransactionError2) async {
    log.error("ReadActivity transaction failed", error: error)
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        let pending = ChatActivityItem
          .filter(ChatActivityItem.Columns.chatId == context.chatId)
          .filter(ChatActivityItem.Columns.pendingRead == true)
        let seen = try pending.filter(context.messageIds.contains(ChatActivityItem.Columns.messageId)).fetchAll(db)
        let all = try pending
          .filter(allKinds.map(\.rawValue).contains(ChatActivityItem.Columns.kind))
          .filter(ChatActivityItem.Columns.messageId <= (context.maxId ?? Int64.max))
          .fetchAll(db)
        try ChatActivityItem.rollbackPendingRead(db, items: Array(Set(seen + all)))
      }
    } catch {
      log.error("Failed to roll back activity read", error: error)
    }
  }
}

/// Refills one chat's unread mentions or reactions from the server, oldest first.
public struct GetUnreadActivityTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .getUnreadActivity
  public var context: Context
  public var type: TransactionKindType = .ephemeral(EphemeralTransactionConfig(maxQueueAge: 10))

  public struct Context: Sendable, Codable {
    let peerId: Peer
    let chatId: Int64
    let kind: ChatActivityItem.Kind
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public init(peerId: Peer, chatId: Int64, kind: ChatActivityItem.Kind) {
    context = Context(peerId: peerId, chatId: chatId, kind: kind)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .getUnreadActivity(.with {
      $0.peerID = context.peerId.toInputPeer()
      $0.reactions = context.kind == .reaction
    })
  }

  public func apply(_ rpcResult: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .getUnreadActivity(result) = rpcResult else {
      throw TransactionExecutionError.invalid
    }
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        try ChatActivityItem.replaceUnread(
          db,
          chatId: context.chatId,
          kind: context.kind,
          messageIds: result.messageIds,
          complete: result.final
        )
        guard var dialog = try Dialog.get(peerId: context.peerId).fetchOne(db) else { return }
        if dialog.chatId == nil { dialog.chatId = context.chatId }
        let counts = ActivityCounts(
          mentions: Int(result.unreadMentionsCount),
          reactions: Int(result.unreadReactionsCount)
        )
        // A complete list leaves only pending rows the server still counts, so the counts are
        // exact. Otherwise this is a snapshot like any other.
        if result.final {
          try dialog.applyServerActivityCounts(db, counts)
        } else {
          try dialog.applySnapshotActivityCounts(db, counts, existing: dialog)
        }
        try dialog.update(db)
      }
    } catch {
      throw TransactionExecutionError.invalid
    }
  }
}

public extension Transaction2 where Self == ReadActivityTransaction {
  static func readActivity(peerId: Peer, chatId: Int64, messageIds: [Int64]) -> ReadActivityTransaction {
    ReadActivityTransaction(peerId: peerId, chatId: chatId, messageIds: messageIds)
  }

  /// `maxId` bounds the read to messages known when the user asked; nil reads everything.
  static func readAllActivity(
    peerId: Peer,
    chatId: Int64,
    kinds: [ChatActivityItem.Kind],
    maxId: Int64?
  ) -> ReadActivityTransaction {
    ReadActivityTransaction(allIn: peerId, chatId: chatId, kinds: kinds, maxId: maxId)
  }
}

public extension Transaction2 where Self == GetUnreadActivityTransaction {
  static func getUnreadActivity(peerId: Peer, chatId: Int64, kind: ChatActivityItem.Kind) -> GetUnreadActivityTransaction {
    GetUnreadActivityTransaction(peerId: peerId, chatId: chatId, kind: kind)
  }
}
