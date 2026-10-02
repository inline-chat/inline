import Foundation
import InlineProtocol
import RealtimeV2

public struct ForwardMessagesTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .forwardMessages
  public var context: Context
  public var type: TransactionKindType = .mutation()

  /// Persist these alongside the complete ordered selection before forwarding.
  public struct Submission: Sendable, Codable, Equatable {
    public var randomId: Int64
    public var expectedSourceRevision: Int64
    public var expectedSourceSnapshot: String?

    public init(
      expectedSourceRevision: Int64,
      expectedSourceSnapshot: String? = nil,
      randomId: Int64 = Int64.random(in: 1 ... Int64.max)
    ) {
      self.randomId = randomId
      self.expectedSourceRevision = expectedSourceRevision
      self.expectedSourceSnapshot = expectedSourceSnapshot
    }
  }

  public struct Receipt: Sendable, Codable, Equatable {
    public var sourceMessageId: Int64
    public var randomId: Int64
    public var messageId: Int64
    public var sourceRevision: Int64
  }

  public struct Context: Sendable, Codable {
    public var fromPeerId: Peer
    public var toPeerId: Peer
    public var messageIds: [Int64]
    public var shareForwardHeader: Bool?
    public var submissions: [Submission]?

    public init(
      fromPeerId: Peer,
      toPeerId: Peer,
      messageIds: [Int64],
      shareForwardHeader: Bool?,
      submissions: [Submission]? = nil
    ) {
      self.fromPeerId = fromPeerId
      self.toPeerId = toPeerId
      self.messageIds = messageIds
      self.shareForwardHeader = shareForwardHeader
      self.submissions = submissions
    }
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public init(
    fromPeerId: Peer,
    toPeerId: Peer,
    messageIds: [Int64],
    shareForwardHeader: Bool? = nil,
    submissions: [Submission]? = nil
  ) {
    context = Context(
      fromPeerId: fromPeerId,
      toPeerId: toPeerId,
      messageIds: messageIds,
      shareForwardHeader: shareForwardHeader,
      submissions: submissions
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
      $0.submissions = (context.submissions ?? []).map { submission in
        .with {
          $0.randomID = submission.randomId
          $0.expectedSourceRevision = submission.expectedSourceRevision
          if let snapshot = submission.expectedSourceSnapshot {
            $0.expectedSourceSnapshot = snapshot
          }
        }
      }
    })
  }

  /// A complete receipt is required before a promotion may activate its worker.
  /// Empty legacy/old-server results cannot prove that the selected seed landed.
  public func receipts(from response: InlineProtocol.ForwardMessagesResult) throws(
    TransactionExecutionError
  ) -> [Receipt] {
    guard let submissions = context.submissions,
          submissions.count == context.messageIds.count,
          response.receipts.count == context.messageIds.count
    else {
      throw .invalid
    }
    var receipts: [Receipt] = []
    var destinationIds = Set<Int64>()
    for (index, receipt) in response.receipts.enumerated() {
      let submission = submissions[index]
      guard receipt.sourceMessageID == context.messageIds[index],
            receipt.randomID == submission.randomId,
            receipt.sourceRevision == submission.expectedSourceRevision,
            !receipt.messageDeleted,
            receipt.messageID > 0,
            destinationIds.insert(receipt.messageID).inserted
      else {
        throw .invalid
      }
      receipts.append(Receipt(
        sourceMessageId: receipt.sourceMessageID,
        randomId: receipt.randomID,
        messageId: receipt.messageID,
        sourceRevision: receipt.sourceRevision
      ))
    }
    return receipts
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(
    TransactionExecutionError
  ) {
    guard case let .forwardMessages(response) = result else {
      throw TransactionExecutionError.invalid
    }

    if context.submissions != nil {
      _ = try receipts(from: response)
    }

    await Api.realtime.applyUpdates(response.updates)
  }
}

public extension Transaction2 where Self == ForwardMessagesTransaction {
  static func forwardMessages(
    fromPeerId: Peer,
    toPeerId: Peer,
    messageIds: [Int64],
    shareForwardHeader: Bool? = nil,
    submissions: [ForwardMessagesTransaction.Submission]? = nil
  ) -> ForwardMessagesTransaction {
    ForwardMessagesTransaction(
      fromPeerId: fromPeerId,
      toPeerId: toPeerId,
      messageIds: messageIds,
      shareForwardHeader: shareForwardHeader,
      submissions: submissions
    )
  }
}
