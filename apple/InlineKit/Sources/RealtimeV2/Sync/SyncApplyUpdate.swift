import InlineProtocol

public enum UpdateApplySource: Sendable, Equatable {
  case realtime
  case syncCatchup
}

public struct UpdateApplyResult: Sendable {
  public let appliedCount: Int
  public let failedCount: Int
  public let committedBucketState: BucketState?

  public var succeeded: Bool {
    failedCount == 0
  }

  public init(
    appliedCount: Int,
    failedCount: Int,
    committedBucketState: BucketState? = nil
  ) {
    self.appliedCount = appliedCount
    self.failedCount = failedCount
    self.committedBucketState = committedBucketState
  }

  public static func success(count: Int) -> UpdateApplyResult {
    UpdateApplyResult(appliedCount: count, failedCount: 0)
  }
}

public struct UpdateBucketCommit: Sendable {
  public let key: BucketKey
  public let state: BucketState

  public init(key: BucketKey, state: BucketState) {
    self.key = key
    self.state = state
  }
}

public struct ChatRepairSnapshot: Sendable {
  public let peer: InlineProtocol.Peer
  public let chat: InlineProtocol.GetChatResult
  public let participants: InlineProtocol.GetChatParticipantsResult
  public let history: InlineProtocol.GetChatHistoryResult
  public let targetState: BucketState
  public let reason: String

  public init(
    peer: InlineProtocol.Peer,
    chat: InlineProtocol.GetChatResult,
    participants: InlineProtocol.GetChatParticipantsResult,
    history: InlineProtocol.GetChatHistoryResult,
    targetState: BucketState,
    reason: String
  ) {
    self.peer = peer
    self.chat = chat
    self.participants = participants
    self.history = history
    self.targetState = targetState
    self.reason = reason
  }
}

/// Protocol for applying updates within the Sync actor context
public protocol ApplyUpdates: Sendable {
  /// Apply a batch of updates to the database
  func apply(
    updates: [InlineProtocol.Update],
    source: UpdateApplySource,
    sidecars: InlineProtocol.UpdateSidecars?
  ) async -> UpdateApplyResult

  /// Apply a bounded current-state repair for a chat bucket.
  func repairChat(_ snapshot: ChatRepairSnapshot) async -> BucketState?
}

public extension ApplyUpdates {
  func apply(updates: [InlineProtocol.Update], source: UpdateApplySource) async -> UpdateApplyResult {
    await apply(updates: updates, source: source, sidecars: nil)
  }

  func repairChat(_ snapshot: ChatRepairSnapshot) async -> BucketState? {
    nil
  }

  func apply(
    updates: [InlineProtocol.Update],
    source: UpdateApplySource,
    sidecars: InlineProtocol.UpdateSidecars?,
    bucketCommit: UpdateBucketCommit?
  ) async -> UpdateApplyResult {
    await apply(updates: updates, source: source, sidecars: sidecars)
  }
}
