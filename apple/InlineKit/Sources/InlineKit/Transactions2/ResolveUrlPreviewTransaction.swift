import Foundation
import InlineProtocol
import RealtimeV2

public struct ResolveUrlPreviewTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .resolveURLPreview
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    public var peer: Peer
    public var url: String
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public init(peer: Peer, url: String) {
    context = Context(peer: peer, url: url)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .resolveURLPreview(.with {
      $0.peerID = context.peer.toInputPeer()
      $0.url = context.url
    })
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .resolveURLPreview = result else {
      throw TransactionExecutionError.invalid
    }
  }
}

public extension Transaction2 where Self == ResolveUrlPreviewTransaction {
  static func resolveURLPreview(peer: Peer, url: String) -> ResolveUrlPreviewTransaction {
    ResolveUrlPreviewTransaction(peer: peer, url: url)
  }
}
