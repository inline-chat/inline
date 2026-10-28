import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

/// Unpins every message in a chat with one request, so the header clears in one step.
public struct UnpinAllMessagesTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .unpinAllMessages
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public var peer: Peer
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  private var log = Log.scoped("Transactions/UnpinAllMessages")

  public init(peer: Peer) {
    context = Context(peer: peer)
  }

  public var executionKey: TransactionExecutionKey? {
    .peerMutation(context.peer)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .unpinAllMessages(.with {
      $0.peerID = context.peer.toInputPeer()
    })
  }

  public func optimistic() async {
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        guard let chat = try Chat.getByPeerId(db: db, peerId: context.peer) else {
          log.warning("Failed to resolve chat for optimistic unpin all")
          return
        }

        try PinnedMessage.replaceAll(db, chatId: chat.id, messageIds: [])
      }
    } catch {
      log.error("Failed to optimistically unpin all messages", error: error)
    }
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .unpinAllMessages(response) = result else {
      throw TransactionExecutionError.invalid
    }

    await Api.realtime.applyUpdates(response.updates)
  }

  public func failed(error: TransactionError2) async {
    log.error("UnpinAllMessages transaction failed", error: error)
  }
}

public extension Transaction2 where Self == UnpinAllMessagesTransaction {
  static func unpinAllMessages(peer: Peer) -> UnpinAllMessagesTransaction {
    UnpinAllMessagesTransaction(peer: peer)
  }
}
