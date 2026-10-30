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

  public var executionKey: TransactionExecutionKey? { .readState(context.peerId) }

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
    await UnreadManager.shared.cancelAutomaticReads(in: context.peerId)
    do {
      let snapshot = try await AppDatabase.shared.dbWriter.write { db -> DialogMutationSnapshot? in
        guard var dialog = try Dialog.get(peerId: context.peerId).fetchOne(db) else { return nil }
        let baseline = dialog
        dialog.unreadMark = true
        try dialog.save(db, onConflict: .replace)
        return DialogMutationSnapshot(
          baseline: baseline,
          optimistic: try Dialog.fetchOne(db, id: dialog.id) ?? dialog,
          createdRow: false
        )
      }
      guard let snapshot else { return }
      await DialogMutationRollbackTracker.shared.record(
        intentID: context.intentId,
        peer: context.peerId,
        kind: .read,
        snapshot: snapshot,
        fields: [.unreadMark]
      )
    } catch {
      log.error("Failed to optimistically mark dialog as unread", error: error)
    }
  }

  public func apply(_ rpcResult: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .markAsUnread(result) = rpcResult else {
      throw TransactionExecutionError.invalid
    }

    log.trace("result: \(result)")
    await Api.realtime.applyUpdatesAndWait(result.updates)
    await DialogMutationRollbackTracker.shared.complete(
      intentID: context.intentId,
      peer: context.peerId,
      kind: .read
    )
  }

  // Neither outcome rolls back, so the intent must stop owning its fields.
  public func commitOutcomeUnknown() async {
    await DialogMutationRollbackTracker.shared.complete(intentID: context.intentId, peer: context.peerId, kind: .read)
  }

  public func cancelled() async {
    await DialogMutationRollbackTracker.shared.complete(intentID: context.intentId, peer: context.peerId, kind: .read)
  }

  public func failed(error: TransactionError2) async {
    log.error("MarkAsUnread transaction failed", error: error)
    guard let rollback = await DialogMutationRollbackTracker.shared.takeForRollback(
      intentID: context.intentId,
      peer: context.peerId,
      kind: .read
    ) else { return }

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        try rollback.apply(db)
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
