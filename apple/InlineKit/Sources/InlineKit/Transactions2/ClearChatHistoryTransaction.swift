import Foundation
import InlineProtocol
import Logger
import RealtimeV2

public struct ClearChatHistoryTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/ClearChatHistory")

  public var method: InlineProtocol.Method = .clearChatHistory
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public var peerId: Peer?
    public var spaceId: Int64?
    public var keepLastDays: Int32
    public var deleteReplyThreads: Bool
  }

  public init(peerId: Peer, keepLastDays: Int32, deleteReplyThreads: Bool) {
    context = Context(peerId: peerId, spaceId: nil, keepLastDays: keepLastDays, deleteReplyThreads: deleteReplyThreads)
  }

  public init(spaceId: Int64, keepLastDays: Int32, deleteReplyThreads: Bool) {
    context = Context(peerId: nil, spaceId: spaceId, keepLastDays: keepLastDays, deleteReplyThreads: deleteReplyThreads)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .clearChatHistory_p(.with {
      if let peerId = context.peerId {
        $0.peerID = peerId.toInputPeer()
      }
      if let spaceId = context.spaceId {
        $0.spaceID = spaceId
      }
      $0.keepLastDays = context.keepLastDays
      $0.deleteReplyThreads = context.deleteReplyThreads
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func optimistic() async {}

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .clearChatHistory_p(response) = result else {
      throw TransactionExecutionError.invalid
    }

    await Api.realtime.applyUpdates(response.updates)
  }

  public func failed(error: TransactionError2) async {
    log.error("ClearChatHistory transaction failed", error: error)
  }
}

public extension Transaction2 where Self == ClearChatHistoryTransaction {
  static func clearChatHistory(
    peerId: Peer,
    keepLastDays: Int32,
    deleteReplyThreads: Bool
  ) -> ClearChatHistoryTransaction {
    ClearChatHistoryTransaction(
      peerId: peerId,
      keepLastDays: keepLastDays,
      deleteReplyThreads: deleteReplyThreads
    )
  }

  static func clearChatHistory(
    spaceId: Int64,
    keepLastDays: Int32,
    deleteReplyThreads: Bool
  ) -> ClearChatHistoryTransaction {
    ClearChatHistoryTransaction(
      spaceId: spaceId,
      keepLastDays: keepLastDays,
      deleteReplyThreads: deleteReplyThreads
    )
  }
}
