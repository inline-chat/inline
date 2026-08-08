import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct CollapseHistoryTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .collapseHistory
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    let peerId: Peer
    let maxId: Int64?
    let intentId: String?
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  private var log = Log.scoped("Transactions/CollapseHistory")

  public init(peerId: Peer, maxId: Int64?) {
    context = Context(peerId: peerId, maxId: maxId, intentId: UUID().uuidString)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .collapseHistory(.with {
      $0.peerID = context.peerId.toInputPeer()
      if let maxId = context.maxId {
        $0.maxID = maxId
      }
    })
  }

  /// Uses both the chat pointer and locally materialized server messages. `lastMsgId` can
  /// temporarily point at a negative optimistic message, so it is not sufficient by itself.
  public static func maxMessageIdForClear(_ db: Database, chatId: Int64) throws -> Int64? {
    let chatLastMsgId = try Chat.fetchOne(db, id: chatId)?.lastMsgId ?? 0
    let localMaxMessageId = try Message
      .filter(Message.Columns.chatId == chatId)
      .filter(Message.Columns.messageId > 0)
      .select(max(Message.Columns.messageId))
      .asRequest(of: Int64.self)
      .fetchOne(db) ?? 0
    let maxId = Swift.max(chatLastMsgId, localMaxMessageId)
    return maxId > 0 ? maxId : nil
  }

  public func optimistic() async {
    do {
      let original = try await AppDatabase.shared.reader.read { db in
        try Dialog.get(peerId: context.peerId).fetchOne(db)
      }
      await DialogMutationRollbackTracker.shared.record(
        intentID: context.intentId,
        peer: context.peerId,
        kind: .collapse,
        original: original
      )

      try await AppDatabase.shared.dbWriter.write { db in
        guard var dialog = try Dialog.get(peerId: context.peerId).fetchOne(db) else { return }
        if let maxId = context.maxId {
          dialog.collapsedMaxId = max(dialog.collapsedMaxId ?? 0, maxId)
          let now = Date()
          dialog.collapsedAt = dialog.collapsedAt.map { existing in
            existing >= now ? existing.addingTimeInterval(0.001) : now
          } ?? now
          dialog.readInboxMaxId = max(dialog.readInboxMaxId ?? 0, maxId)
          dialog.unreadCount = 0
          dialog.unreadMark = false
        } else {
          dialog.collapsedMaxId = nil
          dialog.collapsedAt = nil
        }
        try dialog.save(db, onConflict: .replace)
      }
    } catch {
      await DialogMutationRollbackTracker.shared.complete(
        intentID: context.intentId,
        peer: context.peerId,
        kind: .collapse
      )
      log.error("Failed to optimistically update collapsed history", error: error)
    }
  }

  public func apply(_ rpcResult: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .collapseHistory(result) = rpcResult else {
      throw TransactionExecutionError.invalid
    }

    await Api.realtime.applyUpdates(result.updates)
    await DialogMutationRollbackTracker.shared.complete(
      intentID: context.intentId,
      peer: context.peerId,
      kind: .collapse
    )
  }

  public func failed(error: TransactionError2) async {
    log.error("CollapseHistory transaction failed", error: error)
    guard let rollback = await DialogMutationRollbackTracker.shared.takeForRollback(
      intentID: context.intentId,
      peer: context.peerId,
      kind: .collapse
    ), let original = rollback.original else { return }

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        guard var dialog = try Dialog.get(peerId: context.peerId).fetchOne(db) else { return }
        dialog.collapsedMaxId = original.collapsedMaxId
        dialog.collapsedAt = original.collapsedAt
        dialog.readInboxMaxId = original.readInboxMaxId
        dialog.unreadCount = original.unreadCount
        dialog.unreadMark = original.unreadMark
        try dialog.save(db, onConflict: .replace)
      }
    } catch {
      log.error("Failed to roll back collapsed history", error: error)
    }
  }
}

public extension Transaction2 where Self == CollapseHistoryTransaction {
  static func collapseHistory(peerId: Peer, maxId: Int64?) -> CollapseHistoryTransaction {
    CollapseHistoryTransaction(peerId: peerId, maxId: maxId)
  }
}
