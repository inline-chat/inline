import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct MarkAsUnreadTransaction: Transaction2 {
  // Properties
  public var method: InlineProtocol.Method = .markAsUnread
  public var context: Context

  public struct Context: Sendable, Codable {
    let peerId: Peer
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  // Private
  private var log = Log.scoped("Transactions/MarkAsUnread")

  public init(peerId: Peer) {
    context = Context(peerId: peerId)
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

  public func optimistic() async {}

  public func apply(_ rpcResult: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .markAsUnread(result) = rpcResult else {
      throw TransactionExecutionError.invalid
    }

    log.trace("result: \(result)")
    await Api.realtime.applyUpdates(result.updates)
  }
}

// Helper

public extension Transaction2 where Self == MarkAsUnreadTransaction {
  static func markAsUnread(peerId: Peer) -> MarkAsUnreadTransaction {
    MarkAsUnreadTransaction(peerId: peerId)
  }
}
