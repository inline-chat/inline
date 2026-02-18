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
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  private var log = Log.scoped("Transactions/ReadMessages")

  public init(peerId: Peer, maxId: Int64?) {
    context = Context(peerId: peerId, maxId: maxId)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .readMessages(.with {
      $0.peerID = context.peerId.toInputPeer()
      if let maxId = context.maxId {
        $0.maxID = maxId
      }
    })
  }

  public func apply(_ rpcResult: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .readMessages(result) = rpcResult else {
      throw TransactionExecutionError.invalid
    }

    log.trace("result: \(result)")
    await Api.realtime.applyUpdates(result.updates)
  }
}

public extension Transaction2 where Self == ReadMessagesTransaction {
  static func readMessages(peerId: Peer, maxId: Int64? = nil) -> ReadMessagesTransaction {
    ReadMessagesTransaction(peerId: peerId, maxId: maxId)
  }
}
