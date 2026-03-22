import Foundation
import InlineProtocol
import Logger
import RealtimeV2

public struct InvokeMessageActionTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/InvokeMessageAction")

  public var method: InlineProtocol.Method = .invokeMessageAction
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    public let peerId: Peer
    public let messageId: Int64
    public let actionId: String
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public init(peerId: Peer, messageId: Int64, actionId: String) {
    context = Context(
      peerId: peerId,
      messageId: messageId,
      actionId: actionId.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .invokeMessageAction(.with {
      $0.peerID = context.peerId.toInputPeer()
      $0.messageID = context.messageId
      $0.actionID = context.actionId
    })
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .invokeMessageAction = result else {
      throw TransactionExecutionError.invalid
    }
  }

  public func failed(error: TransactionError2) async {
    log.error("InvokeMessageAction transaction failed", error: error)
  }
}

public extension Transaction2 where Self == InvokeMessageActionTransaction {
  static func invokeMessageAction(
    peerId: Peer,
    messageId: Int64,
    actionId: String
  ) -> InvokeMessageActionTransaction {
    InvokeMessageActionTransaction(
      peerId: peerId,
      messageId: messageId,
      actionId: actionId
    )
  }
}
