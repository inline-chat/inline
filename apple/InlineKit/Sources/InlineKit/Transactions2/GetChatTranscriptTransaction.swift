import Foundation
import InlineProtocol
import Logger
import RealtimeV2

public struct GetChatTranscriptTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/GetChatTranscript")

  public var method: InlineProtocol.Method = .getChatTranscript
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    public var peer: Peer
    public var beforeMessageID: Int64?
    public var limit: Int32?
  }

  public init(peer: Peer, beforeMessageID: Int64? = nil, limit: Int32? = nil) {
    context = Context(peer: peer, beforeMessageID: beforeMessageID, limit: limit)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .getChatTranscript(.with {
      $0.peerID = context.peer.toInputPeer()
      $0.mode = .humanReadable
      $0.length = .concise
      $0.media = .included
      if let beforeMessageID = context.beforeMessageID {
        $0.beforeMessageID = beforeMessageID
      }
      if let limit = context.limit {
        $0.limit = limit
      }
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func optimistic() async {}

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .getChatTranscript = result else {
      throw TransactionExecutionError.invalid
    }
  }

  public func failed(error: TransactionError2) async {
    log.error("Failed to get chat transcript", error: error)
  }

  public func cancelled() async {}
}

public extension Transaction2 where Self == GetChatTranscriptTransaction {
  static func getChatTranscript(
    peer: Peer,
    beforeMessageID: Int64? = nil,
    limit: Int32? = nil
  ) -> GetChatTranscriptTransaction {
    GetChatTranscriptTransaction(peer: peer, beforeMessageID: beforeMessageID, limit: limit)
  }
}
