import Foundation
import InlineProtocol
import Logger
import RealtimeV2

public struct DeleteMessageAttachmentTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/DeleteMessageAttachment")

  public var method: InlineProtocol.Method = .deleteMessageAttachment
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public let peerId: Peer
    public let messageId: Int64
    public let attachmentId: Int64
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public init(peerId: Peer, messageId: Int64, attachmentId: Int64) {
    context = Context(peerId: peerId, messageId: messageId, attachmentId: attachmentId)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .deleteMessageAttachment(.with {
      $0.peerID = context.peerId.toInputPeer()
      $0.messageID = context.messageId
      $0.attachmentID = context.attachmentId
    })
  }

  public func optimistic() async {}

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .deleteMessageAttachment(response) = result else {
      throw TransactionExecutionError.invalid
    }

    await Api.realtime.applyUpdates(response.updates)
  }

  public func failed(error: TransactionError2) async {
    log.error("DeleteMessageAttachment transaction failed", error: error)
  }
}

public extension Transaction2 where Self == DeleteMessageAttachmentTransaction {
  static func deleteMessageAttachment(
    peerId: Peer,
    messageId: Int64,
    attachmentId: Int64
  ) -> DeleteMessageAttachmentTransaction {
    DeleteMessageAttachmentTransaction(peerId: peerId, messageId: messageId, attachmentId: attachmentId)
  }
}
