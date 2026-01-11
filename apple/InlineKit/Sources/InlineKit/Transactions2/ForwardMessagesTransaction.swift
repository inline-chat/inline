import Foundation
import InlineProtocol
import RealtimeV2

public struct ForwardMessagesTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .forwardMessages
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public var fromPeerId: Peer
    public var toPeerId: Peer
    public var messageIds: [Int64]
    public var shareForwardHeader: Bool?

    public init(
      fromPeerId: Peer,
      toPeerId: Peer,
      messageIds: [Int64],
      shareForwardHeader: Bool?
    ) {
      self.fromPeerId = fromPeerId
      self.toPeerId = toPeerId
      self.messageIds = messageIds
      self.shareForwardHeader = shareForwardHeader
    }
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public init(
    fromPeerId: Peer,
    toPeerId: Peer,
    messageIds: [Int64],
    shareForwardHeader: Bool? = nil
  ) {
    context = Context(
      fromPeerId: fromPeerId,
      toPeerId: toPeerId,
      messageIds: messageIds,
      shareForwardHeader: shareForwardHeader
    )
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .forwardMessages(.with {
      $0.fromPeerID = context.fromPeerId.toInputPeer()
      $0.toPeerID = context.toPeerId.toInputPeer()
      $0.messageIds = context.messageIds
      if let shareForwardHeader = context.shareForwardHeader {
        $0.shareForwardHeader = shareForwardHeader
      }
    })
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(
    TransactionExecutionError
  ) {
    guard case let .forwardMessages(response) = result else {
      throw TransactionExecutionError.invalid
    }

    await Api.realtime.applyUpdates(response.updates)
  }
}

public extension Transaction2 where Self == ForwardMessagesTransaction {
  static func forwardMessages(
    fromPeerId: Peer,
    toPeerId: Peer,
    messageIds: [Int64],
    shareForwardHeader: Bool? = nil
  ) -> ForwardMessagesTransaction {
    ForwardMessagesTransaction(
      fromPeerId: fromPeerId,
      toPeerId: toPeerId,
      messageIds: messageIds,
      shareForwardHeader: shareForwardHeader
    )
  }
}
