import Foundation
import InlineProtocol
import Logger
import RealtimeV2

public struct ReadMessagesTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .readMessages
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

  private var log = Log.scoped("Transactions/ReadMessages")

  public init(peerId: Peer, maxId: Int64?) {
    context = Context(peerId: peerId, maxId: maxId, intentId: UUID().uuidString)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .readMessages(.with {
      $0.peerID = context.peerId.toInputPeer()
      if let maxId = context.maxId {
        $0.maxID = maxId
      }
    })
  }

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
        dialog.unreadCount = 0
        dialog.unreadMark = false
        try dialog.save(db, onConflict: .replace)
      }
    } catch {
      await DialogMutationRollbackTracker.shared.complete(
        intentID: context.intentId,
        peer: context.peerId,
        kind: .read
      )
      log.error("Failed to optimistically mark dialog as read", error: error)
    }
  }

  public func apply(_ rpcResult: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .readMessages(result) = rpcResult else {
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
    log.error("ReadMessages transaction failed", error: error)
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
      log.error("Failed to roll back read state", error: error)
    }
  }
}

public extension Transaction2 where Self == ReadMessagesTransaction {
  static func readMessages(peerId: Peer, maxId: Int64? = nil) -> ReadMessagesTransaction {
    ReadMessagesTransaction(peerId: peerId, maxId: maxId)
  }
}
