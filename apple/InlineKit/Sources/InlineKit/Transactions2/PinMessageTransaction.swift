import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct PinMessageTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .pinMessage
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public var peer: Peer
    public var messageId: Int64
    public var unpin: Bool
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  private var log = Log.scoped("Transactions/PinMessage")

  public init(peer: Peer, messageId: Int64, unpin: Bool) {
    context = Context(peer: peer, messageId: messageId, unpin: unpin)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .pinMessage(.with {
      $0.peerID = context.peer.toInputPeer()
      $0.messageID = context.messageId
      $0.unpin = context.unpin
    })
  }

  public func optimistic() async {
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        guard let chat = try Chat.getByPeerId(peerId: context.peer) else {
          log.warning("Failed to resolve chat for optimistic pin")
          return
        }

        if context.unpin {
          _ = try PinnedMessage
            .filter(Column("chatId") == chat.id)
            .filter(Column("messageId") == context.messageId)
            .deleteAll(db)
          return
        }

        try db.execute(
          sql: "UPDATE pinnedMessage SET position = position + 1 WHERE chatId = ?",
          arguments: [chat.id]
        )

        let pinned = PinnedMessage(chatId: chat.id, messageId: context.messageId, position: 0)
        try pinned.save(db)
      }
    } catch {
      log.error("Failed to optimistically update pin state", error: error)
    }
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .pinMessage(response) = result else {
      throw TransactionExecutionError.invalid
    }

    await Api.realtime.applyUpdates(response.updates)
  }

  public func failed(error: TransactionError2) async {
    log.error("PinMessage transaction failed", error: error)
  }
}

public extension Transaction2 where Self == PinMessageTransaction {
  static func pinMessage(peer: Peer, messageId: Int64, unpin: Bool) -> PinMessageTransaction {
    PinMessageTransaction(peer: peer, messageId: messageId, unpin: unpin)
  }
}
