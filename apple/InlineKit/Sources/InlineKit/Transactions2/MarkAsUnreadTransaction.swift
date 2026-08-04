import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct MarkAsUnreadTransaction: Transaction2 {
  // Properties
  public var method: InlineProtocol.Method = .markAsUnread
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    let peerId: Peer
    let intentId: String?
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  // Private
  private var log = Log.scoped("Transactions/MarkAsUnread")

  public init(peerId: Peer) {
    context = Context(peerId: peerId, intentId: UUID().uuidString)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .markAsUnread(.with {
      $0.peerID = context.peerId.toInputPeer()
    })
  }

  // Computed
  private var peerId: Peer {
    context.peerId
  }

  // MARK: - Transaction Methods

  public func optimistic() async {
    do {
      let original = try await AppDatabase.shared.reader.read { db in
        try Dialog.get(peerId: context.peerId).fetchOne(db)
      }
      await DialogMutationRollbackTracker.shared.record(
        intentID: context.intentId,
        peer: context.peerId,
        kind: .read,
        original: original
      )
      try await AppDatabase.shared.dbWriter.write { db in
        guard var dialog = try Dialog.get(peerId: context.peerId).fetchOne(db) else { return }
        dialog.unreadMark = true
        try dialog.save(db, onConflict: .replace)
      }
    } catch {
      await DialogMutationRollbackTracker.shared.complete(
        intentID: context.intentId,
        peer: context.peerId,
        kind: .read
      )
      log.error("Failed to optimistically mark dialog as unread", error: error)
    }
  }

  public func apply(_ rpcResult: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .markAsUnread(result) = rpcResult else {
      throw TransactionExecutionError.invalid
    }

    log.trace("result: \(result)")
    await Api.realtime.applyUpdates(result.updates)
    await DialogMutationRollbackTracker.shared.complete(
      intentID: context.intentId,
      peer: context.peerId,
      kind: .read
    )
  }

  public func failed(error: TransactionError2) async {
    log.error("MarkAsUnread transaction failed", error: error)
    guard let rollback = await DialogMutationRollbackTracker.shared.takeForRollback(
      intentID: context.intentId,
      peer: context.peerId,
      kind: .read
    ), let original = rollback.original else { return }

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        guard var dialog = try Dialog.get(peerId: context.peerId).fetchOne(db) else { return }
        dialog.unreadCount = original.unreadCount
        dialog.unreadMark = original.unreadMark
        try dialog.save(db, onConflict: .replace)
      }
    } catch {
      log.error("Failed to roll back unread state", error: error)
    }
  }
}

// Helper

public extension Transaction2 where Self == MarkAsUnreadTransaction {
  static func markAsUnread(peerId: Peer) -> MarkAsUnreadTransaction {
    MarkAsUnreadTransaction(peerId: peerId)
  }
}
