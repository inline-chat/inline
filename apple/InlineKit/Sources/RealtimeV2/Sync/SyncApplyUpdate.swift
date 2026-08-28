import Auth
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

public struct SpaceRepairSnapshot: Sendable {
  public let spaceID: Int64
  public let snapshot: InlineProtocol.GetSpaceResult
  public let members: InlineProtocol.GetSpaceMembersResult
  public let targetState: BucketState
  public let reason: String

  public init(
    spaceID: Int64,
    snapshot: InlineProtocol.GetSpaceResult,
    members: InlineProtocol.GetSpaceMembersResult,
    targetState: BucketState,
    reason: String
  ) {
    self.spaceID = spaceID
    self.snapshot = snapshot
    self.members = members
    self.targetState = targetState
    self.reason = reason
  }
}

public struct UserRepairSnapshot: Sendable {
  public let chats: InlineProtocol.GetChatsResult
  public let me: InlineProtocol.GetMeResult
  public let settings: InlineProtocol.GetUserSettingsResult
  public let checkpointState: BucketState
  public let targetState: BucketState
  public let reason: String

  public init(
    chats: InlineProtocol.GetChatsResult,
    me: InlineProtocol.GetMeResult,
    settings: InlineProtocol.GetUserSettingsResult,
    checkpointState: BucketState,
    targetState: BucketState,
    reason: String
  ) {
    self.chats = chats
    self.me = me
    self.settings = settings
    self.checkpointState = checkpointState
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

  /// Apply a batch and, when supplied, commit its durable bucket cursor in the
  /// same storage transaction. This is a protocol requirement so existential
  /// dispatch reaches database-backed implementations instead of silently
  /// selecting the forwarding default below.
  func apply(
    updates: [InlineProtocol.Update],
    source: UpdateApplySource,
    sidecars: InlineProtocol.UpdateSidecars?,
    bucketCommit: UpdateBucketCommit?
  ) async -> UpdateApplyResult

  func apply(
    updates: [InlineProtocol.Update],
    source: UpdateApplySource,
    sidecars: InlineProtocol.UpdateSidecars?,
    bucketCommit: UpdateBucketCommit?,
    mutationToken: AuthAccountMutationToken?
  ) async -> UpdateApplyResult

  /// Apply a bounded current-state repair for a chat bucket.
  func repairChat(_ snapshot: ChatRepairSnapshot) async -> BucketState?
  /// Apply a bounded current-state repair for a space bucket.
  func repairSpace(_ snapshot: SpaceRepairSnapshot) async -> BucketState?
  /// Apply a current account projection fetched after a frozen user cursor.
  func repairUser(_ snapshot: UserRepairSnapshot) async -> BucketState?
}

public extension ApplyUpdates {
  func apply(updates: [InlineProtocol.Update], source: UpdateApplySource) async -> UpdateApplyResult {
    await apply(updates: updates, source: source, sidecars: nil)
  }

  func repairChat(_ snapshot: ChatRepairSnapshot) async -> BucketState? {
    nil
  }


  func repairSpace(_ snapshot: SpaceRepairSnapshot) async -> BucketState? {
    nil
  }

  func repairUser(_ snapshot: UserRepairSnapshot) async -> BucketState? {
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

  func apply(
    updates: [InlineProtocol.Update],
    source: UpdateApplySource,
    sidecars: InlineProtocol.UpdateSidecars?,
    bucketCommit: UpdateBucketCommit?,
    mutationToken: AuthAccountMutationToken?
  ) async -> UpdateApplyResult {
    await apply(
      updates: updates,
      source: source,
      sidecars: sidecars,
      bucketCommit: bucketCommit
    )
  }
}
