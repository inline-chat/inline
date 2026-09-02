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
  public let expectedStartState: BucketState?
  /// Request-time account projection fence for materializing an absent child.
  /// A user removal may erase both the child model and its zero cursor while
  /// its first page is in flight; the child CAS alone cannot detect that ABA.
  public let expectedUserStateForMissingChild: BucketState?

  public init(
    key: BucketKey,
    state: BucketState,
    expectedStartState: BucketState? = nil,
    expectedUserStateForMissingChild: BucketState? = nil
  ) {
    self.key = key
    self.state = state
    self.expectedStartState = expectedStartState
    self.expectedUserStateForMissingChild = expectedUserStateForMissingChild
  }
}

public struct ChatRepairSnapshot: Sendable {
  public let peer: InlineProtocol.Peer
  public let chat: InlineProtocol.GetChatResult
  /// Optional hydration for a subset of `chat.pinnedMessageIds`. Pin identity
  /// remains authoritative even while a body is unavailable.
  public let pinnedMessages: [InlineProtocol.Message]
  public let targetState: BucketState
  public let mutationToken: AuthAccountMutationToken
  public let expectedUserStateForMissingChild: BucketState?
  public let reason: String

  public init(
    peer: InlineProtocol.Peer,
    chat: InlineProtocol.GetChatResult,
    pinnedMessages: [InlineProtocol.Message],
    targetState: BucketState,
    mutationToken: AuthAccountMutationToken,
    reason: String,
    expectedUserStateForMissingChild: BucketState? = nil
  ) {
    self.peer = peer
    self.chat = chat
    self.pinnedMessages = pinnedMessages
    self.targetState = targetState
    self.mutationToken = mutationToken
    self.expectedUserStateForMissingChild = expectedUserStateForMissingChild
    self.reason = reason
  }
}

public struct SpaceRepairSnapshot: Sendable {
  public let spaceID: Int64
  public let snapshot: InlineProtocol.GetSpaceResult
  public let targetState: BucketState
  public let mutationToken: AuthAccountMutationToken
  public let expectedUserStateForMissingChild: BucketState?
  public let reason: String

  public init(
    spaceID: Int64,
    snapshot: InlineProtocol.GetSpaceResult,
    targetState: BucketState,
    mutationToken: AuthAccountMutationToken,
    reason: String,
    expectedUserStateForMissingChild: BucketState? = nil
  ) {
    self.spaceID = spaceID
    self.snapshot = snapshot
    self.targetState = targetState
    self.mutationToken = mutationToken
    self.expectedUserStateForMissingChild = expectedUserStateForMissingChild
    self.reason = reason
  }
}

public struct UserRepairSnapshot: Sendable {
  public let chats: InlineProtocol.GetChatsResult
  public let me: InlineProtocol.GetMeResult
  public let settings: InlineProtocol.GetUserSettingsResult
  public let checkpointState: BucketState
  /// User state captured after the ordinary account projections were fetched.
  /// A typed User TOO_LONG replays this bounded suffix after installing the
  /// projection at `checkpointState`; ordinary audits leave it nil.
  public let replayThroughState: BucketState?
  public let targetState: BucketState
  public let mutationToken: AuthAccountMutationToken
  /// Only a server-typed User TOO_LONG may replace active catalog inclusion.
  /// Projection audits and other scoped repairs must leave omissions inert.
  public let replacesActiveCatalog: Bool
  /// Forces a snapshot projection audit even when the durable user cursor has
  /// already reached the checkpoint. This is reserved for exceptional global
  /// watermark regression recovery and must never rewind the user cursor.
  public let requiresProjectionAudit: Bool
  public let reason: String

  public init(
    chats: InlineProtocol.GetChatsResult,
    me: InlineProtocol.GetMeResult,
    settings: InlineProtocol.GetUserSettingsResult,
    checkpointState: BucketState,
    replayThroughState: BucketState? = nil,
    targetState: BucketState,
    mutationToken: AuthAccountMutationToken,
    replacesActiveCatalog: Bool = false,
    requiresProjectionAudit: Bool = false,
    reason: String
  ) {
    self.chats = chats
    self.me = me
    self.settings = settings
    self.checkpointState = checkpointState
    self.replayThroughState = replayThroughState
    self.targetState = targetState
    self.mutationToken = mutationToken
    self.replacesActiveCatalog = replacesActiveCatalog
    self.requiresProjectionAudit = requiresProjectionAudit
    self.reason = reason
  }
}

/// Opaque admission captured by a user repair whose child catch-up demands
/// must become durable before the proposed user cursor can commit.
public struct UserRepairFinalization: Sendable {
  public let expectedUserState: BucketState
  public let expectedUserStateExists: Bool
  public let proposedUserState: BucketState
  public let replayThroughState: BucketState?
  public let catchUpTargets: [BucketKey: Int64]
  public let retiredBucketKeys: Set<BucketKey>
  public let mutationToken: AuthAccountMutationToken

  public init(
    expectedUserState: BucketState,
    expectedUserStateExists: Bool,
    proposedUserState: BucketState,
    replayThroughState: BucketState? = nil,
    catchUpTargets: [BucketKey: Int64],
    retiredBucketKeys: Set<BucketKey> = [],
    mutationToken: AuthAccountMutationToken
  ) {
    self.expectedUserState = expectedUserState
    self.expectedUserStateExists = expectedUserStateExists
    self.proposedUserState = proposedUserState
    self.replayThroughState = replayThroughState
    self.catchUpTargets = catchUpTargets
    self.retiredBucketKeys = retiredBucketKeys
    self.mutationToken = mutationToken
  }
}

/// Sync-owned proof describing the durable state reached for one exact child
/// demand. `authoritative` distinguishes a resolved latest-state request from
/// an ordinary numeric target.
public struct UserRepairTargetResolution: Sendable {
  public let state: BucketState
  public let authoritative: Bool

  public init(state: BucketState, authoritative: Bool) {
    self.state = state
    self.authoritative = authoritative
  }
}

public enum UserRepairOutcome: Sendable {
  case applied(
    state: BucketState,
    seededStates: [BucketKey: BucketState],
    replayThroughState: BucketState?,
    retiredBucketKeys: Set<BucketKey>
  )
  case pending(
    finalization: UserRepairFinalization,
    seededStates: [BucketKey: BucketState]
  )
  case superseded(currentState: BucketState, replayThroughState: BucketState?)
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
  func repairUser(_ snapshot: UserRepairSnapshot) async -> UserRepairOutcome?
  /// Advance a pending user repair only after its exact child demands are durable.
  func finalizeUserRepair(
    _ finalization: UserRepairFinalization,
    resolvedTargets: [BucketKey: UserRepairTargetResolution]
  ) async -> BucketState?
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

  func repairUser(_ snapshot: UserRepairSnapshot) async -> UserRepairOutcome? {
    nil
  }

  func finalizeUserRepair(
    _ finalization: UserRepairFinalization,
    resolvedTargets: [BucketKey: UserRepairTargetResolution]
  ) async -> BucketState? {
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
