import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

/// Durable state remains server-owned. Existing transaction-journal metadata
/// identifies one ephemeral resident-row projection; it is never written to
/// the acknowledgement table.
public struct AcknowledgeMessagesTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .acknowledgeMessages
  public var type: TransactionKindType = .mutation()
  public var context: Context

  public struct Context: Codable, Sendable {
    public var peerId: Peer
    public var chatId: Int64
    public var maxId: Int64
    public var clear: Bool
    public var expectedRevision: Int64
    public var userId: Int64
    public var previousAcknowledgement: Acknowledgement?
    public var optimisticRequestId: UUID

    enum CodingKeys: String, CodingKey {
      case peerId
      case chatId
      case maxId
      case clear
      case expectedRevision
      case userId
      case previousAcknowledgement
      case optimisticRequestId
    }

    public init(
      peerId: Peer,
      chatId: Int64,
      maxId: Int64,
      clear: Bool,
      expectedRevision: Int64,
      userId: Int64,
      previousAcknowledgement: Acknowledgement?,
      optimisticRequestId: UUID
    ) {
      self.peerId = peerId
      self.chatId = chatId
      self.maxId = maxId
      self.clear = clear
      self.expectedRevision = expectedRevision
      self.userId = userId
      self.previousAcknowledgement = previousAcknowledgement
      self.optimisticRequestId = optimisticRequestId
    }

    public init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      peerId = try values.decode(Peer.self, forKey: .peerId)
      chatId = try values.decode(Int64.self, forKey: .chatId)
      maxId = try values.decode(Int64.self, forKey: .maxId)
      clear = try values.decodeIfPresent(Bool.self, forKey: .clear) ?? false
      expectedRevision = try values.decodeIfPresent(Int64.self, forKey: .expectedRevision) ?? 0
      userId = try values.decodeIfPresent(Int64.self, forKey: .userId) ?? 0
      previousAcknowledgement = try values.decodeIfPresent(
        Acknowledgement.self,
        forKey: .previousAcknowledgement
      )
      optimisticRequestId = try values.decodeIfPresent(UUID.self, forKey: .optimisticRequestId) ?? UUID()
    }
  }

  public init(
    message: FullMessage,
    action: AcknowledgementAction,
    currentUserId: Int64? = Auth.shared.getCurrentUserId(),
    optimisticRequestId: UUID = UUID()
  ) {
    let userId = currentUserId ?? 0
    context = Context(
      peerId: message.peerId,
      chatId: message.chatId,
      maxId: message.message.messageId,
      clear: action.clear,
      expectedRevision: action.expectedRevision,
      userId: userId,
      previousAcknowledgement: message.currentUserAcknowledgement?.userId == userId
        ? message.currentUserAcknowledgement
        : message.acknowledgementState(for: userId),
      optimisticRequestId: optimisticRequestId
    )
  }

  public var executionKey: TransactionExecutionKey? { .chatMutation(chatID: context.chatId) }
  public var reconnectReplayPolicy: TransactionReconnectPolicy? { .replaySafe }

  public func optimistic() async {
    guard context.userId > 0,
          Auth.shared.getCurrentUserId() == context.userId else { return }
    let admitted = await MainActor.run {
      MessagesPublisher.shared.beginOptimisticAcknowledgement(
        requestId: context.optimisticRequestId,
        chatId: context.chatId,
        userId: context.userId,
        maxId: context.maxId,
        cleared: context.clear,
        peer: context.peerId,
        animated: true
      )
    }
    guard admitted else { return }

    let userInfo = await loadCurrentUserInfo()
    await MainActor.run {
      guard Auth.shared.getCurrentUserId() == context.userId else { return }
      MessagesPublisher.shared.enrichOptimisticAcknowledgement(
        requestId: context.optimisticRequestId,
        chatId: context.chatId,
        userId: context.userId,
        userInfo: userInfo,
        peer: context.peerId,
        animated: false
      )
    }
  }

  public func validateOptimisticState() async -> Bool {
    await MainActor.run {
      MessagesPublisher.shared.hasOptimisticAcknowledgement(
        requestId: context.optimisticRequestId,
        chatId: context.chatId,
        userId: context.userId
      )
    }
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .acknowledgeMessages(.with {
      $0.peerID = context.peerId.toInputPeer()
      $0.maxID = context.maxId
      $0.clear = context.clear
      $0.expectedRevision = context.expectedRevision
    })
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .acknowledgeMessages(response) = result else { throw TransactionExecutionError.invalid }
    await Api.realtime.applyUpdatesAndWait(response.updates)
    // Always project the canonical post-reducer row. A stale RPC response may
    // be rejected by the revision fence and must not bypass it in memory.
    if let confirmed = await loadCanonicalAcknowledgement() {
      await MainActor.run {
        guard Auth.shared.getCurrentUserId() == context.userId else { return }
        MessagesPublisher.shared.acknowledgementsChanged([confirmed], peer: context.peerId, animated: true)
      }
    } else {
      await restoreOptimisticProjection()
    }
  }

  public func failed(error: TransactionError2) async {
    Log.scoped("Transactions/Acknowledgement").error("Acknowledgement transaction failed", error: error)
    await restoreOptimisticProjection()
  }

  public func cancelled() async {
    await restoreOptimisticProjection()
  }

  public func commitOutcomeUnknown() async {
    Log.scoped("Transactions/Acknowledgement")
      .warning("Acknowledgement outcome is unknown; preserving optimistic projection")
  }

  private func restoreOptimisticProjection() async {
    guard context.userId > 0 else { return }
    let userInfo = context.previousAcknowledgement == nil ? nil : await loadCurrentUserInfo()
    let previous = context.previousAcknowledgement.map {
      FullAcknowledgement(acknowledgement: $0, userInfo: userInfo)
    }
    await MainActor.run {
      MessagesPublisher.shared.restoreOptimisticAcknowledgement(
        requestId: context.optimisticRequestId,
        chatId: context.chatId,
        userId: context.userId,
        previous: previous,
        peer: context.peerId,
        animated: true
      )
    }
  }

  private func loadCurrentUserInfo() async -> UserInfo? {
    try? await AppDatabase.shared.reader.read { db in
      try User.userInfoQuery().filter(Column("id") == context.userId).fetchOne(db)
    }
  }

  private func loadCanonicalAcknowledgement() async -> FullAcknowledgement? {
    try? await AppDatabase.shared.reader.read { db in
      guard let acknowledgement = try Acknowledgement
        .filter(
          Acknowledgement.Columns.chatId == context.chatId
            && Acknowledgement.Columns.userId == context.userId
        )
        .fetchOne(db)
      else { return nil }
      let userInfo = try User.userInfoQuery()
        .filter(Column("id") == context.userId)
        .fetchOne(db)
      return FullAcknowledgement(acknowledgement: acknowledgement, userInfo: userInfo)
    }
  }
}

extension AcknowledgeMessagesTransaction: Codable {
  enum CodingKeys: String, CodingKey { case context }
}

public extension Transaction2 where Self == AcknowledgeMessagesTransaction {
  static func acknowledgeMessages(
    message: FullMessage,
    action: AcknowledgementAction
  ) -> AcknowledgeMessagesTransaction {
    AcknowledgeMessagesTransaction(message: message, action: action)
  }
}
