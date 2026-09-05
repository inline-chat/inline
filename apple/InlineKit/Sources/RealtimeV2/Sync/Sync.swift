import Foundation
import Auth
import InlineProtocol
import Logger

public struct SyncConfig: Sendable {
  public var lastSyncSafetyGapSeconds: Int64
  /// Caps concurrent `getUpdates` RPCs across buckets to avoid thundering herds on reconnect.
  ///
  /// This is intentionally global: each bucket already coalesces fetches, but many buckets can still
  /// fetch in parallel (e.g. after `getUpdatesState` signals).
  public var maxConcurrentBucketFetches: Int

  public init(
    lastSyncSafetyGapSeconds: Int64,
    maxConcurrentBucketFetches: Int = 4
  ) {
    self.lastSyncSafetyGapSeconds = lastSyncSafetyGapSeconds
    self.maxConcurrentBucketFetches = max(1, maxConcurrentBucketFetches)
  }

  public static let `default` = SyncConfig(lastSyncSafetyGapSeconds: 15)
}

/// One retry cadence for discovery and bucket owners. Retry count is unbounded,
/// but its rate is bounded; progress returns the owner to the fast tier.
enum SyncRetryPolicy {
  static func delay(
    attempt: Int,
    rateLimited: Bool = false,
    jitterUnit: Double = Double.random(in: 0 ... 1)
  ) -> Duration {
    let jitter = min(1, max(0, jitterUnit))
    if rateLimited {
      return .milliseconds(Int64((60_000 + 20_000 * jitter).rounded()))
    }

    let seconds: Double = switch attempt {
      case ...0: 1
      case 1: 2
      case 2: 4
      default: 5
    }
    let milliseconds = seconds * 1_000 * (0.8 + 0.4 * jitter)
    return .milliseconds(Int64(milliseconds.rounded()))
  }
}

public struct SyncBucketSnapshot: Sendable {
  public let key: BucketKey
  public let seq: Int64
  public let date: Int64
  public let isFetching: Bool
  public let needsFetch: Bool

  public init(key: BucketKey, seq: Int64, date: Int64, isFetching: Bool, needsFetch: Bool) {
    self.key = key
    self.seq = seq
    self.date = date
    self.isFetching = isFetching
    self.needsFetch = needsFetch
  }
}

private extension BucketKey {
  var traceKind: String {
    switch self {
      case .chat:
        "chat"
      case .space:
        "space"
      case .user:
        "user"
    }
  }
}

public struct SyncStats: Sendable {
  public var directUpdatesApplied: Int64
  public var bucketUpdatesApplied: Int64
  public var bucketUpdatesSkipped: Int64
  public var bucketUpdatesDuplicateSkipped: Int64
  public var bucketFetchCount: Int64
  public var bucketFetchFailures: Int64
  public var bucketFetchTooLong: Int64
  public var bucketFetchFollowups: Int64
  public var realtimeBufferRecoveries: Int64
  public var bucketsTracked: Int
  public var lastDirectApplyAt: Int64
  public var lastBucketFetchAt: Int64
  public var lastBucketFetchFailureAt: Int64
  public var lastSyncDate: Int64
  public var buckets: [SyncBucketSnapshot]
  public var activeBucketFetches: Int
  public var discoveryRoundsPending: Int
  public var discoveryTargetsPending: Int
  public var queuedDiscoveryTargets: Int
  public var isStateFetchInFlight: Bool
  public var hasPendingStateFetch: Bool

  public init(
    directUpdatesApplied: Int64,
    bucketUpdatesApplied: Int64,
    bucketUpdatesSkipped: Int64,
    bucketUpdatesDuplicateSkipped: Int64,
    bucketFetchCount: Int64,
    bucketFetchFailures: Int64,
    bucketFetchTooLong: Int64,
    bucketFetchFollowups: Int64,
    realtimeBufferRecoveries: Int64 = 0,
    bucketsTracked: Int,
    lastDirectApplyAt: Int64,
    lastBucketFetchAt: Int64,
    lastBucketFetchFailureAt: Int64,
    lastSyncDate: Int64,
    buckets: [SyncBucketSnapshot],
    activeBucketFetches: Int = 0,
    discoveryRoundsPending: Int = 0,
    discoveryTargetsPending: Int = 0,
    queuedDiscoveryTargets: Int = 0,
    isStateFetchInFlight: Bool = false,
    hasPendingStateFetch: Bool = false
  ) {
    self.directUpdatesApplied = directUpdatesApplied
    self.bucketUpdatesApplied = bucketUpdatesApplied
    self.bucketUpdatesSkipped = bucketUpdatesSkipped
    self.bucketUpdatesDuplicateSkipped = bucketUpdatesDuplicateSkipped
    self.bucketFetchCount = bucketFetchCount
    self.bucketFetchFailures = bucketFetchFailures
    self.bucketFetchTooLong = bucketFetchTooLong
    self.bucketFetchFollowups = bucketFetchFollowups
    self.realtimeBufferRecoveries = realtimeBufferRecoveries
    self.bucketsTracked = bucketsTracked
    self.lastDirectApplyAt = lastDirectApplyAt
    self.lastBucketFetchAt = lastBucketFetchAt
    self.lastBucketFetchFailureAt = lastBucketFetchFailureAt
    self.lastSyncDate = lastSyncDate
    self.buckets = buckets
    self.activeBucketFetches = activeBucketFetches
    self.discoveryRoundsPending = discoveryRoundsPending
    self.discoveryTargetsPending = discoveryTargetsPending
    self.queuedDiscoveryTargets = queuedDiscoveryTargets
    self.isStateFetchInFlight = isStateFetchInFlight
    self.hasPendingStateFetch = hasPendingStateFetch
  }

  public static let empty = SyncStats(
    directUpdatesApplied: 0,
    bucketUpdatesApplied: 0,
    bucketUpdatesSkipped: 0,
    bucketUpdatesDuplicateSkipped: 0,
    bucketFetchCount: 0,
    bucketFetchFailures: 0,
    bucketFetchTooLong: 0,
    bucketFetchFollowups: 0,
    realtimeBufferRecoveries: 0,
    bucketsTracked: 0,
    lastDirectApplyAt: 0,
    lastBucketFetchAt: 0,
    lastBucketFetchFailureAt: 0,
    lastSyncDate: 0,
    buckets: []
  )
}

#if DEBUG || DEBUG_BUILD
public enum SyncDebugScenario: String, CaseIterable, Identifiable, Sendable {
  case forceDiscovery
  case clearStateAndFetch
  case seedZeroDateAndFetch
  case seedStaleDateAndFetch
  case rewindUserBucketAndFetch

  public var id: String { rawValue }

  public var title: String {
    switch self {
      case .forceDiscovery:
        "Force Discovery"
      case .clearStateAndFetch:
        "Clear Cursors + Fetch"
      case .seedZeroDateAndFetch:
        "Seed Zero Date + Fetch"
      case .seedStaleDateAndFetch:
        "Seed Stale Date + Fetch"
      case .rewindUserBucketAndFetch:
        "Rewind User Bucket"
    }
  }

  public var detail: String {
    switch self {
      case .forceDiscovery:
        "Queues getUpdatesState and the user bucket without changing local cursors."
      case .clearStateAndFetch:
        "Clears global and bucket cursors, then runs normal discovery from a cold local state."
      case .seedZeroDateAndFetch:
        "Clears the global checkpoint so the next discovery requests a fresh current checkpoint."
      case .seedStaleDateAndFetch:
        "Stores a 15-day-old global cursor so discovery runs from the real persisted date."
      case .rewindUserBucketAndFetch:
        "Moves only the user-bucket cursor back by 25 sequences and runs its normal catch-up path."
    }
  }

  public var systemImage: String {
    switch self {
      case .forceDiscovery:
        "arrow.clockwise"
      case .clearStateAndFetch:
        "trash.circle.fill"
      case .seedZeroDateAndFetch:
        "0.circle.fill"
      case .seedStaleDateAndFetch:
        "calendar.badge.clock"
      case .rewindUserBucketAndFetch:
        "backward.end.circle.fill"
    }
  }
}

public enum SyncDebugBucketScenario: String, CaseIterable, Identifiable, Sendable {
  case fetchLatest
  case rewind25AndFetch
  case rewindToZeroAndFetch
  case overflowBufferAndRecover

  public var id: String { rawValue }

  public var title: String {
    switch self {
      case .fetchLatest:
        "Fetch Latest"
      case .rewind25AndFetch:
        "Rewind 25 + Fetch"
      case .rewindToZeroAndFetch:
        "Rewind to Zero + Fetch"
      case .overflowBufferAndRecover:
        "Overflow Buffer + Recover"
    }
  }

  public var detail: String {
    switch self {
      case .fetchLatest:
        "Runs an authoritative latest fetch without changing the cursor first."
      case .rewind25AndFetch:
        "Rewinds only this bucket by 25 sequences and exercises normal replay."
      case .rewindToZeroAndFetch:
        "Resets only this bucket to zero; a backlog over 1,000 exercises TOO_LONG recovery."
      case .overflowBufferAndRecover:
        "Injects a bounded debug-only overflow, discards the synthetic buffer, and catches up from the server."
    }
  }
}

public struct SyncDebugActionResult: Sendable {
  public let succeeded: Bool
  public let summary: String

  public init(succeeded: Bool, summary: String) {
    self.succeeded = succeeded
    self.summary = summary
  }
}

public struct SyncDebugScenarioResult: Sendable {
  public let scenario: SyncDebugScenario
  public let succeeded: Bool
  public let summary: String

  public init(scenario: SyncDebugScenario, succeeded: Bool, summary: String) {
    self.scenario = scenario
    self.succeeded = succeeded
    self.summary = summary
  }
}
#endif

actor Sync {
  private enum DiscoveryTarget {
    case through(Int64)
    case latest
  }

  private enum DiscoveryCheckpointPolicy {
    case safetyGap
    case allowingRegression
    case exactFresh
  }

  private struct ActiveDiscoveryRound {
    let generation: UInt64
    var observedTarget = false
    var checkpointPolicy: DiscoveryCheckpointPolicy = .safetyGap
    var pendingTargets: [BucketKey: DiscoveryTarget] = [:]
  }

  private struct PendingDiscoveryRound {
    let checkpoint: Int64
    let checkpointPolicy: DiscoveryCheckpointPolicy
    var pendingTargets: [BucketKey: DiscoveryTarget]
  }

  private enum StateFetchAttemptError: Error, PrivacySafeErrorCategoryProviding {
    case storageReadFailed
    case invalidResponse
    case invalidDate
    case missingUserSequence
    case missingDiscoveryTargets
    case userCheckpointWriteFailed
    case globalCheckpointWriteFailed
    case bootstrapRepairFailed

    var privacySafeErrorCategory: String {
      switch self {
        case .storageReadFailed: "sync_state:storage_read_failed"
        case .invalidResponse: "sync_state:invalid_response"
        case .invalidDate: "sync_state:invalid_date"
        case .missingUserSequence: "sync_state:missing_user_sequence"
        case .missingDiscoveryTargets: "sync_state:missing_discovery_targets"
        case .userCheckpointWriteFailed: "sync_state:user_checkpoint_write_failed"
        case .globalCheckpointWriteFailed: "sync_state:global_checkpoint_write_failed"
        case .bootstrapRepairFailed: "sync_state:bootstrap_repair_failed"
      }
    }
  }

  private enum UserRepairFailurePhase: String, Sendable {
    case preflight
    case checkpoint
    case chatsProjection = "chats_projection"
    case meProjection = "me_projection"
    case settingsProjection = "settings_projection"
    case postSnapshotCheckpoint = "post_snapshot_checkpoint"
    case admission

    var breadcrumbCategory: String {
      switch self {
        case .chatsProjection: "sync.bootstrap.chats"
        case .meProjection: "sync.bootstrap.me"
        case .settingsProjection: "sync.bootstrap.settings"
        default: "sync.lifecycle"
      }
    }
  }

  private enum UserRepairFailureCause: String, Equatable, Sendable {
    case unavailable
    case requestFailed = "request_failed"
    case invalidResponse = "invalid_response"
    case persistenceFailed = "persistence_failed"
  }

  private struct UserRepairFailure:
    Error, LocalizedError, PrivacySafeErrorCategoryProviding, Sendable
  {
    let phase: UserRepairFailurePhase
    let cause: UserRepairFailureCause

    var errorDescription: String? {
      "User repair failed during \(phase.rawValue): \(cause.rawValue)"
    }

    var privacySafeErrorCategory: String {
      "user_repair:\(phase.rawValue):\(cause.rawValue)"
    }
  }

  private enum SnapshotOutcomeError: Error {
    case notReady
    case accountMismatch
    case invalidTarget
  }

  private static let getUpdatesStateTimeout: Duration = .seconds(15)
  private static let chatRepairTimeout: Duration = .seconds(20)
  private static let chatRepairHistoryLimit: Int32 = 100

  private var log = Log.scoped("RealtimeV2.Sync")

  private var applyUpdates: ApplyUpdates
  private var syncStorage: SyncStorage
  private let auth: AuthHandle?
  // Must be a strong reference: Sync/BucketActor schedule async Tasks that can easily outlive
  // the caller's local reference. A weak ref here makes sync silently stop working.
  private var client: ProtocolClientType?
  private var config: SyncConfig
  private var stats: SyncStats = .empty
  // Activity is keyed by bucket so a retry/follow-up cannot accidentally clear
  // another fetch's Updating state. The lifecycle fields below cover the
  // discovery/state phase before a bucket actor has acquired a lease.
  private var activeBucketActivityKeys: Set<BucketKey> = []
  private var isSyncActivityActive = false
  private var isStateFetchInFlight = false
  private var isStateFetchPending = false
  private var stateRetryWakeWaiter: (id: UUID, continuation: CheckedContinuation<Void, Never>)?
  private var stateRetryWakeRequested = false
  private var lastAcceptedSessionID: UInt64?
  private var nextDiscoveryRoundGeneration: UInt64 = 0
  private var pendingDiscoveryRounds: [UInt64: PendingDiscoveryRound] = [:]
  private var queuedDiscoveryTargets: [BucketKey: DiscoveryTarget] = [:]
  private var activeDiscoveryRound: ActiveDiscoveryRound?
  private var syncActivityListener: (@Sendable (Bool) async -> Void)?

  private var buckets: [BucketKey: BucketActor] = [:]
  private var bucketLoadRetries: [BucketKey: (id: UUID, task: Task<Void, Never>)] = [:]
  private let bucketFetchLimiter: FetchLimiter
  private var generation: UInt64 = 0
  private var acceptsWork = false
  private var isResetting = false
  private var rootTasks: [UUID: Task<Void, Never>] = [:]
  private var operationsInProgress = 0
  private var operationDrainWaiters: [CheckedContinuation<Void, Never>] = []
  private var accountMutationToken: AuthAccountMutationToken?

  init(
    applyUpdates: ApplyUpdates,
    syncStorage: SyncStorage,
    client: ProtocolClientType,
    config: SyncConfig,
    acceptsWork: Bool = true,
    auth: AuthHandle? = nil
  ) {
    self.applyUpdates = applyUpdates
    self.syncStorage = syncStorage
    self.auth = auth
    self.client = client
    self.config = config
    self.acceptsWork = acceptsWork
    bucketFetchLimiter = FetchLimiter(limit: config.maxConcurrentBucketFetches)
  }

  // MARK: - Public API

  /// Process incoming updates (pushed from server)
  func process(
    updates: [InlineProtocol.Update],
    mutationToken: AuthAccountMutationToken? = nil
  ) async {
    guard let expectedGeneration = beginOperation() else { return }
    defer { endOperation() }

    let span = PerformanceTrace.begin(
      "SyncProcessRealtimePush",
      category: .sync,
      "updates=\(updates.count)"
    )
    let startedAt = Date()
    defer {
      span.end(
        "updates=\(updates.count) duration_ms=\(PerformanceTrace.elapsedMilliseconds(since: startedAt))"
      )
    }

    log.trace("applying \(updates.count) updates")

    var applyingUpdates: [InlineProtocol.Update] = []
    var bucketedUpdates: [BucketKey: [InlineProtocol.Update]] = [:]

    for update in updates {
      switch update.update {
        case let .chatHasNewUpdates(payload):
          // Trigger fetch for this chat
          chatHasNewUpdates(payload)
          continue

        case let .spaceHasNewUpdates(payload):
          // Trigger fetch for this space
          spaceHasNewUpdates(payload)
          continue

        default:
          if update.hasSeq, update.seq > 0 {
            if case .userAddedToChat = update.update {
              fetchUserBucket(upToSeq: Int64(update.seq))
              continue
            }
            if let key = getBucketKey(for: update) {
            // Route sequenced updates through BucketActor so we can enforce strict per-bucket ordering
            // and fetch missing history when we detect gaps.
              bucketedUpdates[key, default: []].append(update)
              continue
            }
            log.warning("sequenced update has unknown bucket content; running discovery")
            getStateFromServer()
            continue
          }

          // Non-sequenced updates are applied directly.
          applyingUpdates.append(update)
      }
    }

    // Apply the direct updates
    if !applyingUpdates.isEmpty {
      let result = await applyUpdates.apply(
        updates: applyingUpdates,
        source: .realtime,
        sidecars: nil,
        bucketCommit: nil,
        mutationToken: mutationToken
      )
      guard isCurrent(expectedGeneration) else { return }
      recordDirectApply(count: result.appliedCount)
      if result.succeeded {
        // Update bucket states based on applied updates
        await updateBucketStates(for: applyingUpdates, generation: expectedGeneration)
      } else {
        log.error(
          "failed to apply \(result.failedCount) direct updates; skipping direct sync cursor advancement"
        )
        if shouldFetchUserBucketAfterDirectApplyFailure(applyingUpdates) {
          log.warning("direct participant grant update failed; scheduling discovery for sidecar-backed recovery")
          getStateFromServer()
        }
      }
    }

    // Apply bucketed updates (sequenced) via BucketActor ordering/buffering.
    if !bucketedUpdates.isEmpty {
      for (key, updates) in bucketedUpdates {
        if let target = updates.map({ Int64($0.seq) }).max() {
          registerDiscoveryTarget(key: key, seq: target)
        }
        guard let actor = await getBucketActor(key: key, generation: expectedGeneration) else { continue }
        await actor.processRealtimeUpdates(updates, mutationToken: mutationToken)
        guard isCurrent(expectedGeneration) else { return }
        // Duplicate-only batches still registered a demand before loading the
        // actor. Report its durable coordinate too, so an active discovery
        // round cannot remain pinned behind an already-applied sequence.
        let state = await actor.snapshot()
        guard isCurrent(expectedGeneration) else { return }
        await bucketDidAdvance(key: key, state: BucketState(date: state.date, seq: state.seq))
      }
    }
  }

  /// A protocol-open edge, not a presentation state, owns recovery. Replacing
  /// an already-open session must wake unresolved work too, exactly once.
  func acceptedSessionOpened(
    sessionID: UInt64,
    mutationToken: AuthAccountMutationToken? = nil
  ) async {
    guard acceptsWork, !isResetting else { return }
    if let auth {
      guard let mutationToken, mutationToken == accountMutationToken,
            (try? auth.validateAccountMutation(mutationToken)) != nil
      else { return }
    }
    guard lastAcceptedSessionID != sessionID else { return }
    lastAcceptedSessionID = sessionID
    // A newer edge during an RPC needs a subsequent discovery; if the RPC
    // fails, its next attempt consumes that edge instead of adding an owner.
    getStateFromServer()
    launchRootTask { sync, taskGeneration in
      await sync.wakeBucketRetries(generation: taskGeneration)
    }
    // Failed exact cursor loads have no bucket actor yet. Restart only those
    // existing owners; this is not a persisted-bucket inventory pass.
    for (key, retry) in Array(bucketLoadRetries) {
      retry.task.cancel()
      bucketLoadRetries.removeValue(forKey: key)
      scheduleBucketLoadRetry(key: key, immediate: true)
    }
    // Publish admission before returning to the connection presentation owner.
    // Network work remains owned by root tasks, not by its snapshot collector.
    await publishSyncActivityIfNeeded()
  }

  func connectionStateChanged(state: RealtimeConnectionState) {
    // Kept for source compatibility with presentation clients. It must never
    // schedule sync work: Updating -> Connected is not a new protocol session.
    log.trace("presentation connection state changed to \(state)")
  }

  func setSyncActivityListener(_ listener: (@Sendable (Bool) async -> Void)?) async {
    syncActivityListener = listener
    await publishSyncActivityIfNeeded()
  }

  /// Save bucket state to storage after successful update application
  func saveBucketState(for key: BucketKey, seq: Int64, date: Int64) async -> BucketState? {
    log.trace("saving bucket state for \(key): seq=\(seq), date=\(date)")
    let saved = await syncStorage.advanceBucketState(
      for: key,
      state: BucketState(date: date, seq: seq)
    )
    if saved == nil {
      log.error("failed to save bucket state for \(key): seq=\(seq), date=\(date)")
    }
    return saved
  }

  func installSnapshotBucketStates(_ states: [BucketKey: BucketState]) async {
    guard let expectedGeneration = beginOperation() else { return }
    defer { endOperation() }
    for (key, state) in states {
      guard isCurrent(expectedGeneration) else { return }
      if let actor = buckets[key] {
        await actor.installSnapshotState(state)
      }
      guard isCurrent(expectedGeneration) else { return }
      await bucketDidAdvance(key: key, state: state, authoritative: false)
    }
  }

  func discardBucketState(for key: BucketKey) async {
    // An inaccessible peer is no longer a live actor, but its durable cursor and
    // cached rows are still useful if access is restored later. The owner must
    // never turn an access error into destructive local-data deletion.
    log.debug("retiring inaccessible sync bucket actor for \(key)")
    buckets.removeValue(forKey: key)
  }

  /// Retires only actors made inactive by an admitted account catalog rebase.
  /// Durable cursors and cached rows remain available if access returns.
  func retireCatalogBucketActors(_ keys: Set<BucketKey>) async {
    for key in keys where key != .user {
      if let loadRetry = bucketLoadRetries.removeValue(forKey: key) {
        loadRetry.task.cancel()
      }
      if let actor = buckets.removeValue(forKey: key) {
        await actor.invalidate()
        await actor.waitUntilIdle()
      }
      await resolveInaccessibleBucket(key: key)
    }
  }

  /// Apply updates from bucket actor
  func userStateForMissingChildAdmission() async throws -> BucketState {
    guard acceptsWork, !isResetting else { throw CancellationError() }
    return try await syncStorage.getBucketState(for: .user)
  }

  /// Apply updates from bucket actor
  func applyUpdatesFromBucket(
    _ updates: [InlineProtocol.Update],
    sidecars: InlineProtocol.UpdateSidecars? = nil,
    bucketCommit: UpdateBucketCommit? = nil,
    mutationToken: AuthAccountMutationToken? = nil
  ) async -> UpdateApplyResult {
    await applyUpdates.apply(
      updates: updates,
      source: .syncCatchup,
      sidecars: sidecars,
      bucketCommit: bucketCommit,
      mutationToken: mutationToken
    )
  }

  /// Apply sequenced realtime updates through the same engine, but with realtime side effects.
  func applyUpdatesFromRealtime(
    _ updates: [InlineProtocol.Update],
    bucketCommit: UpdateBucketCommit? = nil,
    mutationToken: AuthAccountMutationToken? = nil
  ) async -> UpdateApplyResult {
    await applyUpdates.apply(
      updates: updates,
      source: .realtime,
      sidecars: nil,
      bucketCommit: bucketCommit,
      mutationToken: mutationToken
    )
  }

  /// Fetch and apply a bounded current-state snapshot for a chat bucket.
  func repairChatBucket(
    peer: InlineProtocol.Peer,
    targetState: BucketState,
    reason: String
  ) async -> BucketState? {
    guard let client else {
      log.error("client is nil, cannot repair chat bucket")
      return nil
    }
    guard let accountMutationToken else {
      log.error("cannot repair chat bucket without an account mutation token")
      return nil
    }

    let startedAt = Date()
    let span = PerformanceTrace.begin(
      "SyncChatRepair",
      category: .sync,
      "reason=\(reason)"
    )
    defer {
      span.end(
        "reason=\(reason) duration_ms=\(PerformanceTrace.elapsedMilliseconds(since: startedAt))"
      )
    }

    do {
      let expectedUserStateForMissingChild = try await syncStorage.getBucketState(for: .user)
      guard let rawChat = try await callRepairRpc(
        client: client,
        method: .getChat,
        input: .getChat(.with {
          $0.peerID = peer.toInputPeer()
          $0.includeRecentMessages = true
        }),
        timeout: Self.chatRepairTimeout
      ) else {
        return nil
      }
      guard case let .getChat(chat) = rawChat else {
        log.error("failed to parse getChat result during chat repair")
        return nil
      }
      guard chat.hasChat,
            chat.hasDialog,
            chat.chat.id > 0,
            chat.dialog.chatID == chat.chat.id,
            chat.chat.peerID == peer
      else {
        log.error("getChat result did not match the requested chat during chat repair")
        return nil
      }

      let pinnedIDs = chat.pinnedMessageIds
      guard pinnedIDs.allSatisfy({ $0 > 0 }),
            Set(pinnedIDs).count == pinnedIDs.count,
            validateChatRepairMessages(chat)
      else {
        log.error("getChat returned an invalid chat repair window")
        return nil
      }

      let repaired = await applyUpdates.repairChat(ChatRepairSnapshot(
        peer: peer,
        chat: chat,
        pinnedMessages: [],
        targetState: targetState,
        mutationToken: accountMutationToken,
        reason: reason,
        expectedUserStateForMissingChild: expectedUserStateForMissingChild
      ))
      if repaired == nil {
        log.error("failed to apply chat repair snapshot")
      }
      return repaired
    } catch {
      log.error("failed to repair chat bucket", error: error)
      return nil
    }
  }

  private func validateChatRepairMessages(_ snapshot: InlineProtocol.GetChatResult) -> Bool {
    let messages = snapshot.messages
    guard messages.count <= Int(Self.chatRepairHistoryLimit),
          Set(messages.map(\.id)).count == messages.count,
          messages.allSatisfy({
            $0.id > 0 &&
              $0.chatID == snapshot.chat.id &&
              $0.peerID == snapshot.chat.peerID
          }),
          zip(messages, messages.dropFirst()).allSatisfy({ $0.0.id > $0.1.id })
    else { return false }

    let lastMessageID = snapshot.chat.hasLastMsgID ? snapshot.chat.lastMsgID : 0
    if lastMessageID > 0 {
      return messages.first?.id == lastMessageID
    }
    return messages.isEmpty
  }

  func repairSpaceBucket(
    spaceID: Int64,
    targetState: BucketState,
    reason: String
  ) async -> BucketState? {
    guard let client else {
      log.error("client is nil, cannot repair space bucket")
      return nil
    }
    guard let accountMutationToken else {
      log.error("cannot repair space bucket without an account mutation token")
      return nil
    }
    do {
      let expectedUserStateForMissingChild = try await syncStorage.getBucketState(for: .user)
      guard let rawSpace = try await callRepairRpc(
        client: client,
        method: .getSpace,
        input: .getSpace(.with { $0.spaceID = spaceID }),
        timeout: Self.chatRepairTimeout
      ) else {
        return nil
      }
      guard case let .getSpace(snapshot) = rawSpace else {
        log.error("failed to parse getSpace result during space repair")
        return nil
      }
      guard snapshot.hasSpace, snapshot.space.id == spaceID else {
        log.error("getSpace result did not match the requested space during space repair")
        return nil
      }
      return await applyUpdates.repairSpace(SpaceRepairSnapshot(
        spaceID: spaceID,
        snapshot: snapshot,
        targetState: targetState,
        mutationToken: accountMutationToken,
        reason: reason,
        expectedUserStateForMissingChild: expectedUserStateForMissingChild
      ))
    } catch {
      log.error("failed to repair space bucket", error: error)
      return nil
    }
  }

  private func callRepairRpc(
    client: ProtocolClientType,
    method: InlineProtocol.Method,
    input: InlineProtocol.RpcCall.OneOf_Input?,
    timeout: Duration
  ) async throws -> InlineProtocol.RpcResult.OneOf_Result? {
    guard await bucketFetchLimiter.acquire() else { return nil }
    do {
      let result = try await client.callRpc(method: method, input: input, timeout: timeout)
      await bucketFetchLimiter.release()
      return result
    } catch {
      await bucketFetchLimiter.release()
      throw error
    }
  }

  private func fetchUserRepairChats(
    client: ProtocolClientType,
    checkpointState: BucketState,
    mutationToken: AuthAccountMutationToken,
    persistIndependently: Bool
  ) async -> Result<(InlineProtocol.GetChatsResult, UserBootstrapCatalogPersistence?), UserRepairFailure> {
    let startedAt = Date()
    let span = PerformanceTrace.begin("SyncUserRepairChats", category: .sync)
    var succeeded = false
    defer {
      let durationMs = PerformanceTrace.elapsedMilliseconds(since: startedAt)
      span.end("success=\(succeeded) duration_ms=\(durationMs)")
      PerformanceTrace.slowBreadcrumb(
        "user repair projection was slow",
        category: UserRepairFailurePhase.chatsProjection.breadcrumbCategory,
        durationMs: durationMs,
        thresholdMs: 5_000
      )
    }
    do {
      guard case let .getChats(chats) = try await callRepairRpc(
        client: client,
        method: .getChats,
        input: .getChats(.init()),
        timeout: Self.chatRepairTimeout
      ) else {
        return .failure(UserRepairFailure(
          phase: .chatsProjection,
          cause: .invalidResponse
        ))
      }
      if persistIndependently {
        guard case let .chats(persistence)? = await applyUpdates.persistUserBootstrapProjection(.init(
          projection: .chats(chats),
          checkpointState: checkpointState,
          mutationToken: mutationToken
        )) else {
          return .failure(UserRepairFailure(
            phase: .chatsProjection,
            cause: .persistenceFailed
          ))
        }
        guard acceptsWork, !isResetting, !Task.isCancelled,
              accountMutationToken == mutationToken
        else {
          return .failure(UserRepairFailure(
            phase: .chatsProjection,
            cause: .persistenceFailed
          ))
        }
        await installSnapshotBucketStates(persistence.seededStates)
        succeeded = true
        return .success((chats, persistence))
      }
      succeeded = true
      return .success((chats, nil))
    } catch {
      return .failure(UserRepairFailure(
        phase: .chatsProjection,
        cause: .requestFailed
      ))
    }
  }

  private func fetchUserRepairMe(
    client: ProtocolClientType,
    checkpointState: BucketState,
    mutationToken: AuthAccountMutationToken,
    persistIndependently: Bool
  ) async -> Result<InlineProtocol.GetMeResult, UserRepairFailure> {
    let startedAt = Date()
    let span = PerformanceTrace.begin("SyncUserRepairMe", category: .sync)
    var succeeded = false
    defer {
      let durationMs = PerformanceTrace.elapsedMilliseconds(since: startedAt)
      span.end("success=\(succeeded) duration_ms=\(durationMs)")
      PerformanceTrace.slowBreadcrumb(
        "user repair projection was slow",
        category: UserRepairFailurePhase.meProjection.breadcrumbCategory,
        durationMs: durationMs,
        thresholdMs: 5_000
      )
    }
    do {
      guard case let .getMe(me) = try await callRepairRpc(
        client: client,
        method: .getMe,
        input: .getMe(.init()),
        timeout: Self.chatRepairTimeout
      ) else {
        return .failure(UserRepairFailure(
          phase: .meProjection,
          cause: .invalidResponse
        ))
      }
      if persistIndependently {
        guard case .me? = await applyUpdates.persistUserBootstrapProjection(.init(
          projection: .me(me),
          checkpointState: checkpointState,
          mutationToken: mutationToken
        )) else {
          return .failure(UserRepairFailure(
            phase: .meProjection,
            cause: .persistenceFailed
          ))
        }
        succeeded = true
        return .success(me)
      }
      succeeded = true
      return .success(me)
    } catch {
      return .failure(UserRepairFailure(
        phase: .meProjection,
        cause: .requestFailed
      ))
    }
  }

  private func fetchUserRepairSettings(
    client: ProtocolClientType,
    checkpointState: BucketState,
    mutationToken: AuthAccountMutationToken,
    persistIndependently: Bool
  ) async -> Result<InlineProtocol.GetUserSettingsResult, UserRepairFailure> {
    let startedAt = Date()
    let span = PerformanceTrace.begin("SyncUserRepairSettings", category: .sync)
    var succeeded = false
    defer {
      let durationMs = PerformanceTrace.elapsedMilliseconds(since: startedAt)
      span.end("success=\(succeeded) duration_ms=\(durationMs)")
      PerformanceTrace.slowBreadcrumb(
        "user repair projection was slow",
        category: UserRepairFailurePhase.settingsProjection.breadcrumbCategory,
        durationMs: durationMs,
        thresholdMs: 5_000
      )
    }
    do {
      guard case let .getUserSettings(settings) = try await callRepairRpc(
        client: client,
        method: .getUserSettings,
        input: .getUserSettings(.init()),
        timeout: Self.chatRepairTimeout
      ) else {
        return .failure(UserRepairFailure(
          phase: .settingsProjection,
          cause: .invalidResponse
        ))
      }
      if persistIndependently {
        guard case .settings? = await applyUpdates.persistUserBootstrapProjection(.init(
          projection: .settings(settings),
          checkpointState: checkpointState,
          mutationToken: mutationToken
        )) else {
          return .failure(UserRepairFailure(
            phase: .settingsProjection,
            cause: .persistenceFailed
          ))
        }
        succeeded = true
        return .success(settings)
      }
      succeeded = true
      return .success(settings)
    } catch {
      return .failure(UserRepairFailure(
        phase: .settingsProjection,
        cause: .requestFailed
      ))
    }
  }

  private func reportUserRepairFailure(
    phase: UserRepairFailurePhase,
    cause: UserRepairFailureCause
  ) {
    log.error(
      "user repair failed",
      error: UserRepairFailure(phase: phase, cause: cause)
    )
  }

  private func reportUserRepairFailure(_ failure: UserRepairFailure) {
    log.error("user repair failed", error: failure)
  }

  func repairUserBucket(
    targetState: BucketState,
    reason: String,
    replacesActiveCatalog: Bool = false,
    requiresProjectionAudit: Bool = false,
    capturedCheckpointState: BucketState? = nil,
    persistProjectionsIndependently: Bool = false
  ) async -> UserRepairOutcome? {
    guard let client else {
      reportUserRepairFailure(phase: .preflight, cause: .unavailable)
      return nil
    }
    guard let accountMutationToken else {
      reportUserRepairFailure(phase: .preflight, cause: .unavailable)
      return nil
    }
    var failurePhase = UserRepairFailurePhase.checkpoint
    do {
      let allowsCheckpointBehindTarget = replacesActiveCatalog && requiresProjectionAudit
      let checkpointState: BucketState
      if let capturedCheckpointState {
        guard capturedCheckpointState.date > 0,
              capturedCheckpointState.seq >= targetState.seq || allowsCheckpointBehindTarget
        else {
          reportUserRepairFailure(phase: .checkpoint, cause: .invalidResponse)
          return nil
        }
        checkpointState = capturedCheckpointState
      } else {
        guard let rawCheckpoint = try await callRepairRpc(
          client: client,
          method: .getUpdatesState,
          input: .getUpdatesState(.init()),
          timeout: Self.getUpdatesStateTimeout
        ) else {
          guard !Task.isCancelled else { return nil }
          reportUserRepairFailure(phase: .checkpoint, cause: .requestFailed)
          return nil
        }
        guard case let .getUpdatesState(checkpoint) = rawCheckpoint,
              checkpoint.hasSeq,
              checkpoint.date > 0,
              Int64(checkpoint.seq) >= targetState.seq || allowsCheckpointBehindTarget
        else {
          reportUserRepairFailure(phase: .checkpoint, cause: .invalidResponse)
          return nil
        }
        checkpointState = BucketState(date: checkpoint.date, seq: Int64(checkpoint.seq))
      }

      failurePhase = .chatsProjection
      async let chatsResult = fetchUserRepairChats(
        client: client,
        checkpointState: checkpointState,
        mutationToken: accountMutationToken,
        persistIndependently: persistProjectionsIndependently
      )
      async let meResult = fetchUserRepairMe(
        client: client,
        checkpointState: checkpointState,
        mutationToken: accountMutationToken,
        persistIndependently: persistProjectionsIndependently
      )
      async let settingsResult = fetchUserRepairSettings(
        client: client,
        checkpointState: checkpointState,
        mutationToken: accountMutationToken,
        persistIndependently: persistProjectionsIndependently
      )
      let (chatsFetch, meFetch, settingsFetch) = await (chatsResult, meResult, settingsResult)
      guard acceptsWork, !isResetting, !Task.isCancelled,
            self.accountMutationToken == accountMutationToken
      else { return nil }
      guard case let .success(fetchedChats) = chatsFetch else {
        if case let .failure(failure) = chatsFetch {
          if failure.cause != .persistenceFailed {
            reportUserRepairFailure(failure)
          }
        }
        return nil
      }
      guard case let .success(me) = meFetch else {
        if case let .failure(failure) = meFetch {
          if failure.cause != .persistenceFailed {
            reportUserRepairFailure(failure)
          }
        }
        return nil
      }
      guard case let .success(settings) = settingsFetch else {
        if case let .failure(failure) = settingsFetch {
          if failure.cause != .persistenceFailed {
            reportUserRepairFailure(failure)
          }
        }
        return nil
      }
      let (chats, bootstrapCatalogPersistence) = fetchedChats
      let admittedBootstrapCatalog: UserBootstrapCatalogPersistence?
      if persistProjectionsIndependently {
        guard let bootstrapCatalogPersistence else { return nil }
        admittedBootstrapCatalog = bootstrapCatalogPersistence
      } else {
        admittedBootstrapCatalog = nil
      }

      let replayThroughState: BucketState?
      if replacesActiveCatalog {
        failurePhase = .postSnapshotCheckpoint
        guard let rawReplayThrough = try await callRepairRpc(
          client: client,
          method: .getUpdatesState,
          input: .getUpdatesState(.init()),
          timeout: Self.getUpdatesStateTimeout
        ),
          case let .getUpdatesState(replayThrough) = rawReplayThrough,
          replayThrough.hasSeq,
          replayThrough.date > 0,
          Int64(replayThrough.seq) >= checkpointState.seq
        else {
          guard !Task.isCancelled else { return nil }
          reportUserRepairFailure(phase: .postSnapshotCheckpoint, cause: .invalidResponse)
          return nil
        }
        replayThroughState = BucketState(
          date: replayThrough.date,
          seq: Int64(replayThrough.seq)
        )
      } else {
        replayThroughState = nil
      }
      guard acceptsWork, !isResetting, !Task.isCancelled,
            self.accountMutationToken == accountMutationToken
      else { return nil }
      failurePhase = .admission
      let outcome = await applyUpdates.repairUser(UserRepairSnapshot(
        chats: chats,
        me: me,
        settings: settings,
        checkpointState: checkpointState,
        replayThroughState: replayThroughState,
        targetState: targetState,
        mutationToken: accountMutationToken,
        bootstrapCatalogPersistence: admittedBootstrapCatalog,
        replacesActiveCatalog: replacesActiveCatalog,
        requiresProjectionAudit: requiresProjectionAudit,
        reason: reason
      ))
      guard let outcome else { return nil }
      return outcome
    } catch {
      guard !Task.isCancelled else { return nil }
      reportUserRepairFailure(phase: failurePhase, cause: .requestFailed)
      return nil
    }
  }

  func finalizeUserRepair(
    _ finalization: UserRepairFinalization,
    resolvedTargets: [BucketKey: UserRepairTargetResolution]
  ) async -> BucketState? {
    await applyUpdates.finalizeUserRepair(
      finalization,
      resolvedTargets: resolvedTargets
    )
  }

  /// Installs an already-admitted account repair under this Sync generation.
  /// The user actor owns the two-phase ordering: seeded states are installed
  /// first, exact child targets are registered/launched (where zero means
  /// authoritative latest), and finite targets that are already durable are
  /// reported through `bucketDidAdvance` before user finalization.
  func applyUserRepairOutcome(_ outcome: UserRepairOutcome) async -> BucketState? {
    guard acceptsWork, !isResetting,
          let userActor = await getBucketActor(key: .user, generation: generation)
    else { return nil }
    return await userActor.applyUserRepairOutcome(outcome)
  }

  /// Installs a catalog snapshot's actor seeds and launches only its exact
  /// child catch-up demands. The caller has already persisted the projection;
  /// this seam advances existing actors, reports finite targets already met by
  /// those seeds, and leaves zero (`.latest`) targets to an authoritative fetch.
  @discardableResult
  func installSnapshotOutcome(
    seededStates: [BucketKey: BucketState],
    catchUpTargets: [BucketKey: Int64],
    expectedAccount: AuthAccountMutationToken
  ) async throws -> [BucketKey: UserRepairTargetResolution] {
    guard let expectedGeneration = beginOperation() else { throw SnapshotOutcomeError.notReady }
    defer { endOperation() }
    try validateSnapshotLease(expectedAccount, generation: expectedGeneration)
    guard catchUpTargets.allSatisfy({ key, target in
      key != .user && target >= 0
    }), seededStates.allSatisfy({ key, state in
      key != .user && state.seq >= 0 && state.date >= 0
    }) else {
      throw SnapshotOutcomeError.invalidTarget
    }

    for (key, state) in seededStates {
      try validateSnapshotLease(expectedAccount, generation: expectedGeneration)
      if let actor = buckets[key] {
        await actor.installSnapshotState(state)
      }
    }
    try validateSnapshotLease(expectedAccount, generation: expectedGeneration)
    registerUserRepairTargets(catchUpTargets)
    // A seed can satisfy a pre-existing finite discovery hint even when this
    // catalog result carries no new catch-up target. Report every seed through
    // the normal owner so that old rounds do not remain pinned.
    for (key, state) in seededStates {
      try validateSnapshotLease(expectedAccount, generation: expectedGeneration)
      await bucketDidAdvance(key: key, state: state, authoritative: false)
    }
    var immediateResolutions: [BucketKey: UserRepairTargetResolution] = [:]
    for (key, target) in catchUpTargets {
      try validateSnapshotLease(expectedAccount, generation: expectedGeneration)
      guard let actor = await getBucketActor(key: key, generation: expectedGeneration) else {
        throw SnapshotOutcomeError.notReady
      }
      try validateSnapshotLease(expectedAccount, generation: expectedGeneration)
      let snapshot = await actor.snapshot()
      try validateSnapshotLease(expectedAccount, generation: expectedGeneration)
      if target > 0, snapshot.seq >= target {
        let state = BucketState(date: snapshot.date, seq: snapshot.seq)
        await bucketDidAdvance(key: key, state: state, authoritative: false)
        immediateResolutions[key] = UserRepairTargetResolution(
          state: state,
          authoritative: false
        )
        continue
      }

      // A zero target is an explicit authoritative-latest demand. It must not
      // be satisfied by the actor's current cursor, so it is always launched.
      _ = await actor.noteHasNewUpdates(upToSeq: target)
      try validateSnapshotLease(expectedAccount, generation: expectedGeneration)
      launchRootTask { sync, taskGeneration in
        guard (try? await sync.validateSnapshotLease(expectedAccount, generation: taskGeneration)) != nil else {
          return
        }
        guard let currentActor = await sync.getBucketActor(
          key: key,
          generation: taskGeneration
        ) else { return }
        guard (try? await sync.validateSnapshotLease(expectedAccount, generation: taskGeneration)) != nil else {
          return
        }
        await currentActor.fetchNewUpdates()
      }
    }
    try validateSnapshotLease(expectedAccount, generation: expectedGeneration)
    return immediateResolutions
  }

  private func validateSnapshotLease(
    _ expectedAccount: AuthAccountMutationToken,
    generation expectedGeneration: UInt64
  ) throws {
    guard isCurrent(expectedGeneration) else { throw SnapshotOutcomeError.notReady }
    guard accountMutationToken == expectedAccount else { throw SnapshotOutcomeError.accountMismatch }
    try auth?.validateAccountMutation(expectedAccount)
  }

  func updateConfig(_ config: SyncConfig) async {
    self.config = config
    await bucketFetchLimiter.setLimit(config.maxConcurrentBucketFetches)
    log.debug("updated sync config: messageUpdates=true, gap=\(config.lastSyncSafetyGapSeconds)s")
    await publishSyncActivityIfNeeded()
  }

  func activateGeneration() {
    generation &+= 1
    accountMutationToken = try? auth?.beginAccountMutation()
    stateRetryWakeRequested = false
    lastAcceptedSessionID = nil
    acceptsWork = true
  }

  func clearSyncState(acceptNewWork: Bool = true) async {
    await resetSyncState(clearPersistentState: true, acceptNewWork: acceptNewWork)
  }

  func prepareForTermination() async {
    await resetSyncState(clearPersistentState: false, acceptNewWork: false)
  }

  private func resetSyncState(clearPersistentState: Bool, acceptNewWork: Bool) async {
    log.debug("resetting sync runtime and bucket cache")
    generation &+= 1
    wakeStateRetry()
    accountMutationToken = nil
    lastAcceptedSessionID = nil
    acceptsWork = false
    isResetting = true
    let tasks = Array(rootTasks.values)
    rootTasks.removeAll()
    for task in tasks {
      task.cancel()
    }
    stats = .empty
    isStateFetchInFlight = false
    isStateFetchPending = false
    pendingDiscoveryRounds.removeAll()
    bucketLoadRetries.removeAll()
    queuedDiscoveryTargets.removeAll()
    activeDiscoveryRound = nil
    await invalidateAllBuckets()
    for task in tasks {
      await task.value
    }
    await waitForOperationsToFinish()
    if clearPersistentState {
      await syncStorage.clearSyncState()
    }
    activeBucketActivityKeys.removeAll()
    await publishSyncActivityIfNeeded()
    isResetting = false
    acceptsWork = acceptNewWork
  }

  func getStats() async -> SyncStats {
    var snapshot = stats
    if let state = try? await syncStorage.getState() {
      snapshot.lastSyncDate = state.lastSyncDate
    }
    let bucketSnapshots = await getBucketSnapshots()
    snapshot.buckets = bucketSnapshots
    snapshot.bucketsTracked = bucketSnapshots.count
    snapshot.activeBucketFetches = activeBucketActivityKeys.count
    snapshot.discoveryRoundsPending = pendingDiscoveryRounds.count + (activeDiscoveryRound == nil ? 0 : 1)
    snapshot.discoveryTargetsPending = pendingDiscoveryRounds.values.reduce(0) { partial, round in
      partial + round.pendingTargets.count
    } + (activeDiscoveryRound?.pendingTargets.count ?? 0)
    snapshot.queuedDiscoveryTargets = queuedDiscoveryTargets.count
    snapshot.isStateFetchInFlight = isStateFetchInFlight
    snapshot.hasPendingStateFetch = isStateFetchPending
    return snapshot
  }

#if DEBUG || DEBUG_BUILD
  func runDebugScenario(_ scenario: SyncDebugScenario) async -> SyncDebugScenarioResult {
    switch scenario {
      case .forceDiscovery:
        queueDebugDiscovery()
        return SyncDebugScenarioResult(
          scenario: scenario,
          succeeded: true,
          summary: "Queued discovery and user bucket catch-up."
        )

      case .clearStateAndFetch:
        stats = .empty
        await invalidateAllBuckets()
        activeBucketActivityKeys.removeAll()
        let saved = await syncStorage.clearSyncState()
        await publishSyncActivityIfNeeded()
        guard saved else {
          return SyncDebugScenarioResult(
            scenario: scenario,
            succeeded: false,
            summary: "Failed to clear sync state."
          )
        }
        queueDebugDiscovery()
        return SyncDebugScenarioResult(
          scenario: scenario,
          succeeded: true,
          summary: "Cleared sync cursors and queued discovery."
        )

      case .seedZeroDateAndFetch:
        let saved = await syncStorage.setState(SyncState(lastSyncDate: 0))
        stats.lastSyncDate = 0
        guard saved else {
          return SyncDebugScenarioResult(
            scenario: scenario,
            succeeded: false,
            summary: "Failed to save zero global sync date."
          )
        }
        queueDebugDiscovery()
        return SyncDebugScenarioResult(
          scenario: scenario,
          succeeded: true,
          summary: "Stored lastSyncDate=0 and queued discovery."
        )

      case .seedStaleDateAndFetch:
        let day: Int64 = 24 * 60 * 60
        let staleDate = max(0, nowSeconds() - 15 * day)
        let saved = await syncStorage.setState(SyncState(lastSyncDate: staleDate))
        stats.lastSyncDate = staleDate
        guard saved else {
          return SyncDebugScenarioResult(
            scenario: scenario,
            succeeded: false,
            summary: "Failed to save stale global sync date."
          )
        }
        queueDebugDiscovery()
        return SyncDebugScenarioResult(
          scenario: scenario,
          succeeded: true,
          summary: "Stored 15-day-old lastSyncDate and queued discovery."
        )

      case .rewindUserBucketAndFetch:
        guard let actor = await getBucketActor(key: .user, generation: generation) else {
          return SyncDebugScenarioResult(
            scenario: scenario,
            succeeded: false,
            summary: "Could not create the user-bucket owner."
          )
        }
        let snapshot = await actor.snapshot()
        let newState = BucketState(
          date: max(0, snapshot.date - 60 * 60),
          seq: max(0, snapshot.seq - 25)
        )
        guard await syncStorage.setBucketState(for: .user, state: newState) else {
          return SyncDebugScenarioResult(
            scenario: scenario,
            succeeded: false,
            summary: "Failed to save the rewound user-bucket cursor."
          )
        }
        await actor.debugRewindState(seq: newState.seq, date: newState.date)
        return SyncDebugScenarioResult(
          scenario: scenario,
          succeeded: true,
          summary: "Rewound only the user bucket from seq \(snapshot.seq) to \(newState.seq) and ran catch-up."
        )
    }
  }

  func runDebugBucketScenario(
    _ scenario: SyncDebugBucketScenario,
    key: BucketKey
  ) async -> SyncDebugActionResult {
    guard let actor = buckets[key] else {
      return SyncDebugActionResult(
        succeeded: false,
        summary: "The selected bucket is no longer tracked. Refresh sync stats and try again."
      )
    }

    let snapshot = await actor.snapshot()
    switch scenario {
      case .fetchLatest:
        await actor.debugFetchLatest()
        return SyncDebugActionResult(
          succeeded: true,
          summary: "Fetched the latest authoritative state for \(key.traceKind) from seq \(snapshot.seq)."
        )

      case .rewind25AndFetch:
        return await debugRewindAndFetch(
          actor: actor,
          key: key,
          from: snapshot,
          to: BucketState(
            date: max(0, snapshot.date - 60 * 60),
            seq: max(0, snapshot.seq - 25)
          )
        )

      case .rewindToZeroAndFetch:
        return await debugRewindAndFetch(
          actor: actor,
          key: key,
          from: snapshot,
          to: BucketState(date: 0, seq: 0)
        )

      case .overflowBufferAndRecover:
        guard await actor.debugOverflowRealtimeBufferAndRecover() else {
          return SyncDebugActionResult(
            succeeded: false,
            summary: "The current sequence is too close to the protocol Int32 limit to synthesize a safe overflow."
          )
        }
        return SyncDebugActionResult(
          succeeded: true,
          summary: "Overflowed and discarded a synthetic \(key.traceKind) buffer, then ran bounded server catch-up."
        )
    }
  }

  private func debugRewindAndFetch(
    actor: BucketActor,
    key: BucketKey,
    from oldState: SyncBucketSnapshot,
    to newState: BucketState
  ) async -> SyncDebugActionResult {
    guard await syncStorage.setBucketState(for: key, state: newState) else {
      return SyncDebugActionResult(
        succeeded: false,
        summary: "Failed to persist the debug cursor for \(key.traceKind)."
      )
    }
    await actor.debugRewindState(seq: newState.seq, date: newState.date)
    return SyncDebugActionResult(
      succeeded: true,
      summary: "Rewound only \(key.traceKind) from seq \(oldState.seq) to \(newState.seq) and ran catch-up."
    )
  }

  private func queueDebugDiscovery() {
    getStateFromServer()
  }
#endif

  // MARK: - Private Helpers

  private func chatHasNewUpdates(_ payload: InlineProtocol.UpdateChatHasNewUpdates) {
    log.trace("chat has new updates: \(payload)")
    let key = BucketKey.chat(peer: payload.peerID)
    registerDiscoveryTarget(key: key, seq: Int64(payload.updateSeq))
    launchRootTask { sync, generation in
      guard let bucketActor = await sync.getBucketActor(
        key: key,
        generation: generation
      ) else { return }
      let shouldFetch = await bucketActor.noteHasNewUpdates(upToSeq: Int64(payload.updateSeq))
      if shouldFetch {
        await bucketActor.fetchNewUpdates()
      } else {
        let snapshot = await bucketActor.snapshot()
        await sync.bucketDidAdvance(
          key: key,
          state: BucketState(date: snapshot.date, seq: snapshot.seq)
        )
      }
    }
  }

  private func spaceHasNewUpdates(_ payload: InlineProtocol.UpdateSpaceHasNewUpdates) {
    log.trace("space has new updates: \(payload)")
    let key = BucketKey.space(id: payload.spaceID)
    registerDiscoveryTarget(key: key, seq: Int64(payload.updateSeq))
    launchRootTask { sync, generation in
      guard let bucketActor = await sync.getBucketActor(
        key: key,
        generation: generation
      ) else { return }
      let shouldFetch = await bucketActor.noteHasNewUpdates(upToSeq: Int64(payload.updateSeq))
      if shouldFetch {
        await bucketActor.fetchNewUpdates()
      } else {
        let snapshot = await bucketActor.snapshot()
        await sync.bucketDidAdvance(
          key: key,
          state: BucketState(date: snapshot.date, seq: snapshot.seq)
        )
      }
    }
  }

  private func fetchUserBucket(upToSeq: Int64) {
    guard upToSeq > 0 else {
      log.warning("refusing an unbounded user bucket fetch")
      return
    }
    log.trace("fetching user bucket updates through seq \(upToSeq)")
    registerDiscoveryTarget(key: .user, seq: upToSeq)
    launchRootTask { sync, generation in
      guard let bucketActor = await sync.getBucketActor(key: .user, generation: generation) else { return }
      await bucketActor.setFetchTarget(upToSeq: upToSeq)
      await bucketActor.fetchNewUpdates()
    }
  }

  /// Closes fresh bootstrap at a finite server coordinate. The first state
  /// response seeds B; the actor captures current C through the ordinary state
  /// RPC, then replays only (B,C]. Concurrent catalog snapshots are guarded by
  /// their expected user cursor, so they either land before this replay or retry.
  private func probeFreshUserBucket(afterCheckpointSeq checkpointSeq: Int64) {
    guard checkpointSeq >= 0 else {
      log.warning("refusing a fresh user probe with a negative checkpoint sequence")
      return
    }
    registerDiscoveryTarget(key: .user, seq: 0)
    launchRootTask { sync, generation in
      guard let bucketActor = await sync.getBucketActor(key: .user, generation: generation) else { return }
      await bucketActor.setFetchTarget(upToSeq: checkpointSeq)
      _ = await bucketActor.noteHasNewUpdates(upToSeq: 0)
      await bucketActor.fetchNewUpdates()
    }
  }

  private func wakeBucketRetries(generation expectedGeneration: UInt64) async {
    guard isCurrent(expectedGeneration) else { return }
    // Only runtime work owners participate; dormant persisted buckets are not
    // loaded, materialized, or probed on a session edge.
    let actors = activeBucketActivityKeys.compactMap { buckets[$0] }
    for actor in actors {
      guard isCurrent(expectedGeneration) else { return }
      if await actor.wakeRetryIfNeeded() {
        launchRootTask { _, _ in await actor.fetchNewUpdates() }
      }
    }
  }

  private func getBucketActor(
    key: BucketKey,
    generation expectedGeneration: UInt64,
    retriesLoadFailure: Bool = true
  ) async -> BucketActor? {
    guard isCurrent(expectedGeneration) else { return nil }
    if let bucketActor = buckets[key] {
      if case let .through(targetSeq)? = queuedDiscoveryTargets[key] {
        let snapshot = await bucketActor.snapshot()
        if snapshot.seq >= targetSeq {
          await bucketDidAdvance(
            key: key,
            state: BucketState(date: snapshot.date, seq: snapshot.seq)
          )
        }
      }
      return bucketActor
    }
    let bucketState: BucketState
    do {
      bucketState = try await syncStorage.getBucketState(for: key)
    } catch {
      log.error("failed to load sync bucket state for \(key): \(error)")
      if retriesLoadFailure, isCurrent(expectedGeneration) {
        scheduleBucketLoadRetry(key: key)
      }
      return nil
    }
    guard isCurrent(expectedGeneration) else { return nil }
    if let bucketActor = buckets[key] {
      return bucketActor
    }
    let bucketActor = BucketActor(
      key: key,
      seq: bucketState.seq,
      date: bucketState.date,
      client: client,
      sync: self,
      fetchLimiter: bucketFetchLimiter,
      accountMutationToken: accountMutationToken
    )
    buckets[key] = bucketActor
    // A queued finite target may have been satisfied by an earlier direct
    // apply or snapshot before this actor was materialized. Clear only that
    // exact queued dependency; `.latest` still requires an authoritative fetch.
    if case let .through(targetSeq)? = queuedDiscoveryTargets[key],
       bucketState.seq >= targetSeq {
      await bucketDidAdvance(key: key, state: bucketState)
    }
    return bucketActor
  }

  private func scheduleBucketLoadRetry(key: BucketKey, immediate: Bool = false) {
    guard bucketLoadRetries[key] == nil else { return }
    let id = UUID()
    guard let task = makeRootTask({ sync, generation in
      await sync.retryBucketLoad(key: key, id: id, generation: generation, immediate: immediate)
    }) else { return }
    bucketLoadRetries[key] = (id, task)
    requestSyncActivityRefresh()
  }

  private func retryBucketLoad(
    key: BucketKey,
    id: UUID,
    generation expectedGeneration: UInt64,
    immediate: Bool
  ) async {
    defer {
      if bucketLoadRetries[key]?.id == id {
        bucketLoadRetries.removeValue(forKey: key)
      }
      requestSyncActivityRefresh()
    }
    var attempt = 0
    while isCurrent(expectedGeneration), !Task.isCancelled {
      if !immediate || attempt > 0 {
        do { try await Task.sleep(for: SyncRetryPolicy.delay(attempt: attempt)) }
        catch { return }
      }
      guard isCurrent(expectedGeneration), !Task.isCancelled else { return }
      attempt += 1
      guard let actor = await getBucketActor(
        key: key,
        generation: expectedGeneration,
        retriesLoadFailure: false
      ) else { continue }
      var exactTargets: [BucketKey: DiscoveryTarget] = [:]
      if let target = queuedDiscoveryTargets[key] {
        mergeDiscoveryTarget(target, for: key, into: &exactTargets)
      }
      if let target = activeDiscoveryRound?.pendingTargets[key] {
        mergeDiscoveryTarget(target, for: key, into: &exactTargets)
      }
      for round in pendingDiscoveryRounds.values {
        if let target = round.pendingTargets[key] {
          mergeDiscoveryTarget(target, for: key, into: &exactTargets)
        }
      }
      guard let target = exactTargets[key] else { return }
      let sequence: Int64
      switch target {
        case let .through(value): sequence = value
        case .latest: sequence = 0
      }
      if await actor.noteHasNewUpdates(upToSeq: sequence) {
        await actor.fetchNewUpdates()
      } else {
        let state = await actor.snapshot()
        await bucketDidAdvance(key: key, state: BucketState(date: state.date, seq: state.seq))
      }
      return
    }
  }

  private func invalidateAllBuckets() async {
    let existingBuckets = Array(buckets.values)
    buckets.removeAll()

    for bucket in existingBuckets {
      await bucket.invalidate()
    }
    await bucketFetchLimiter.cancelAllWaiters()
    for bucket in existingBuckets {
      await bucket.waitUntilIdle()
    }
  }

  /// Get the state from the server
  private func getStateFromServer() {
    guard !isStateFetchInFlight else {
      isStateFetchPending = true
      log.trace("getUpdatesState already in flight")
      // An accepted reconnect/open edge should interrupt retry sleep without
      // creating a second state owner. The in-flight owner will make the next
      // attempt against the new session.
      wakeStateRetry()
      requestSyncActivityRefresh()
      return
    }
    let launched = launchRootTask { sync, generation in
      await sync.fetchStateFromServerWithRetry(generation: generation)
    }
    isStateFetchInFlight = launched
    requestSyncActivityRefresh()
  }

  private func fetchStateFromServerWithRetry(generation expectedGeneration: UInt64) async {
    defer {
      isStateFetchInFlight = false
      if isStateFetchPending {
        isStateFetchPending = false
        getStateFromServer()
      }
      requestSyncActivityRefresh()
    }
    guard isCurrent(expectedGeneration) else { return }
    guard let client else {
      log.error("client is nil")
      return
    }

    // A reconnect may have woken the previous owner while its RPC was still
    // completing. Its pending flag starts one fresh owner after this one; the
    // current owner must not carry that wake into a later retry sleep.
    stateRetryWakeRequested = false

    let totalStartedAt = Date()
    PerformanceTrace.breadcrumb(
      "sync state check started",
      category: "sync.lifecycle",
      data: [
        "retry_policy": "1,2,4,5,5+jitter; explicit-rate-limit=60-80",
      ]
    )

    var retryAttempt = 0
    while true {
      let attempt = retryAttempt + 1
      let attemptStartedAt = Date()
      let span = PerformanceTrace.begin(
        "SyncGetUpdatesState",
        category: .sync,
        "attempt=\(attempt)"
      )
      do {
        guard isCurrent(expectedGeneration), !Task.isCancelled else { return }
        guard let state = await preparedSyncState(generation: expectedGeneration) else {
          throw StateFetchAttemptError.storageReadFailed
        }
        guard isCurrent(expectedGeneration), !Task.isCancelled else { return }
        let isFreshCheckpoint = state.lastSyncDate == 0
        // This attempt runs on the current accepted session and therefore
        // consumes any discovery wake received before its RPC was admitted.
        isStateFetchPending = false
        stateRetryWakeRequested = false
        if !isFreshCheckpoint {
          nextDiscoveryRoundGeneration &+= 1
          var round = ActiveDiscoveryRound(generation: nextDiscoveryRoundGeneration)
          round.pendingTargets = queuedDiscoveryTargets
          round.observedTarget = queuedDiscoveryTargets.keys.contains { $0 != .user }
          queuedDiscoveryTargets.removeAll()
          activeDiscoveryRound = round
          await publishSyncActivityIfNeeded()
        }
        // The protocol session resumes this direct call only after every earlier
        // wire-ordered account event has been processed by the account collector.
        // Therefore all hints caused by this request are registered before the
        // result is allowed to stage its global checkpoint.
        let result = try await client.callRpc(method: .getUpdatesState, input: .getUpdatesState(.with {
          if !isFreshCheckpoint {
            $0.date = state.lastSyncDate
          }
        }), timeout: Self.getUpdatesStateTimeout)
        guard isCurrent(expectedGeneration), !Task.isCancelled else { return }
        guard case let .getUpdatesState(payload) = result else {
          throw StateFetchAttemptError.invalidResponse
        }
        guard payload.date > 0 else {
          throw StateFetchAttemptError.invalidDate
        }
        log.trace("sent get updates state request with date: \(state.lastSyncDate)")
        log.trace(
          "received get updates state date: \(payload.date), updatesFound=\(payload.hasUpdatesFound ? String(payload.updatesFound) : "unknown")"
        )
        if isFreshCheckpoint {
          guard payload.hasSeq else {
            throw StateFetchAttemptError.missingUserSequence
          }
          guard payload.seq >= 0 else {
            throw StateFetchAttemptError.invalidResponse
          }
          let existingUser = try await syncStorage.getBucketState(for: .user)
          guard isCurrent(expectedGeneration), !Task.isCancelled else { return }
          if accountMutationToken != nil {
            let bootstrapStartedAt = Date()
            PerformanceTrace.breadcrumb(
              "fresh account bootstrap started",
              category: "sync.lifecycle",
              data: ["target_seq": payload.seq]
            )
            // A zero global date is a normal empty-store bootstrap, not a
            // reason to seed only cursors. Install the authoritative account
            // projection at the captured P0 checkpoint, capture P1 after the
            // snapshot, and let the existing repair owner replay (P0, P1].
            // The app remains mounted against its usable local store while the
            // projection fills in.
            let checkpoint = BucketState(date: payload.date, seq: Int64(payload.seq))
            guard let outcome = await repairUserBucket(
              targetState: existingUser,
              reason: "fresh_account_bootstrap",
              replacesActiveCatalog: true,
              requiresProjectionAudit: true,
              capturedCheckpointState: checkpoint,
              persistProjectionsIndependently: true
            ) else {
              PerformanceTrace.breadcrumb(
                "fresh account bootstrap failed",
                category: "sync.lifecycle",
                level: .error,
                data: [
                  "duration_ms": PerformanceTrace.elapsedMilliseconds(since: bootstrapStartedAt),
                  "failed": 1,
                  "target_seq": payload.seq,
                ]
              )
              throw StateFetchAttemptError.bootstrapRepairFailed
            }

            nextDiscoveryRoundGeneration &+= 1
            var round = ActiveDiscoveryRound(generation: nextDiscoveryRoundGeneration)
            round.observedTarget = true
            round.checkpointPolicy = .exactFresh
            round.pendingTargets = queuedDiscoveryTargets
            queuedDiscoveryTargets.removeAll()
            mergeDiscoveryTarget(.through(checkpoint.seq), for: .user, into: &round.pendingTargets)
            try await stageDiscoveryCheckpoint(
              checkpoint.date,
              updatesFound: true,
              round: round,
              generation: expectedGeneration
            )
            guard await applyUserRepairOutcome(outcome) != nil else {
              requeuePendingDiscoveryRound(round.generation)
              reportUserRepairFailure(phase: .admission, cause: .persistenceFailed)
              PerformanceTrace.breadcrumb(
                "fresh account bootstrap failed",
                category: "sync.lifecycle",
                level: .error,
                data: [
                  "duration_ms": PerformanceTrace.elapsedMilliseconds(since: bootstrapStartedAt),
                  "failed": 1,
                  "target_seq": payload.seq,
                ]
              )
              throw StateFetchAttemptError.bootstrapRepairFailed
            }
            let bootstrapDurationMs = PerformanceTrace.elapsedMilliseconds(since: bootstrapStartedAt)
            PerformanceTrace.breadcrumb(
              "fresh account bootstrap completed",
              category: "sync.lifecycle",
              data: [
                "duration_ms": bootstrapDurationMs,
                "target_seq": payload.seq,
              ]
            )
            PerformanceTrace.slowBreadcrumb(
              "fresh account bootstrap was slow",
              category: "sync.lifecycle",
              durationMs: bootstrapDurationMs,
              thresholdMs: 5_000,
              data: ["target_seq": payload.seq]
            )
          } else if existingUser.seq > 0 || existingUser.date > 0 {
            // A user cursor may have committed before a failed global write.
            // It is no longer pristine: replay its exact gap instead of seeding
            // a newer server checkpoint and silently skipping those events.
            nextDiscoveryRoundGeneration &+= 1
            var round = ActiveDiscoveryRound(generation: nextDiscoveryRoundGeneration)
            round.observedTarget = true
            round.pendingTargets = queuedDiscoveryTargets
            queuedDiscoveryTargets.removeAll()
            if Int64(payload.seq) > existingUser.seq {
              mergeDiscoveryTarget(.through(Int64(payload.seq)), for: .user, into: &round.pendingTargets)
            }
            try await stageDiscoveryCheckpoint(
              payload.date, updatesFound: false, round: round, generation: expectedGeneration
            )
            probeFreshUserBucket(afterCheckpointSeq: Int64(payload.seq))
          } else {
            let seed = BucketState(date: payload.date, seq: Int64(payload.seq))
            let appliedSeed = await applyUpdates.apply(
              updates: [], source: .syncCatchup, sidecars: nil,
              bucketCommit: UpdateBucketCommit(key: .user, state: seed, expectedStartState: existingUser),
              mutationToken: accountMutationToken
            )
            guard appliedSeed.succeeded else { throw StateFetchAttemptError.userCheckpointWriteFailed }
            let seededUser: BucketState?
            if let committed = appliedSeed.committedBucketState {
              seededUser = committed
            } else if auth == nil {
              // Lightweight storage/apply fakes have no shared transaction.
              // An authenticated production owner must return its CAS commit.
              seededUser = await syncStorage.advanceBucketState(for: .user, state: seed)
            } else {
              seededUser = nil
            }
            guard let seededUser else {
              throw StateFetchAttemptError.userCheckpointWriteFailed
            }
            await installSnapshotBucketStates([.user: seededUser])
            let seededGlobal = await syncStorage.setState(SyncState(lastSyncDate: payload.date))
            guard isCurrent(expectedGeneration), !Task.isCancelled else { return }
            guard seededGlobal else {
              throw StateFetchAttemptError.globalCheckpointWriteFailed
            }
            stats.lastSyncDate = payload.date
            probeFreshUserBucket(afterCheckpointSeq: Int64(payload.seq))
          }
          // Production bootstraps use the account repair snapshot above. The
          // cursor-only branch remains solely for lightweight Sync tests that
          // deliberately construct no authenticated account mutation owner.
        } else {
          guard payload.hasSeq else {
            throw StateFetchAttemptError.missingUserSequence
          }
          guard payload.seq >= 0 else {
            throw StateFetchAttemptError.invalidResponse
          }
          if payload.date < state.lastSyncDate {
            // A server-regressed checkpoint is exceptional: monotonic-ignore
            // would permanently skip the account repair and any exact child
            // demands carried by it. Repair the admitted user projection first,
            // then let the pending round commit the repaired checkpoint only
            // after all returned targets converge.
            guard let userActor = await getBucketActor(
              key: .user,
              generation: expectedGeneration
            ) else {
              throw StateFetchAttemptError.invalidResponse
            }
            let currentUser = await userActor.snapshot()
            var regressionRound = activeDiscoveryRound ?? ActiveDiscoveryRound(
              generation: nextDiscoveryRoundGeneration
            )
            regressionRound.observedTarget = true
            regressionRound.checkpointPolicy = .allowingRegression
            activeDiscoveryRound = regressionRound
            guard let outcome = await repairUserBucket(
              targetState: BucketState(date: currentUser.date, seq: currentUser.seq),
              reason: "checkpoint_regression",
              requiresProjectionAudit: true
            ), await applyUserRepairOutcome(outcome) != nil
            else {
              throw StateFetchAttemptError.invalidResponse
            }
            let repairedState = await userActor.snapshot()
            let repairedRound = activeDiscoveryRound ?? regressionRound
            try await stageDiscoveryCheckpoint(
              // The checkpoint attached to this round is the server's explicit
              // regression marker. Never derive it from the effective user
              // cursor: a monotonic cursor may intentionally retain a higher
              // durable date after the repair.
              payload.date,
              updatesFound: true,
              round: repairedRound,
              generation: expectedGeneration
            )
            activeDiscoveryRound = nil
            span.end(
              "attempt=\(attempt) success=true regression_repaired=true duration_ms=\(PerformanceTrace.elapsedMilliseconds(since: attemptStartedAt))"
            )
            PerformanceTrace.breadcrumb(
              "sync checkpoint regression repaired",
              category: "sync.lifecycle",
              level: .warning,
              data: [
                "attempt": attempt,
                "server_date": payload.date,
                "repaired_date": repairedState.date,
              ]
            )
            return
          }
          var round = activeDiscoveryRound ?? ActiveDiscoveryRound(generation: nextDiscoveryRoundGeneration)
          // The user cursor is part of every warm discovery round, including an
          // updatesFound=false response. This keeps account projection changes
          // from being silently omitted when the server reports no bucket hint.
          // It is not evidence that the Chat/Space hints promised by
          // updatesFound=true were delivered in this round.
          if payload.seq > 0 {
            mergeDiscoveryTarget(
              .through(Int64(payload.seq)),
              for: .user,
              into: &round.pendingTargets
            )
          } else {
            // Keep the response's explicit zero cursor in the same dependency
            // set as every other warm response. It is already satisfied by any
            // non-negative local cursor, and therefore does not launch a
            // seqEnd=0 request, but it must not disappear before checkpoint
            // staging (especially when a queued user target is being merged).
            mergeDiscoveryTarget(
              .through(0),
              for: .user,
              into: &round.pendingTargets
            )
            // A zero cursor is attached to the round for accounting, then
            // immediately retired as satisfied. Preserve any older explicit
            // `.latest`/positive target that was already waiting on the user.
            if case .through(0)? = round.pendingTargets[.user] {
              round.pendingTargets.removeValue(forKey: .user)
            }
          }
          try await stageDiscoveryCheckpoint(
            payload.date,
            updatesFound: payload.hasUpdatesFound && payload.updatesFound,
            round: round,
            generation: expectedGeneration
          )
          activeDiscoveryRound = nil
          if payload.seq > 0 {
            fetchUserBucket(upToSeq: Int64(payload.seq))
          }
        }
        guard isCurrent(expectedGeneration), !Task.isCancelled else { return }
        span.end(
          "attempt=\(attempt) success=true duration_ms=\(PerformanceTrace.elapsedMilliseconds(since: attemptStartedAt))"
        )
        PerformanceTrace.breadcrumb(
          "sync state check completed",
          category: "sync.lifecycle",
          data: [
            "attempt": attempt,
            "duration_ms": PerformanceTrace.elapsedMilliseconds(since: totalStartedAt),
          ]
        )
        return
      } catch {
        mergeActiveDiscoveryTargetsIntoQueue()
        span.end(
          "attempt=\(attempt) success=false duration_ms=\(PerformanceTrace.elapsedMilliseconds(since: attemptStartedAt))"
        )
        if let stateError = error as? StateFetchAttemptError,
           case .bootstrapRepairFailed = stateError
        {
          // The repair owner emitted one finite, phase-specific Sentry error.
          // Keep retries visible locally without creating a second issue group.
          log.warning("fresh account bootstrap will retry after repair failure")
        } else {
          log.error("failed to get updates state", error: error)
        }
        let delay = getUpdatesStateRetryDelay(
          attempt: retryAttempt,
          rateLimited: isRateLimitError(error)
        )
        retryAttempt += 1
        log.warning("scheduling getUpdatesState retry in \(delay)")
        await waitForStateRetry(delay)
        guard isCurrent(expectedGeneration), !Task.isCancelled else { return }
      }
    }
  }

  private func getUpdatesStateRetryDelay(attempt: Int, rateLimited: Bool) -> Duration {
    SyncRetryPolicy.delay(attempt: attempt, rateLimited: rateLimited)
  }

  private func waitForStateRetry(_ delay: Duration) async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        try? await Task.sleep(for: delay)
      }
      group.addTask {
        await self.waitForStateRetryWake()
      }
      _ = await group.next()
      group.cancelAll()
    }
  }

  private func waitForStateRetryWake() async {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled {
          continuation.resume()
        } else if stateRetryWakeRequested {
          stateRetryWakeRequested = false
          continuation.resume()
        } else {
          stateRetryWakeWaiter = (id, continuation)
        }
      }
    } onCancel: {
      Task { await self.cancelStateRetryWaiter(id: id) }
    }
  }

  private func cancelStateRetryWaiter(id: UUID) {
    guard let waiter = stateRetryWakeWaiter, waiter.id == id else { return }
    stateRetryWakeWaiter = nil
    waiter.continuation.resume()
  }

  private func wakeStateRetry() {
    stateRetryWakeRequested = true
    guard let waiter = stateRetryWakeWaiter else { return }
    stateRetryWakeWaiter = nil
    stateRetryWakeRequested = false
    waiter.continuation.resume()
  }

  private func isRateLimitError(_ error: Error) -> Bool {
    guard case let ProtocolSessionError.rpcError(errorCode, _, code) = error else {
      return false
    }
    return errorCode == .rateLimit || code == 429
  }

  private func preparedSyncState(generation expectedGeneration: UInt64) async -> SyncState? {
    guard isCurrent(expectedGeneration) else { return nil }
    let state: SyncState
    do {
      state = try await syncStorage.getState()
    } catch {
      log.error("failed to load global sync state: \(error)")
      return nil
    }
    guard isCurrent(expectedGeneration) else { return nil }
    return state
  }

  private func updateBucketStates(
    for updates: [InlineProtocol.Update],
    generation expectedGeneration: UInt64
  ) async {
    guard isCurrent(expectedGeneration) else { return }
    // We need to group by bucket because we want the MAX seq/date for each bucket.
    var maxStates: [BucketKey: (seq: Int64, date: Int64)] = [:]

    for update in updates {
      guard let key = getBucketKey(for: update) else { continue }

      // Only process if we have a valid seq > 0
      if update.hasSeq, update.seq > 0 {
        let current = maxStates[key] ?? (seq: 0, date: 0)
        if Int64(update.seq) > current.seq {
          maxStates[key] = (seq: Int64(update.seq), date: update.date)
        }
      }
    }

    var statesToSave: [BucketKey: BucketState] = [:]

    for (key, state) in maxStates {
      statesToSave[key] = BucketState(date: state.date, seq: state.seq)
    }

    if !statesToSave.isEmpty {
      log.trace("saving batch bucket states: \(statesToSave.count)")
      let saved = await syncStorage.setBucketStates(states: statesToSave)
      guard isCurrent(expectedGeneration) else { return }
      guard saved else {
        log.error("failed to save batch bucket states: \(statesToSave.count)")
        return
      }
    }

    for (key, state) in maxStates {
      if let actor = buckets[key] {
        await actor.updateState(seq: state.seq, date: state.date)
      }
      await bucketDidAdvance(
        key: key,
        state: BucketState(date: state.date, seq: state.seq)
      )
    }
  }

  private func maxUpdateDate(in updates: [InlineProtocol.Update]) -> Int64 {
    var maxDate: Int64 = 0
    for update in updates where update.date > 0 {
      maxDate = max(maxDate, update.date)
    }
    return maxDate
  }

  private func shouldFetchUserBucketAfterDirectApplyFailure(_ updates: [InlineProtocol.Update]) -> Bool {
    for update in updates {
      if case .participantAdd = update.update { return true }
      if case .participantDelete = update.update { return true }
      if case .participantGroupAdd = update.update { return true }
      if case .participantGroupDelete = update.update { return true }
      if case .chatPermissions = update.update { return true }
    }
    return false
  }

  private func getBucketSnapshots() async -> [SyncBucketSnapshot] {
    var snapshots: [SyncBucketSnapshot] = []
    snapshots.reserveCapacity(buckets.count)
    for (_, actor) in buckets {
      let snapshot = await actor.snapshot()
      snapshots.append(snapshot)
    }
    return snapshots
  }

  private func recordDirectApply(count: Int) {
    stats.directUpdatesApplied += Int64(count)
    stats.lastDirectApplyAt = nowSeconds()
  }

  private func nowSeconds() -> Int64 {
    Int64(Date().timeIntervalSince1970)
  }

  func recordBucketFetchStart() {
    stats.bucketFetchCount += 1
    stats.lastBucketFetchAt = nowSeconds()
  }

  func recordBucketFetchFailure() {
    stats.bucketFetchFailures += 1
    stats.lastBucketFetchFailureAt = nowSeconds()
  }

  func recordBucketFetchTooLong() {
    stats.bucketFetchTooLong += 1
  }

  func recordBucketFetchFollowup() {
    stats.bucketFetchFollowups += 1
  }

  func recordRealtimeBufferRecovery() {
    stats.realtimeBufferRecoveries += 1
  }

  func bucketFetchActivityStarted(for key: BucketKey) async {
    activeBucketActivityKeys.insert(key)
    await publishSyncActivityIfNeeded()
  }

  func bucketFetchActivityEnded(for key: BucketKey) async {
    activeBucketActivityKeys.remove(key)
    await publishSyncActivityIfNeeded()
  }

  func recordBucketUpdatesApplied(applied: Int, skipped: Int, duplicates: Int) {
    stats.bucketUpdatesApplied += Int64(applied)
    stats.bucketUpdatesSkipped += Int64(skipped)
    stats.bucketUpdatesDuplicateSkipped += Int64(duplicates)
  }

  private func registerDiscoveryTarget(key: BucketKey, seq: Int64) {
    let target: DiscoveryTarget = seq > 0 ? .through(seq) : .latest
    guard var round = activeDiscoveryRound else {
      var attachedToPendingRound = false
      // A user repair can begin while an earlier discovery round is already
      // staged and waiting on the user cursor. Keep its exact child demands in
      // every such round; putting them only in the next queued round would let
      // an older checkpoint commit before the repair's children converge.
      for generation in pendingDiscoveryRounds.keys.sorted() {
        guard var pendingRound = pendingDiscoveryRounds[generation],
              pendingRound.pendingTargets[.user] != nil
        else { continue }
        mergeDiscoveryTarget(target, for: key, into: &pendingRound.pendingTargets)
        pendingDiscoveryRounds[generation] = pendingRound
        attachedToPendingRound = true
      }
      if attachedToPendingRound {
        requestSyncActivityRefresh()
        return
      }
      // A hint received after a state result belongs to the next discovery
      // round. Keeping it until that round is opened prevents a later
      // updatesFound=true response from borrowing a target from the old round.
      mergeDiscoveryTarget(target, for: key, into: &queuedDiscoveryTargets)
      return
    }
    if key != .user { round.observedTarget = true }
    mergeDiscoveryTarget(target, for: key, into: &round.pendingTargets)
    activeDiscoveryRound = round
    requestSyncActivityRefresh()
  }

  /// Installs exact child demands returned by an admitted user repair. This is
  /// deliberately target-driven: a GET_CHATS snapshot never causes a bucket
  /// sweep, and the demands are registered before the user cursor advances.
  func registerUserRepairTargets(_ targets: [BucketKey: Int64]) {
    for (key, seq) in targets {
      registerDiscoveryTarget(key: key, seq: seq)
    }
  }

  /// Keeps a pending user repair's proposed cursor in the same discovery
  /// dependency set as its children. The apply owner will not advance that
  /// cursor until the children are durable.
  func registerUserRepairFinalizationTarget(_ seq: Int64) {
    registerDiscoveryTarget(key: .user, seq: seq)
  }

  /// Launch only the child buckets explicitly returned by user repair.
  func launchUserRepairTargets(_ targets: [BucketKey: Int64]) async {
    var tasks: [Task<Void, Never>] = []
    for (key, seq) in targets {
      if let task = makeRootTask({ sync, generation in
        guard let actor = await sync.getBucketActor(key: key, generation: generation) else { return }
        if await actor.noteHasNewUpdates(upToSeq: seq) {
          await actor.fetchNewUpdates()
        } else {
          let snapshot = await actor.snapshot()
          await sync.bucketDidAdvance(key: key, state: BucketState(date: snapshot.date, seq: snapshot.seq))
        }
      }) {
        tasks.append(task)
      }
    }
    // Await every admitted child task before returning. Finalization still
    // happens from each child's durable bucketDidAdvance callback, but this
    // keeps the pending repair's admission window explicit and bounded to the
    // exact target set returned by the user snapshot.
    for task in tasks {
      await task.value
    }
  }

  private func mergeActiveDiscoveryTargetsIntoQueue() {
    guard let round = activeDiscoveryRound else { return }
    for (key, target) in round.pendingTargets {
      mergeDiscoveryTarget(target, for: key, into: &queuedDiscoveryTargets)
    }
    activeDiscoveryRound = nil
    requestSyncActivityRefresh()
  }

  /// A failed handoff to the user actor must not discard realtime hints that
  /// arrived after P0. Return the exact pending round to the existing queue so
  /// the next discovery attempt owns those demands.
  private func requeuePendingDiscoveryRound(_ generation: UInt64) {
    guard let round = pendingDiscoveryRounds.removeValue(forKey: generation) else { return }
    for (key, target) in round.pendingTargets {
      mergeDiscoveryTarget(target, for: key, into: &queuedDiscoveryTargets)
    }
    requestSyncActivityRefresh()
  }

  private func mergeDiscoveryTarget(
    _ target: DiscoveryTarget,
    for key: BucketKey,
    into targets: inout [BucketKey: DiscoveryTarget]
  ) {
    guard let existing = targets[key] else {
      targets[key] = target
      return
    }
    switch (existing, target) {
      case (.latest, _), (_, .latest):
        targets[key] = .latest
      case let (.through(old), .through(new)):
        targets[key] = .through(max(old, new))
    }
  }

  private func discoveryTarget(
    _ target: DiscoveryTarget,
    isSatisfiedBy state: BucketState,
    authoritative: Bool
  ) -> Bool {
    switch target {
      case let .through(seq):
        state.seq >= seq
      case .latest:
        authoritative
    }
  }

  func bucketDidAdvance(
    key: BucketKey,
    state: BucketState,
    authoritative: Bool = false
  ) async {
    if let target = queuedDiscoveryTargets[key],
       discoveryTarget(target, isSatisfiedBy: state, authoritative: authoritative) {
      queuedDiscoveryTargets.removeValue(forKey: key)
    }

    if var round = activeDiscoveryRound,
       let target = round.pendingTargets[key],
       discoveryTarget(target, isSatisfiedBy: state, authoritative: authoritative) {
      round.pendingTargets.removeValue(forKey: key)
      activeDiscoveryRound = round
    }

    var changedPendingRound = false
    for generation in pendingDiscoveryRounds.keys.sorted() {
      guard var round = pendingDiscoveryRounds[generation],
            let target = round.pendingTargets[key],
            discoveryTarget(target, isSatisfiedBy: state, authoritative: authoritative)
      else { continue }
      round.pendingTargets.removeValue(forKey: key)
      pendingDiscoveryRounds[generation] = round
      changedPendingRound = true
    }

    if changedPendingRound {
      if !(await commitDiscoveryCheckpointsIfReady()) {
        // The bucket is already durable. Re-run discovery so a transient global
        // checkpoint write failure cannot leave convergence stuck indefinitely.
        getStateFromServer()
      }
    }
    if key != .user, let userActor = buckets[.user] {
      await userActor.resolvePendingUserRepairTarget(
        key: key,
        state: state,
        authoritative: authoritative
      )
    }
    await publishSyncActivityIfNeeded()
  }

  /// An inaccessible bucket cannot satisfy its sequence target, but it must not
  /// pin global discovery forever. Remove only this exact dependency and retain
  /// the durable cursor/cache for a future access restoration.
  func resolveInaccessibleBucket(key: BucketKey) async {
    queuedDiscoveryTargets.removeValue(forKey: key)
    if var round = activeDiscoveryRound {
      round.pendingTargets.removeValue(forKey: key)
      activeDiscoveryRound = round
    }
    for generation in pendingDiscoveryRounds.keys.sorted() {
      guard var round = pendingDiscoveryRounds[generation] else { continue }
      round.pendingTargets.removeValue(forKey: key)
      pendingDiscoveryRounds[generation] = round
    }
    if key != .user, let userActor = buckets[.user] {
      await userActor.pendingUserRepairTargetBecameInaccessible(key: key)
    }
    guard !(await commitDiscoveryCheckpointsIfReady()) else {
      await publishSyncActivityIfNeeded()
      return
    }
    getStateFromServer()
    await publishSyncActivityIfNeeded()
  }

  private func stageDiscoveryCheckpoint(
    _ checkpoint: Int64,
    updatesFound: Bool,
    round: ActiveDiscoveryRound,
    generation expectedGeneration: UInt64
  ) async throws {
    guard isCurrent(expectedGeneration), checkpoint > 0 else { return }
    guard !updatesFound || round.observedTarget else {
      throw StateFetchAttemptError.missingDiscoveryTargets
    }
    pendingDiscoveryRounds[round.generation] = PendingDiscoveryRound(
      checkpoint: checkpoint,
      checkpointPolicy: round.checkpointPolicy,
      pendingTargets: round.pendingTargets
    )
    guard await commitDiscoveryCheckpointsIfReady(generation: expectedGeneration) else {
      throw StateFetchAttemptError.globalCheckpointWriteFailed
    }
    await publishSyncActivityIfNeeded()
  }

  private func commitDiscoveryCheckpointsIfReady(generation expectedGeneration: UInt64? = nil) async -> Bool {
    for roundGeneration in pendingDiscoveryRounds.keys.sorted() {
      guard let round = pendingDiscoveryRounds[roundGeneration], round.pendingTargets.isEmpty else {
        // A later discovery result cannot move the shared date past an older
        // round whose target is still unapplied.
        break
      }
      let saved: Bool
      switch round.checkpointPolicy {
      case .safetyGap:
        saved = await updateLastSyncDate(
          maxAppliedDate: round.checkpoint,
          source: "getUpdatesState:converged",
          generation: expectedGeneration
        )
      case .allowingRegression:
        saved = await setLastSyncDateAllowingRegression(
          maxAppliedDate: round.checkpoint,
          source: "getUpdatesState:regression-converged",
          generation: expectedGeneration
        )
      case .exactFresh:
        saved = await setFreshLastSyncDate(
          checkpoint: round.checkpoint,
          source: "getUpdatesState:fresh-account-bootstrap",
          generation: expectedGeneration
        )
      }
      guard saved else { return false }
      pendingDiscoveryRounds.removeValue(forKey: roundGeneration)
    }
    return true
  }

  /// A fresh account snapshot is authoritative exactly at P0. Persisting the
  /// normal safety-gap date here would cause a subsequent launch to repeat the
  /// catalog replacement even though the snapshot and bounded suffix already
  /// converged. If another owner has since established a non-zero checkpoint,
  /// preserve it instead of regressing.
  private func setFreshLastSyncDate(
    checkpoint: Int64,
    source: String,
    generation expectedGeneration: UInt64? = nil
  ) async -> Bool {
    if let expectedGeneration, !isCurrent(expectedGeneration) { return false }
    guard checkpoint > 0 else { return false }
    let currentState: SyncState
    do {
      currentState = try await syncStorage.getState()
    } catch {
      log.error(
        "failed to load global sync state before fresh checkpoint",
        error: StateFetchAttemptError.storageReadFailed
      )
      return false
    }
    if let expectedGeneration, !isCurrent(expectedGeneration) { return false }
    guard currentState.lastSyncDate == 0 else {
      stats.lastSyncDate = currentState.lastSyncDate
      return true
    }
    let saved = await syncStorage.setState(SyncState(lastSyncDate: checkpoint))
    if let expectedGeneration, !isCurrent(expectedGeneration) { return false }
    guard saved else {
      log.error(
        "failed to write fresh global sync checkpoint",
        error: StateFetchAttemptError.globalCheckpointWriteFailed
      )
      return false
    }
    stats.lastSyncDate = checkpoint
    log.debug("stored exact fresh lastSyncDate=\(checkpoint) (source=\(source))")
    return true
  }

  /// Explicit checkpoint regression is admitted only for a server-regressed
  /// state response after the account snapshot and exact child targets have
  /// converged. Normal discovery remains monotonic through updateLastSyncDate.
  private func setLastSyncDateAllowingRegression(
    maxAppliedDate: Int64,
    source: String,
    generation expectedGeneration: UInt64? = nil
  ) async -> Bool {
    if let expectedGeneration, !isCurrent(expectedGeneration) { return false }
    guard maxAppliedDate > 0 else { return false }
    let proposed = max(0, maxAppliedDate - config.lastSyncSafetyGapSeconds)
    do {
      _ = try await syncStorage.getState()
    } catch {
      log.error("failed to load global sync state before allowing regression from \(source): \(error)")
      return false
    }
    if let expectedGeneration, !isCurrent(expectedGeneration) { return false }
    let saved = await syncStorage.setState(SyncState(lastSyncDate: proposed))
    if let expectedGeneration, !isCurrent(expectedGeneration) { return false }
    guard saved else {
      log.error("failed to write regressed lastSyncDate=\(proposed) (source=\(source))")
      return false
    }
    stats.lastSyncDate = proposed
    log.warning("allowed explicit lastSyncDate regression to \(proposed) (maxAppliedDate=\(maxAppliedDate), source=\(source))")
    return true
  }

  @discardableResult
  func updateLastSyncDate(
    maxAppliedDate: Int64,
    source: String,
    generation expectedGeneration: UInt64? = nil
  ) async -> Bool {
    if let expectedGeneration, !isCurrent(expectedGeneration) { return false }
    guard maxAppliedDate > 0 else { return true }

    let gap = config.lastSyncSafetyGapSeconds
    let proposed = max(0, maxAppliedDate - gap)
    let currentState: SyncState
    do {
      currentState = try await syncStorage.getState()
    } catch {
      log.error("failed to load global sync state before advancing from \(source): \(error)")
      return false
    }
    if let expectedGeneration, !isCurrent(expectedGeneration) { return false }

    guard proposed > currentState.lastSyncDate else {
      log.trace(
        "skipping lastSyncDate update from \(source): current=\(currentState.lastSyncDate), proposed=\(proposed)"
      )
      return true
    }

    let newState = SyncState(lastSyncDate: proposed)
    let saved = await syncStorage.setState(newState)
    if let expectedGeneration, !isCurrent(expectedGeneration) { return false }
    guard saved else {
      log.error(
        "failed to update lastSyncDate from \(currentState.lastSyncDate) to \(proposed) (source=\(source))"
      )
      return false
    }
    stats.lastSyncDate = proposed
    log.debug(
      "updated lastSyncDate from \(currentState.lastSyncDate) to \(proposed) (maxAppliedDate=\(maxAppliedDate), gap=\(gap)s, source=\(source))"
    )
    return true
  }

  @discardableResult
  private func launchRootTask(
    _ operation: @escaping @Sendable (Sync, UInt64) async -> Void
  ) -> Bool {
    makeRootTask(operation) != nil
  }

  private func makeRootTask(
    _ operation: @escaping @Sendable (Sync, UInt64) async -> Void
  ) -> Task<Void, Never>? {
    guard acceptsWork, !isResetting else { return nil }
    let id = UUID()
    let expectedGeneration = generation
    let task = Task { [weak self] in
      guard let self else { return }
      await operation(self, expectedGeneration)
      await self.finishRootTask(id)
    }
    rootTasks[id] = task
    return task
  }

  private func finishRootTask(_ id: UUID) {
    rootTasks.removeValue(forKey: id)
  }

  private func isCurrent(_ expectedGeneration: UInt64) -> Bool {
    acceptsWork && !isResetting && generation == expectedGeneration
  }

  private func beginOperation() -> UInt64? {
    guard acceptsWork, !isResetting else { return nil }
    operationsInProgress += 1
    return generation
  }

  private func endOperation() {
    operationsInProgress = max(0, operationsInProgress - 1)
    guard operationsInProgress == 0 else { return }
    let waiters = operationDrainWaiters
    operationDrainWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  private func waitForOperationsToFinish() async {
    guard operationsInProgress > 0 else { return }
    await withCheckedContinuation { continuation in
      operationDrainWaiters.append(continuation)
    }
  }

  private func getBucketKey(for update: InlineProtocol.Update) -> BucketKey? {
    switch update.update {
      case let .newMessage(payload):
        .chat(peer: payload.message.peerID)
      case let .editMessage(payload):
        .chat(peer: payload.message.peerID)
      case let .deleteMessages(payload):
        .chat(peer: payload.peerID)
      case let .clearChatHistory_p(payload):
        switch payload.target {
          case let .peerID(peerID):
            .chat(peer: peerID)
          case let .spaceID(spaceID):
            .space(id: spaceID)
          case nil:
            nil
        }
      case let .messageAttachment(payload):
        .chat(peer: payload.peerID)
      case let .acknowledgement(payload):
        payload.hasPeerID ? .chat(peer: payload.peerID) : nil
      case let .updateReaction(payload):
        .chat(peer: .with { $0.chat = .with { $0.chatID = payload.reaction.chatID } })
      case let .deleteReaction(payload):
        .chat(peer: .with { $0.chat = .with { $0.chatID = payload.chatID } })
      case let .deleteChat(payload):
        .chat(peer: payload.peerID)
      case .markAsUnread:
        .user
      case let .spaceMemberAdd(payload):
        .space(id: payload.member.spaceID)
      case let .spaceMemberDelete(payload):
        .space(id: payload.spaceID)
      case let .spaceMemberUpdate(payload):
        .space(id: payload.member.spaceID)
      case .joinSpace:
        .user
      case .updateUserStatus, .updateUserSettings, .updatedUser, .dialogArchived,
           .dialogNotificationSettings, .dialogFolder, .userAddedToChat, .userRemovedFromChat:
        .user
      case let .newChat(payload):
        .chat(peer: payload.chat.peerID)
      case let .chatMoved(payload):
        .chat(peer: payload.chat.peerID)
      case let .participantAdd(payload):
        .chat(peer: .with { $0.chat = .with { $0.chatID = payload.chatID } })
      case let .participantDelete(payload):
        .chat(peer: .with { $0.chat = .with { $0.chatID = payload.chatID } })
      case let .participantGroupAdd(payload):
        .chat(peer: .with { $0.chat = .with { $0.chatID = payload.chatID } })
      case let .participantGroupDelete(payload):
        .chat(peer: .with { $0.chat = .with { $0.chatID = payload.chatID } })
      case let .chatVisibility(payload):
        .chat(peer: .with { $0.chat = .with { $0.chatID = payload.chatID } })
      case let .chatInfo(payload):
        .chat(peer: .with { $0.chat = .with { $0.chatID = payload.chatID } })
      case .chatPermissions:
        .user
      case .messageActionInvoked, .messageActionAnswered, .dialogFollowMode, .dialogCollapsedMaxID, .dialogTranslation:
        .user
      case let .spaceSettings(payload):
        .space(id: payload.spaceID)
      case let .pinnedMessages(payload):
        .chat(peer: payload.peerID)
      case .updateReadMaxID:
        .user
      case .chatOpen:
        .user
      default:
        nil
    }
  }

  private func publishSyncActivityIfNeeded() async {
    let isActive = !activeBucketActivityKeys.isEmpty ||
      isStateFetchInFlight ||
      isStateFetchPending ||
      activeDiscoveryRound != nil ||
      !pendingDiscoveryRounds.isEmpty ||
      !queuedDiscoveryTargets.isEmpty ||
      !bucketLoadRetries.isEmpty
    guard isActive != isSyncActivityActive else { return }
    isSyncActivityActive = isActive
    if let syncActivityListener {
      await syncActivityListener(isActive)
    }
  }

  private func requestSyncActivityRefresh() {
    Task { await self.publishSyncActivityIfNeeded() }
  }
}

// MARK: - FetchLimiter

/// A simple global concurrency limiter for async bucket fetch operations.
actor FetchLimiter {
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
  }

  private var limit: Int
  private var inFlight: Int = 0
  private var waiters: [Waiter] = []

  init(limit: Int) {
    self.limit = max(1, limit)
  }

  func setLimit(_ newLimit: Int) {
    limit = max(1, newLimit)
    resumeWaitersIfPossible()
  }

  func acquire() async -> Bool {
    if inFlight < limit {
      inFlight += 1
      return true
    }

    let id = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled {
          continuation.resume(returning: false)
          return
        }
        waiters.append(Waiter(id: id, continuation: continuation))
      }
    } onCancel: {
      Task { await self.cancelWaiter(id: id) }
    }
  }

  func release() {
    if inFlight > 0 {
      inFlight -= 1
    }
    resumeWaitersIfPossible()
  }

  func cancelAllWaiters() {
    let pending = waiters
    waiters.removeAll()
    for waiter in pending {
      waiter.continuation.resume(returning: false)
    }
  }

  private func cancelWaiter(id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: index)
    waiter.continuation.resume(returning: false)
  }

  private func resumeWaitersIfPossible() {
    while inFlight < limit, !waiters.isEmpty {
      inFlight += 1
      let waiter = waiters.removeFirst()
      waiter.continuation.resume(returning: true)
    }
  }
}

// MARK: - BucketActor

/// Actor responsible for fetching and applying updates for a single bucket (chat, space, or user).
actor BucketActor {
  private var log = Log.scoped("RealtimeV2.Sync.BucketActor")

  private static let updatesPageLimit: Int32 = 100
  private static let maxTotalUpdates: Int64 = 10_000
  private static let maxBufferedRealtimeUpdates = 4_096
  private static let maxBufferedRealtimeBytes = 16 * 1024 * 1024
  private static let maxReportedInvalidEnvelopeFingerprints = 16
  private static let getUpdatesTimeout: Duration = .seconds(30)

  // Strong ref for the same reason as Sync.client.
  private var client: ProtocolClientType?
  private weak var sync: Sync?
  private let fetchLimiter: FetchLimiter
  private let accountMutationToken: AuthAccountMutationToken?

  var key: BucketKey
  var seq: Int64
  var date: Int64
  private var fetchSeqEnd: Int64? = nil
  private var latestDemandGeneration: UInt64 = 0
  private var satisfiedLatestDemandGeneration: UInt64 = 0
  private var capturedLatestTarget: (generation: UInt64, seq: Int64)?

  private var hasLatestDemand: Bool {
    latestDemandGeneration > satisfiedLatestDemandGeneration
  }

  /// Prevents concurrent fetch operations
  private var isFetching: Bool = false
  private var isDrainingRealtime = false
  private var needsFetch: Bool = false

  private var retryTask: Task<Void, Never>?
  private var retryAttempt: Int = 0
  private var retryUsesRateLimitDelay = false
  private var reportedInvalidEnvelopeFingerprints: Set<String> = []
  private var reportedInvalidEnvelopeOverflow = false
  private var isInvalidated: Bool = false
  private var holdsActivityLease = false
  private var activeOperations = 0
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []
  private struct PendingUserRepair {
    let finalization: UserRepairFinalization
    var resolvedTargets: [BucketKey: UserRepairTargetResolution] = [:]
    var isFinalizing = false
  }
  private var pendingUserRepair: PendingUserRepair?
  private var needsUserProjectionRepair = false

  private struct BufferedRealtimeUpdate {
    let update: InlineProtocol.Update
    let bytes: Int
    let mutationToken: AuthAccountMutationToken?
  }

  /// Buffer for out-of-order realtime updates. We only apply contiguous seqs starting at (seq + 1).
  private var bufferedRealtimeUpdates: [Int64: BufferedRealtimeUpdate] = [:]
  private var bufferedRealtimeBytes = 0

  init(
    key: BucketKey,
    seq: Int64,
    date: Int64,
    client: ProtocolClientType?,
    sync: Sync?,
    fetchLimiter: FetchLimiter,
    accountMutationToken: AuthAccountMutationToken?
  ) {
    self.key = key
    self.seq = seq
    self.date = date
    self.client = client
    self.sync = sync
    self.fetchLimiter = fetchLimiter
    self.accountMutationToken = accountMutationToken
  }

  /// Advances an already-created actor when an authoritative account snapshot
  /// installs a newer resource cursor in GRDB.
  func installSnapshotState(_ state: BucketState) {
    guard !isInvalidated else { return }
    guard state.seq >= seq else { return }
    if state.seq > seq {
      seq = state.seq
      retainBufferedRealtimeUpdates(after: state.seq)
    }
    // The snapshot importer may refresh the date at an equal sequence. Keep
    // the actor's page-start CAS coordinate aligned with that durable state.
    date = max(date, state.date)
    if let fetchSeqEnd, state.seq >= fetchSeqEnd {
      self.fetchSeqEnd = nil
    }
  }

  /// Determines if an update should be processed based on its type during sync catch-up.
  ///
  /// We selectively apply only critical structure changes for now
  /// (membership, chat metadata, and other non-history state).
  private func shouldProcessUpdate(_ update: InlineProtocol.Update) -> Bool {
    switch update.update {
      case .acknowledgement:
        true
      case .participantAdd:
        true
      case .spaceMemberDelete:
        true
      case .participantDelete:
        true
      case .participantGroupAdd:
        true
      case .participantGroupDelete:
        true
      case .userAddedToChat, .userRemovedFromChat:
        true
      case .chatVisibility:
        true
      case .chatInfo:
        true
      case .chatPermissions:
        true
      case .deleteChat:
        true
      case .deleteMessages:
        true
      case .clearChatHistory_p:
        true
      case .spaceMemberUpdate:
        true
      case .spaceMemberAdd:
        true
      case .dialogArchived:
        true
      case .dialogNotificationSettings:
        true
      case .pinnedMessages:
        true
      case .markAsUnread:
        true
      case .updateReadMaxID:
        true
      case .newChat:
        true
      case .chatMoved:
        true
      case .joinSpace:
        true
      case .chatOpen:
        true
      case .messageActionInvoked, .messageActionAnswered:
        true
      case .dialogFollowMode, .dialogCollapsedMaxID, .dialogTranslation:
        true
      case .dialogFolder:
        true
      case .updatedUser:
        true
      case .spaceSettings:
        true
      case .newMessage, .editMessage, .messageAttachment:
        true
      case .updateReaction, .deleteReaction:
        true
      case .updateUserSettings:
        true
      case .chatSkipPts:
        true
      case nil:
        // SwiftProtobuf preserves fields that this client does not know, but an
        // older generated oneof has no typed case for them. The server page
        // envelope still accounts for the sequence, so accepting this as a
        // forward-compatible no-op lets older clients make progress. A known
        // constructor that lacks an owner continues to fail closed below.
        true
      default:
        // Only live-only/transient updates are excluded here. Every durable update
        // produced by GET_UPDATES must either be applied or be an explicit no-op in
        // UpdatesEngine before this bucket's cursor can advance.
        false
    }
  }

  /// Process sequenced updates coming directly from the realtime stream.
  ///
  /// We enforce strict seq order per bucket:
  /// - Apply only when the next expected seq is available.
  /// - Buffer out-of-order updates.
  /// - Trigger a catch-up fetch to fill gaps.
  func processRealtimeUpdates(
    _ updates: [InlineProtocol.Update],
    mutationToken: AuthAccountMutationToken? = nil
  ) async {
    guard !isInvalidated else { return }
    beginOperation()
    defer { endOperation() }

    // Buffer incoming updates
    for update in updates {
      guard update.hasSeq, update.seq > 0 else { continue }
      let incomingSeq = Int64(update.seq)
      // Skip duplicates/outdated updates.
      guard incomingSeq > seq else { continue }
      bufferRealtimeUpdate(
        update,
        at: incomingSeq,
        mutationToken: mutationToken ?? accountMutationToken
      )
    }

    let exceededRealtimeBufferLimit = bufferedRealtimeUpdates.count > Self.maxBufferedRealtimeUpdates ||
      bufferedRealtimeBytes > Self.maxBufferedRealtimeBytes
    if exceededRealtimeBufferLimit {
      let recoveryTarget = bufferedRealtimeUpdates.keys.max() ?? seq
      fetchSeqEnd = max(fetchSeqEnd ?? 0, recoveryTarget)
      let bufferedCount = bufferedRealtimeUpdates.count
      let bufferedBytes = bufferedRealtimeBytes
      clearBufferedRealtimeUpdates()
      needsFetch = true
      log.warning(
        "realtime update buffer limit exceeded for bucket type=\(key.traceKind); recovering through bounded catch-up"
      )
      PerformanceTrace.breadcrumb(
        "sync realtime buffer limit exceeded",
        category: "sync.realtime",
        level: .warning,
        data: [
          "bucket": key.traceKind,
          "buffered": bufferedCount,
          "buffered_bytes": bufferedBytes,
          "target_seq": recoveryTarget,
        ]
      )
      if let sync {
        await sync.recordRealtimeBufferRecovery()
      }
    }

    // Catch-up owns the cursor while it is fetching. Do not drain a same-bucket
    // live update between pages (or while the page is waiting on the limiter),
    // otherwise the live apply can overtake the page's expected start state.
    if isFetching || isDrainingRealtime || pendingUserRepair != nil || retryTask != nil {
      needsFetch = true
      log.trace("deferring realtime drain for bucket \(key) while catch-up owns unresolved work")
      if let sync {
        await sync.recordBucketFetchFollowup()
      }
      return
    }

    if exceededRealtimeBufferLimit {
      if isFetching {
        if let sync {
          await sync.recordBucketFetchFollowup()
        }
        return
      }
      await fetchNewUpdates()
      return
    }

    while true {
      // Updates appended while apply was suspended may already be contiguous.
      // Let the live owner drain that suffix locally; only an actual gap or an
      // explicit unresolved target needs a network catch-up request.
      guard !isFetching, !isDrainingRealtime, pendingUserRepair == nil else { return }
      guard await drainBufferedRealtimeUpdates() else { return }
      guard bufferedRealtimeUpdates[seq + 1] != nil else { break }
    }

    // If we still have buffered updates, we're missing at least one seq and must fetch history.
    guard !bufferedRealtimeUpdates.isEmpty || hasLatestDemand ||
      (fetchSeqEnd.map { $0 > seq } ?? false)
    else { return }

    if isFetching {
      needsFetch = true
      log.trace("realtime gap detected for bucket \(key), fetch already in progress; scheduling follow-up")
      if let sync {
        await sync.recordBucketFetchFollowup()
      }
      return
    }

    needsFetch = true
    Task { await self.fetchNewUpdates() }
  }

  /// Hint from the server about the latest seq for this bucket at the time it detected changes.
  ///
  /// We use this as an upper bound so catch-up fetches don't chase a moving target while the
  /// connection is live and new realtime updates keep arriving.
  func noteHasNewUpdates(upToSeq: Int64) -> Bool {
    guard !isInvalidated else { return false }

    // If the server didn't provide a meaningful seq, fetch anyway to be safe.
    guard upToSeq > 0 else {
      latestDemandGeneration &+= 1
      needsFetch = true
      return true
    }
    // Ignore stale hints.
    guard upToSeq > seq else { return false }
    fetchSeqEnd = max(fetchSeqEnd ?? 0, upToSeq)
    return true
  }

  /// Installs a frozen target even when it equals the current cursor. The
  /// equality case is used for the one post-capture user probe after fresh
  /// bootstrap; it must still issue a bounded request rather than an unbounded
  /// latest fetch.
  func setFetchTarget(upToSeq: Int64) {
    guard !isInvalidated, upToSeq > 0 else { return }
    fetchSeqEnd = max(fetchSeqEnd ?? 0, max(upToSeq, seq))
  }

  func noteHasNewUpdatesAndMaybeFetch(upToSeq: Int64) async {
    if noteHasNewUpdates(upToSeq: upToSeq) {
      await fetchNewUpdates()
    }
  }

  private func drainBufferedRealtimeUpdates() async -> Bool {
    guard !isInvalidated else { return true }
    guard !isDrainingRealtime else { return true }
    isDrainingRealtime = true
    defer { isDrainingRealtime = false }

    guard let sync else {
      log.error("sync reference is nil, cannot apply realtime updates")
      return false
    }

    guard !bufferedRealtimeUpdates.isEmpty else { return true }

    // Drop any buffered updates that are now behind our applied cursor.
    if bufferedRealtimeUpdates.count > 0 {
      retainBufferedRealtimeUpdates(after: seq)
    }

    var contiguousEntries: [BufferedRealtimeUpdate] = []
    var nextSeq = seq
    var nextDate = date

    // Drain a contiguous run starting at the next expected seq.
    while let next = bufferedRealtimeUpdates[nextSeq + 1] {
      contiguousEntries.append(next)
      nextSeq = Int64(next.update.seq)
      nextDate = next.update.date
    }

    guard !contiguousEntries.isEmpty else { return true }
    let contiguous = contiguousEntries.map(\.update)
    let mutationToken = contiguousEntries.first?.mutationToken ?? accountMutationToken
    guard contiguousEntries.allSatisfy({ ($0.mutationToken ?? accountMutationToken) == mutationToken }) else {
      log.warning("mixed account generations in realtime bucket buffer; deferring to catch-up")
      needsFetch = true
      return false
    }

    log.debug("applying \(contiguous.count) realtime updates for bucket \(key) (new seq=\(nextSeq))")
    let span = PerformanceTrace.begin(
      "SyncRealtimeDrain",
      category: .sync,
      "bucket=\(key.traceKind) updates=\(contiguous.count) start_seq=\(seq) end_seq=\(nextSeq)"
    )
    let startedAt = Date()
    // Capture the actor cursor immediately before entering the apply owner so
    // its CAS rejects a concurrent state change. This mirrors the per-page
    // catch-up commit contract.
    let expectedStartState = BucketState(date: date, seq: seq)
    let targetState = BucketState(date: nextDate, seq: nextSeq)
    let result = await sync.applyUpdatesFromRealtime(
      contiguous,
      bucketCommit: UpdateBucketCommit(
        key: key,
        state: targetState,
        expectedStartState: expectedStartState
      ),
      mutationToken: mutationToken
    )
    let durationMs = PerformanceTrace.elapsedMilliseconds(since: startedAt)
    span.end(
      "bucket=\(key.traceKind) updates=\(contiguous.count) applied=\(result.appliedCount) failed=\(result.failedCount) duration_ms=\(durationMs)"
    )
    PerformanceTrace.slowBreadcrumb(
      "slow realtime drain apply",
      category: "sync.realtime",
      durationMs: durationMs,
      thresholdMs: 500,
      data: [
        "bucket": key.traceKind,
        "updates": contiguous.count,
        "applied": result.appliedCount,
        "failed": result.failedCount,
      ]
    )
    guard result.succeeded else {
      PerformanceTrace.breadcrumb(
        "realtime drain apply failed",
        category: "sync.realtime",
        level: .warning,
        data: [
          "bucket": key.traceKind,
          "updates": contiguous.count,
          "applied": result.appliedCount,
          "failed": result.failedCount,
        ]
      )
      log.error(
        "failed to apply \(result.failedCount) realtime updates for bucket \(key); keeping seq=\(seq) and scheduling catch-up"
      )
      needsFetch = true
      // A catch-up owner draining its completed target's live suffix handles
      // this failure through its retained retry, not an immediate second fetch.
      if !isFetching {
        Task { await self.fetchNewUpdates() }
      }
      return false
    }
    let saved: BucketState?
    if let committed = result.committedBucketState {
      saved = committed
    } else {
      saved = await sync.saveBucketState(for: key, seq: nextSeq, date: nextDate)
    }
    guard let saved else {
      PerformanceTrace.breadcrumb(
        "realtime drain bucket state save failed",
        category: "sync.realtime",
        level: .warning,
        data: [
          "bucket": key.traceKind,
          "seq": nextSeq,
        ]
      )
      needsFetch = true
      return false
    }

    for update in contiguous where update.hasSeq {
      removeBufferedRealtimeUpdate(at: Int64(update.seq))
    }

    if saved.seq >= seq {
      seq = saved.seq
      date = max(date, saved.date)
    }
    retainBufferedRealtimeUpdates(after: seq)
    if let fetchSeqEnd, seq >= fetchSeqEnd {
      self.fetchSeqEnd = nil
    }
    await sync.bucketDidAdvance(key: key, state: BucketState(date: date, seq: seq))
    return true
  }

  func fetchNewUpdates() async {
    guard !isInvalidated else { return }

    // Guard against concurrent fetch operations
    if isFetching || isDrainingRealtime {
      needsFetch = true
      log.trace("fetch already in progress for bucket \(key), scheduling follow-up")
      if let sync {
        await sync.recordBucketFetchFollowup()
      }
      return
    }
    // A pending account repair owns the user cursor until its exact child
    // targets finalize. Do not start a competing user catch-up pass meanwhile.
    if pendingUserRepair != nil {
      needsFetch = true
      return
    }

    beginOperation()
    defer { endOperation() }

    isFetching = true
    defer {
      isFetching = false
    }

    guard let sync else {
      log.error("sync reference is nil, cannot fetch updates")
      return
    }
    if !holdsActivityLease {
      holdsActivityLease = true
      await sync.bucketFetchActivityStarted(for: key)
    }

    let fetchStartedAt = Date()
    let fetchSpan = PerformanceTrace.begin(
      "SyncBucketFetch",
      category: .sync,
      "bucket=\(key.traceKind) start_seq=\(seq) target_seq=\(fetchSeqEnd ?? 0)"
    )
    var completed = false
    defer {
      let durationMs = PerformanceTrace.elapsedMilliseconds(since: fetchStartedAt)
      fetchSpan.end(
        "bucket=\(key.traceKind) success=\(completed) duration_ms=\(durationMs) end_seq=\(seq) buffered=\(bufferedRealtimeUpdates.count)"
      )
      PerformanceTrace.slowBreadcrumb(
        "slow sync bucket fetch",
        category: "sync.catchup",
        durationMs: durationMs,
        thresholdMs: 1_500,
        data: [
          "bucket": key.traceKind,
          "success": completed,
          "buffered": bufferedRealtimeUpdates.count,
        ]
      )
    }
    PerformanceTrace.breadcrumb(
      "sync bucket fetch started",
      category: "sync.catchup",
      data: [
        "bucket": key.traceKind,
      ]
    )

    // If we had a scheduled retry, cancel it since we're actively attempting a fetch now.
    retryTask?.cancel()
    retryTask = nil

    var finishedWithoutRetry = true
    var scheduleBackgroundFollowUp = false
    while true {
      needsFetch = false
      let ok = await fetchNewUpdatesOnce()
      guard !isInvalidated else { break }
      if ok {
        if retryTask == nil {
          resetRetryState()
        } else {
          // A child finalization CAS may have scheduled a delayed recovery
          // while this user pass was awaiting the exact target. Preserve that
          // retry instead of turning it into an immediate follow-up loop.
          finishedWithoutRetry = false
          break
        }
      } else {
        finishedWithoutRetry = false
        scheduleRetry()
        break
      }

      guard pendingUserRepair == nil else { break }
      // Only a complete successful pass releases its contiguous live suffix.
      // Keep the existing fetch owner while applying it so live side effects
      // survive without allowing a drain between catch-up pages.
      while !isInvalidated, pendingUserRepair == nil, bufferedRealtimeUpdates[seq + 1] != nil {
        guard await drainBufferedRealtimeUpdates() else {
          finishedWithoutRetry = false
          scheduleRetry()
          break
        }
      }
      guard finishedWithoutRetry, !isInvalidated, pendingUserRepair == nil else { break }
      let hasOutstandingFetchTarget = fetchSeqEnd.map { $0 > seq } ?? false
      // Successful application consumes redundant wake flags. Every remaining
      // demand is represented by a target or buffered gap, including latest.
      needsFetch = false
      guard !bufferedRealtimeUpdates.isEmpty || hasOutstandingFetchTarget || hasLatestDemand else { break }
      // A higher target or buffered gap is a separate pass. The target itself
      // stays frozen for this invocation; there are no client-created sequence
      // tranches or synthetic checkpoints.
      scheduleBackgroundFollowUp = true
      log.trace("background follow-up fetch requested for bucket \(key)")
      break
    }

    completed = finishedWithoutRetry
    if completed {
      PerformanceTrace.breadcrumb(
        "sync bucket fetch completed",
        category: "sync.catchup",
        data: [
          "bucket": key.traceKind,
          "duration_ms": PerformanceTrace.elapsedMilliseconds(since: fetchStartedAt),
          "seq": seq,
        ]
      )
    } else {
      PerformanceTrace.breadcrumb(
        "sync bucket fetch scheduled retry",
        category: "sync.catchup",
        level: .warning,
        data: [
          "bucket": key.traceKind,
          "duration_ms": PerformanceTrace.elapsedMilliseconds(since: fetchStartedAt),
        ]
      )
    }
    if scheduleBackgroundFollowUp, !isInvalidated {
      Task { await self.fetchNewUpdates() }
    }

    // Keep the keyed lease through retry sleep, authoritative repair, and any
    // higher-target follow-up. It ends only once this bucket has no unresolved
    // target or buffered gap (or has been retired as inaccessible).
    let hasOutstandingFetchTarget = fetchSeqEnd.map { $0 > seq } ?? false
    let remainsActive = !isInvalidated && (
      pendingUserRepair != nil ||
      needsFetch ||
      !bufferedRealtimeUpdates.isEmpty ||
      hasOutstandingFetchTarget ||
      hasLatestDemand ||
      retryTask != nil ||
      scheduleBackgroundFollowUp
    )
    if !remainsActive, holdsActivityLease {
      holdsActivityLease = false
      await sync.bucketFetchActivityEnded(for: key)
      // The inactive listener is an actor suspension point. A new hint can
      // arrive there while this owner is still marked fetching; that caller
      // coalesces into us, so we must hand it to a successor before returning.
      if !isInvalidated, retryTask == nil, pendingUserRepair == nil,
         needsFetch || !bufferedRealtimeUpdates.isEmpty || hasLatestDemand ||
         (fetchSeqEnd.map { $0 > seq } ?? false) {
        Task { await self.fetchNewUpdates() }
      }
    }
  }

  /// Fetches one frozen target and commits each validated page independently.
  /// The page start state is part of the apply-owner CAS, so a same-bucket live
  /// update cannot race a page between its read and cursor commit.
  private func fetchNewUpdatesOnce() async -> Bool {
    retryUsesRateLimitDelay = false
    guard let client else {
      log.error("client is nil, cannot fetch updates")
      return false
    }
    guard let sync else {
      log.error("sync reference is nil, cannot persist state")
      return false
    }

    await sync.recordBucketFetchStart()
    let startedAt = Date()
    let span = PerformanceTrace.begin(
      "SyncBucketFetchOnce",
      category: .sync,
      "bucket=\(key.traceKind) start_seq=\(seq)"
    )
    var pageCount = 0
    var resultLabel = "unknown"
    defer {
      span.end(
        "bucket=\(key.traceKind) result=\(resultLabel) pages=\(pageCount) duration_ms=\(PerformanceTrace.elapsedMilliseconds(since: startedAt))"
      )
    }

    var currentSeq = seq

    do {
      let expectedUserStateForMissingChild: BucketState?
      if key != .user, currentSeq == 0 {
        expectedUserStateForMissingChild = try await sync.userStateForMissingChildAdmission()
      } else {
        expectedUserStateForMissingChild = nil
      }
      if needsUserProjectionRepair {
        guard let outcome = await sync.repairUserBucket(
          targetState: BucketState(date: date, seq: seq),
          reason: "repair_child_access_changed",
          requiresProjectionAudit: true
        ) else { return false }
        needsUserProjectionRepair = false
        return await applyUserRepairOutcome(outcome) != nil
      }
      // GET_UPDATES only returns each page's end, not the snapshot high-water.
      // Capture that coordinate once for a latest demand, without importing or
      // advancing the metadata response. Every subsequent page is bounded.
      var requestedEndSeq = fetchSeqEnd
      if let bufferedEnd = bufferedRealtimeUpdates.keys.max() {
        requestedEndSeq = max(requestedEndSeq ?? 0, bufferedEnd)
      }
      if requestedEndSeq == nil, !hasLatestDemand {
        latestDemandGeneration &+= 1
      }
      let passLatestGeneration = hasLatestDemand ? latestDemandGeneration : nil
      if let passLatestGeneration {
        if capturedLatestTarget?.generation != passLatestGeneration {
          guard let target = try await captureLatestSequence(client: client),
                !isInvalidated, !Task.isCancelled
          else {
            resultLabel = "latest_target_unavailable"
            return false
          }
          capturedLatestTarget = (passLatestGeneration, target)
        }
        if let target = capturedLatestTarget?.seq {
          requestedEndSeq = max(requestedEndSeq ?? 0, target)
        }
      }
      guard let hardEndSeq = requestedEndSeq else {
        resultLabel = "missing_fixed_target"
        return false
      }
      if passLatestGeneration != nil, currentSeq >= hardEndSeq {
        completeLatestDemand(passLatestGeneration)
        await sync.bucketDidAdvance(
          key: key,
          state: BucketState(date: date, seq: seq),
          authoritative: !hasLatestDemand
        )
        resultLabel = "latest_already_durable"
        return true
      }
      while true {
        let pageStartState = BucketState(date: date, seq: currentSeq)
        let queueStartedAt = Date()
        let queueSpan = PerformanceTrace.begin(
          "SyncBucketQueueWait",
          category: .sync,
          "bucket=\(key.traceKind)"
        )
        guard await fetchLimiter.acquire() else {
          resultLabel = "cancelled"
          return true
        }
        queueSpan.end(
          "bucket=\(key.traceKind) duration_ms=\(PerformanceTrace.elapsedMilliseconds(since: queueStartedAt))"
        )

        let rpcStartedAt = Date()
        let rpcSpan = PerformanceTrace.begin(
          "SyncBucketRPC",
          category: .sync,
          "bucket=\(key.traceKind) start_seq=\(currentSeq) seq_end=\(hardEndSeq)"
        )
        let result: InlineProtocol.RpcResult.OneOf_Result?
        do {
          result = try await client.callRpc(method: .getUpdates, input: .getUpdates(.with {
            $0.bucket = key.toProtocolBucket()
            $0.startSeq = currentSeq
            $0.totalLimit = Int32(Self.maxTotalUpdates)
            $0.limit = Self.updatesPageLimit
            $0.seqEnd = hardEndSeq
          }), timeout: Self.getUpdatesTimeout)
          rpcSpan.end(
            "bucket=\(key.traceKind) success=true duration_ms=\(PerformanceTrace.elapsedMilliseconds(since: rpcStartedAt))"
          )
        } catch {
          rpcSpan.end(
            "bucket=\(key.traceKind) success=false duration_ms=\(PerformanceTrace.elapsedMilliseconds(since: rpcStartedAt))"
          )
          await fetchLimiter.release()
          throw error
        }
        await fetchLimiter.release()
        guard !isInvalidated, !Task.isCancelled else {
          resultLabel = "cancelled"
          return true
        }
        pageCount += 1

        guard case let .getUpdates(payload) = result else {
          resultLabel = "parse_failed"
          return false
        }
        if seq != pageStartState.seq || date != pageStartState.date {
          // A catalog seed or another admitted repair superseded this page
          // while its RPC was in flight. Never replay it against that newer
          // cursor; the next pass considers only still-unresolved targets.
          if seq >= hardEndSeq {
            completeLatestDemand(passLatestGeneration)
            await sync.bucketDidAdvance(
              key: key,
              state: BucketState(date: date, seq: seq),
              authoritative: passLatestGeneration != nil && !hasLatestDemand
            )
          }
          resultLabel = "superseded_page"
          return true
        }

        // A server response cannot widen this invocation's target. This is a
        // protocol failure and is retried from the committed page cursor.
        guard payload.seq <= hardEndSeq else {
          log.error(
            "getUpdates page exceeded frozen target for bucket \(key): target=\(hardEndSeq), page=\(payload.seq)"
          )
          resultLabel = "page_beyond_target"
          return false
        }

        if payload.resultType == .tooLong {
          await sync.recordBucketFetchTooLong()
          let serverSeq = Int64(payload.seq)
          guard serverSeq > currentSeq, payload.date > 0 else {
            resultLabel = "too_long_invalid_seq"
            return false
          }
          // TOO_LONG is the server's explicit snapshot boundary. It is the one
          // page condition that immediately enters scoped authoritative repair.
          if await repairAuthoritativeSnapshotIfNeeded(
            targetSeq: serverSeq,
            targetDate: payload.date,
            reason: "too_long",
            replacesUserCatalog: key == .user,
            latestDemand: passLatestGeneration
          ) {
            resultLabel = "repaired_too_long"
            return true
          }
          resultLabel = "too_long_repair_failed"
          return false
        }

        guard let requiresSnapshotRepair = validatePageEnvelope(
          payload,
          startSeq: currentSeq,
          targetSeq: hardEndSeq
        ) else {
          let fingerprint = invalidEnvelopeFingerprint(
            payload,
            startSeq: currentSeq,
            targetSeq: hardEndSeq
          )
          // A malformed lossless page is a server/protocol defect, not evidence
          // that journal history expired. Keep the cursor and exact target;
          // only an explicit server classification may enter snapshot repair.
          reportInvalidEnvelopeOnce(fingerprint)
          resultLabel = "invalid_page_envelope"
          return false
        }

        // A declared-final page below a trusted target contradicts the
        // response contract. Reject it before sidecars, rows, or the cursor
        // date are committed; valid non-final pages still commit individually.
        guard !payload.final || payload.seq >= hardEndSeq else {
          reportInvalidEnvelopeOnce(invalidEnvelopeFingerprint(
            payload,
            startSeq: currentSeq,
            targetSeq: hardEndSeq
          ))
          resultLabel = "target_not_reached"
          return false
        }

        if requiresSnapshotRepair {
          if await repairAuthoritativeSnapshotIfNeeded(
            targetSeq: payload.seq,
            targetDate: payload.date,
            reason: "server_classified_gap",
            latestDemand: passLatestGeneration
          ) {
            resultLabel = "repaired_server_classified_gap"
            return true
          }
          resultLabel = "snapshot_repair_failed"
          return false
        }

        guard payload.seq >= currentSeq else {
          resultLabel = "server_behind"
          return false
        }
        guard payload.final || payload.seq > currentSeq else {
          reportInvalidEnvelopeOnce(invalidEnvelopeFingerprint(
            payload,
            startSeq: currentSeq,
            targetSeq: hardEndSeq
          ))
          resultLabel = "non_progress"
          return false
        }

        var duplicateSkipped = 0
        let filteredUpdates = payload.updates.filter { update in
          if update.hasSeq, update.seq <= self.seq {
            duplicateSkipped += 1
            return false
          }
          guard shouldProcessUpdate(update) else {
            log.error("unsupported update in bucket catch-up; refusing to advance cursor")
            return false
          }
          return true
        }
        guard filteredUpdates.count == payload.updates.count - duplicateSkipped else {
          resultLabel = "unsupported_update"
          return false
        }

        // Envelope validation accounts for every covered sequence as a fetched
        // update or an authoritative skip. Do not refill a skip from the live
        // buffer: it may be an old grant the server has since revoked.
        let orderedUpdates = orderUpdatesBySeq(filteredUpdates)
        let pageEndState = BucketState(
          date: max(date, max(payload.date, maxUpdateDate(in: orderedUpdates))),
          seq: payload.seq
        )
        let pageCommit = UpdateBucketCommit(
          key: key,
          state: pageEndState,
          expectedStartState: pageStartState,
          expectedUserStateForMissingChild: expectedUserStateForMissingChild
        )
        let applyStartedAt = Date()
        let applySpan = PerformanceTrace.begin(
          "SyncBucketApply",
          category: .sync,
          "bucket=\(key.traceKind) updates=\(orderedUpdates.count) sidecars=\(payload.hasSidecars)"
        )
        let applyResult = await sync.applyUpdatesFromBucket(
          orderedUpdates,
          sidecars: payload.hasSidecars ? payload.sidecars : nil,
          bucketCommit: pageCommit,
          mutationToken: accountMutationToken
        )
        applySpan.end(
          "bucket=\(key.traceKind) updates=\(orderedUpdates.count) applied=\(applyResult.appliedCount) failed=\(applyResult.failedCount) duration_ms=\(PerformanceTrace.elapsedMilliseconds(since: applyStartedAt))"
        )
        guard applyResult.succeeded else {
          await sync.recordBucketUpdatesApplied(
            applied: applyResult.appliedCount,
            skipped: max(0, payload.updates.count - filteredUpdates.count) + applyResult.failedCount,
            duplicates: duplicateSkipped
          )
          resultLabel = "apply_failed"
          return false
        }

        let saved: BucketState?
        if let committed = applyResult.committedBucketState {
          saved = committed
        } else {
          saved = await sync.saveBucketState(
            for: key,
            seq: pageEndState.seq,
            date: pageEndState.date
          )
        }
        guard let saved else {
          resultLabel = "state_save_failed"
          return false
        }
        guard saved.seq >= seq else {
          // The apply committed before an admitted snapshot, but its result
          // returned afterwards. Keep the newer actor coordinate installed by
          // that snapshot; never regress it to this old page result.
          resultLabel = "superseded_commit"
          return true
        }
        seq = saved.seq
        date = saved.date
        currentSeq = saved.seq
        // A committed page is real progress even if a later page fails. Do not
        // carry an old slow-tier penalty past this durable boundary.
        if saved.seq > pageStartState.seq { resetRetryState() }
        retainBufferedRealtimeUpdates(after: saved.seq)
        await sync.recordBucketUpdatesApplied(
          applied: filteredUpdates.count,
          skipped: max(0, payload.updates.count - filteredUpdates.count - duplicateSkipped),
          duplicates: duplicateSkipped
        )
        let completedTarget = payload.final && saved.seq >= hardEndSeq
        if completedTarget { completeLatestDemand(passLatestGeneration) }
        let authoritativeCompletion = completedTarget && passLatestGeneration != nil && !hasLatestDemand
        await sync.bucketDidAdvance(
          key: key,
          state: saved,
          authoritative: authoritativeCompletion
        )

        if payload.final {
          if let fetchSeqEnd, saved.seq >= fetchSeqEnd {
            self.fetchSeqEnd = nil
          }
          resultLabel = "success"
          return true
        }
      }
    } catch {
      if isNonRetryableBucketError(error) {
        log.warning("non-retryable getUpdates error for bucket \(key): \(error)")
        isInvalidated = true
        clearBufferedRealtimeUpdates()
        needsFetch = false
        fetchSeqEnd = nil
        // Preserve the durable cursor/cache while resolving the exact
        // discovery dependency that can no longer be fetched.
        await sync.resolveInaccessibleBucket(key: key)
        await sync.discardBucketState(for: key)
        resultLabel = "non_retryable_error"
        return true
      }
      if isRateLimitError(error) {
        // A server rate-limit is the sole signal for the slow retry lane.
        retryUsesRateLimitDelay = true
      }
      await sync.recordBucketFetchFailure()
      resultLabel = "error"
      return false
    }
  }

  private func captureLatestSequence(client: ProtocolClientType) async throws -> Int64? {
    guard await fetchLimiter.acquire() else { return nil }
    let result: InlineProtocol.RpcResult.OneOf_Result?
    do {
      switch key {
        case let .chat(peer):
          result = try await client.callRpc(
            method: .getChat,
            input: .getChat(.with { $0.peerID = peer.toInputPeer() }),
            timeout: Self.getUpdatesTimeout
          )
        case let .space(id):
          result = try await client.callRpc(
            method: .getSpace,
            input: .getSpace(.with { $0.spaceID = id }),
            timeout: Self.getUpdatesTimeout
          )
        case .user:
          result = try await client.callRpc(
            method: .getUpdatesState,
            input: .getUpdatesState(.init()),
            timeout: Self.getUpdatesTimeout
          )
      }
    } catch {
      await fetchLimiter.release()
      throw error
    }
    await fetchLimiter.release()
    switch (key, result) {
      case let (.chat(peer), .getChat(payload))
        where payload.hasChat && payload.chat.peerID == peer && payload.chat.hasSeq && payload.chat.seq >= 0:
        return Int64(payload.chat.seq)
      case let (.space(id), .getSpace(payload))
        where payload.hasSpace && payload.space.id == id && payload.space.hasSeq && payload.space.seq >= 0:
        return Int64(payload.space.seq)
      case let (.user, .getUpdatesState(payload)) where payload.hasSeq && payload.seq >= 0:
        return Int64(payload.seq)
      default:
        // Older or malformed servers cannot provide a safe bound. Keep the
        // demand in the retry owner; do not silently sweep or chase live pages.
        return nil
    }
  }

  private func completeLatestDemand(_ demand: UInt64?) {
    guard let demand else { return }
    satisfiedLatestDemandGeneration = max(satisfiedLatestDemandGeneration, demand)
    if capturedLatestTarget?.generation == demand { capturedLatestTarget = nil }
  }

  private func isNonRetryableBucketError(_ error: Error) -> Bool {
    guard case let ProtocolSessionError.rpcError(errorCode, _, _) = error else {
      return false
    }

    return switch errorCode {
    case .peerIDInvalid, .chatIDInvalid, .spaceIDInvalid:
      true
    default:
      false
    }
  }

  private func isRateLimitError(_ error: Error) -> Bool {
    guard case let ProtocolSessionError.rpcError(errorCode, _, code) = error else {
      return false
    }
    return errorCode == .rateLimit || code == 429
  }

  private func resetRetryState() {
    retryAttempt = 0
    retryUsesRateLimitDelay = false
    reportedInvalidEnvelopeFingerprints.removeAll(keepingCapacity: true)
    reportedInvalidEnvelopeOverflow = false
    retryTask?.cancel()
    retryTask = nil
  }

  private func scheduleRetry() {
    // Avoid scheduling multiple concurrent retries.
    guard retryTask == nil, !isInvalidated else { return }

    needsFetch = true
    let delay = SyncRetryPolicy.delay(
      attempt: retryAttempt,
      rateLimited: retryUsesRateLimitDelay
    )
    retryAttempt += 1

    log.warning("scheduling retry for bucket \(key) in \(delay)")
    retryTask = Task {
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      self.clearRetryTask()
      await self.fetchNewUpdates()
    }
  }

  private func clearRetryTask() {
    retryTask = nil
  }

  /// An accepted reconnect/open edge is an explicit retry wake. Cancel only
  /// this actor's delayed owner; the caller then runs its normal fetch path,
  /// preserving the one-owner invariant and the committed cursor.
  func wakeRetryIfNeeded() -> Bool {
    guard !isInvalidated, retryTask != nil else { return false }
    retryTask?.cancel()
    // Keep the canceled owner's handle until fetchNewUpdates takes over. A
    // live event in that handoff must not bypass the failed authoritative page.
    needsFetch = true
    return true
  }

  func invalidate() async {
    guard !isInvalidated else { return }
    isInvalidated = true
    let scheduledRetry = retryTask
    retryTask = nil
    scheduledRetry?.cancel()
    await scheduledRetry?.value
    needsFetch = false
    fetchSeqEnd = nil
    capturedLatestTarget = nil
    satisfiedLatestDemandGeneration = latestDemandGeneration
    pendingUserRepair = nil
    clearBufferedRealtimeUpdates()
    if holdsActivityLease, let sync {
      holdsActivityLease = false
      await sync.bucketFetchActivityEnded(for: key)
    }
    client = nil
  }

  func waitUntilIdle() async {
    guard activeOperations > 0 else { return }
    await withCheckedContinuation { continuation in
      idleWaiters.append(continuation)
    }
  }

  private func beginOperation() {
    activeOperations += 1
  }

  private func endOperation() {
    activeOperations = max(0, activeOperations - 1)
    guard activeOperations == 0 else { return }
    let waiters = idleWaiters
    idleWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  private func repairChatSnapshotIfNeeded(
    targetSeq: Int64,
    targetDate: Int64,
    reason: String
  ) async -> Bool {
    guard case let .chat(peer) = key, let sync else { return false }
    guard targetSeq > seq else { return false }

    let targetState = BucketState(date: max(date, targetDate), seq: targetSeq)
    guard let saved = await sync.repairChatBucket(
      peer: peer,
      targetState: targetState,
      reason: reason
    ) else { return false }
    seq = saved.seq
    date = saved.date
    retainBufferedRealtimeUpdates(after: saved.seq)
    if let fetchSeqEnd, saved.seq >= fetchSeqEnd {
      self.fetchSeqEnd = nil
    }
    await sync.bucketDidAdvance(key: key, state: saved, authoritative: true)
    return true
  }

  func resolvePendingUserRepairTarget(
    key targetKey: BucketKey,
    state: BucketState,
    authoritative: Bool
  ) async {
    guard !isInvalidated, var pending = pendingUserRepair,
          !pending.isFinalizing,
          let targetSequence = pending.finalization.catchUpTargets[targetKey]
    else { return }
    let satisfied = targetSequence == 0
      ? authoritative
      : state.seq >= targetSequence
    guard satisfied else { return }
    pending.resolvedTargets[targetKey] = UserRepairTargetResolution(
      state: state,
      authoritative: authoritative
    )
    guard pending.resolvedTargets.count == pending.finalization.catchUpTargets.count,
          let sync
    else {
      pendingUserRepair = pending
      return
    }
    pending.isFinalizing = true
    pendingUserRepair = pending
    guard let saved = await sync.finalizeUserRepair(
      pending.finalization,
      resolvedTargets: pending.resolvedTargets
    ) else {
      // The finalization CAS may lose to another account writer. Do not leave
      // the actor permanently blocked behind a pending outcome: preserve the
      // exact child dependencies, retain the old cursor, and enter the normal
      // delayed retry path while the activity lease stays held.
      pendingUserRepair = nil
      needsFetch = true
      setFetchTarget(upToSeq: pending.finalization.proposedUserState.seq)
      scheduleRetry()
      log.warning("user repair finalization was not accepted; retaining old cursor")
      return
    }
    guard !isInvalidated else { return }
    pendingUserRepair = nil
    _ = await commitUserRepairState(
      saved,
      replayThroughState: pending.finalization.replayThroughState,
      sync: sync
    )
  }

  func pendingUserRepairTargetBecameInaccessible(key: BucketKey) async {
    guard !isInvalidated, let pending = pendingUserRepair,
          pending.finalization.catchUpTargets[key] != nil
    else { return }
    // Terminal access is not proof of the old sequence. Re-admit the account
    // projection, which can omit this child, while retaining the old user
    // cursor and all cached child data until that repair is accepted.
    pendingUserRepair = nil
    needsUserProjectionRepair = true
    needsFetch = true
    scheduleRetry()
  }

  /// Installs an account repair outcome while this actor still owns the user
  /// cursor. Returned child seeds/demands are registered before the actor is
  /// allowed to satisfy its discovery dependency; no bucket sweep is implied.
  func applyUserRepairOutcome(_ outcome: UserRepairOutcome) async -> BucketState? {
    guard !isInvalidated, let sync else { return nil }
    switch outcome {
      case let .applied(state, seededStates, replayThroughState, retiredBucketKeys):
        await sync.retireCatalogBucketActors(retiredBucketKeys)
        await sync.installSnapshotBucketStates(seededStates)
        pendingUserRepair = nil
        return await commitUserRepairState(
          state,
          replayThroughState: replayThroughState,
          sync: sync
        )
      case let .pending(finalization, seededStates):
        await sync.retireCatalogBucketActors(finalization.retiredBucketKeys)
        await sync.installSnapshotBucketStates(seededStates)
        pendingUserRepair = PendingUserRepair(finalization: finalization)
        // Register all exact child demands before the user cursor advances. A
        // zero target means latest and must be resolved by an authoritative
        // final page, not by the actor's current sequence.
        await sync.registerUserRepairTargets(finalization.catchUpTargets)
        await sync.registerUserRepairFinalizationTarget(finalization.proposedUserState.seq)
        if !holdsActivityLease {
          holdsActivityLease = true
          await sync.bucketFetchActivityStarted(for: key)
        }
        await sync.launchUserRepairTargets(finalization.catchUpTargets)
        // Keep the old cursor visible until every child is durable and the
        // apply owner accepts the exact finalization CAS.
        return BucketState(date: date, seq: seq)
      case let .superseded(currentState, replayThroughState):
        // Another repair already committed this checkpoint. It has no child
        // seeds or target demands for this invocation to apply.
        pendingUserRepair = nil
        return await commitUserRepairState(
          currentState,
          replayThroughState: replayThroughState,
          sync: sync
        )
    }
  }

  private func commitUserRepairState(
    _ saved: BucketState,
    replayThroughState: BucketState? = nil,
    sync: Sync
  ) async -> BucketState? {
    let retainedNewerActorState = saved.seq < seq
    if retainedNewerActorState {
      // The durable owner may have observed a newer realtime cursor while the
      // repair was in flight. Keep the actor at that newer state; treating the
      // owner response as a failure would discard a valid supersession.
      log.warning("user repair returned a cursor behind the actor: current=\(seq) returned=\(saved.seq)")
    } else {
      seq = saved.seq
      date = max(date, saved.date)
    }
    let admittedState = BucketState(date: date, seq: seq)
    retainBufferedRealtimeUpdates(after: admittedState.seq)
    if let fetchSeqEnd, admittedState.seq >= fetchSeqEnd { self.fetchSeqEnd = nil }
    if let replayThroughState, replayThroughState.seq > seq {
      setFetchTarget(upToSeq: replayThroughState.seq)
      needsFetch = true
    }
    await sync.bucketDidAdvance(
      key: key,
      state: admittedState,
      authoritative: !retainedNewerActorState
    )
    if !isFetching, needsFetch || !bufferedRealtimeUpdates.isEmpty || fetchSeqEnd != nil {
      Task { await self.fetchNewUpdates() }
    }
    if holdsActivityLease,
       !isFetching,
       retryTask == nil,
       fetchSeqEnd == nil,
       bufferedRealtimeUpdates.isEmpty,
       !needsFetch
    {
      holdsActivityLease = false
      await sync.bucketFetchActivityEnded(for: key)
    }
    return admittedState
  }

  private func repairAuthoritativeSnapshotIfNeeded(
    targetSeq: Int64,
    targetDate: Int64,
    reason: String,
    replacesUserCatalog: Bool = false,
    latestDemand: UInt64? = nil
  ) async -> Bool {
    guard targetSeq > seq, let sync else { return false }
    let targetState = BucketState(date: max(date, targetDate), seq: targetSeq)
    switch key {
      case let .chat(peer):
        guard let saved = await sync.repairChatBucket(
          peer: peer,
          targetState: targetState,
          reason: reason
        ) else { return false }
        seq = saved.seq
        date = saved.date
        retainBufferedRealtimeUpdates(after: saved.seq)
        if let fetchSeqEnd, saved.seq >= fetchSeqEnd { self.fetchSeqEnd = nil }
        completeLatestDemand(latestDemand)
        await sync.bucketDidAdvance(key: key, state: saved, authoritative: !hasLatestDemand)
        return true
      case let .space(id):
        guard let saved = await sync.repairSpaceBucket(
          spaceID: id,
          targetState: targetState,
          reason: reason
        ) else { return false }
        seq = saved.seq
        date = saved.date
        retainBufferedRealtimeUpdates(after: saved.seq)
        if let fetchSeqEnd, saved.seq >= fetchSeqEnd { self.fetchSeqEnd = nil }
        completeLatestDemand(latestDemand)
        await sync.bucketDidAdvance(key: key, state: saved, authoritative: !hasLatestDemand)
        return true
      case .user:
        guard let outcome = await sync.repairUserBucket(
          targetState: targetState,
          reason: reason,
          replacesActiveCatalog: replacesUserCatalog
        ) else { return false }
        return await applyUserRepairOutcome(outcome) != nil
    }
  }

  /// Validates that a lossless page accounts for every sequence it advances.
  /// Returns whether the server requires an authoritative snapshot repair.
  private func invalidEnvelopeFingerprint(
    _ payload: InlineProtocol.GetUpdatesResult,
    startSeq: Int64,
    targetSeq: Int64?
  ) -> String {
    // Keep this deliberately content-free: the fingerprint describes only the
    // accounting shape, so malformed message data cannot create high-cardinality
    // telemetry or accidentally become part of retry identity.
    let updateSeqs = payload.updates.compactMap { update in
      update.hasSeq ? Int64(update.seq) : nil
    }
    let skippedSeqs = payload.skippedSequences.map(\.seq)
    let accountedCount = Set(updateSeqs + skippedSeqs).count
    return [
      "start=\(startSeq)",
      "target=\(targetSeq.map(String.init) ?? "none")",
      "seq=\(payload.seq)",
      "result=\(payload.resultType)",
      "final=\(payload.final)",
      "updates=\(payload.updates.count)",
      "skipped=\(payload.skippedSequences.count)",
      "accounted=\(accountedCount)",
    ].joined(separator: "|")
  }

  /// Reports each unchanged malformed-page shape once until durable progress.
  /// This is telemetry suppression only; retries remain cursor-safe and never
  /// infer snapshot repair from an attempt count.
  private func reportInvalidEnvelopeOnce(_ fingerprint: String) {
    guard !reportedInvalidEnvelopeFingerprints.contains(fingerprint) else { return }
    guard reportedInvalidEnvelopeFingerprints.count < Self.maxReportedInvalidEnvelopeFingerprints else {
      if !reportedInvalidEnvelopeOverflow {
        reportedInvalidEnvelopeOverflow = true
        log.error("rejecting additional malformed getUpdates page shapes for bucket \(key)")
      }
      return
    }
    reportedInvalidEnvelopeFingerprints.insert(fingerprint)
    log.error("rejecting malformed getUpdates page for bucket \(key): \(fingerprint)")
  }

  private func validatePageEnvelope(
    _ payload: InlineProtocol.GetUpdatesResult,
    startSeq: Int64,
    targetSeq: Int64
  ) -> Bool? {
    guard payload.resultType == .slice || payload.resultType == .empty else {
      return nil
    }
    guard payload.seq >= startSeq else {
      return nil
    }
    // An equal-bound request has no journal row from which the server can
    // supply a date. Admit only this exact no-op; the normal page commit keeps
    // the stored date and completes checkpoint, buffer and activity ownership.
    let isEmptyCompletion = payload.resultType == .empty && payload.final &&
      payload.seq == startSeq && startSeq == targetSeq && payload.date == 0 &&
      payload.updates.isEmpty && payload.skippedSequences.isEmpty && !payload.hasSidecars
    guard payload.date > 0 || isEmptyCompletion else {
      return nil
    }
    if payload.resultType == .empty, !payload.updates.isEmpty {
      return nil
    }

    var accounted = Set<Int64>()
    for update in payload.updates {
      guard update.hasSeq else {
        return nil
      }
      let updateSeq = Int64(update.seq)
      guard updateSeq > startSeq, updateSeq <= payload.seq, accounted.insert(updateSeq).inserted else {
        return nil
      }
    }

    var requiresSnapshotRepair = false
    for skipped in payload.skippedSequences {
      guard skipped.seq > startSeq, skipped.seq <= payload.seq, accounted.insert(skipped.seq).inserted else {
        return nil
      }
      switch skipped.reason {
        case .irrelevantToBucket:
          break
        case .snapshotRepairRequired:
          requiresSnapshotRepair = true
        case .unspecified, .UNRECOGNIZED:
          return nil
      }
    }

    guard Int64(accounted.count) == payload.seq - startSeq else {
      return nil
    }
    return requiresSnapshotRepair
  }

  @discardableResult
  private func applyBufferedRealtimeUpdates(
    upTo targetSeq: Int64,
    excluding excludedSeqs: Set<Int64> = [],
    reason: String
  ) async -> Int64? {
    guard targetSeq > seq else { return 0 }
    guard let sync else {
      log.error("sync reference is nil, cannot apply buffered realtime updates")
      return nil
    }

    let entries = bufferedRealtimeUpdates
      .filter { seq, _ in
        seq > self.seq &&
          seq <= targetSeq &&
          !excludedSeqs.contains(seq)
      }
      .sorted { $0.key < $1.key }

    guard !entries.isEmpty else { return 0 }

    let updates = entries.map(\.value.update)
    let mutationToken = entries.first?.value.mutationToken ?? accountMutationToken
    guard entries.allSatisfy({ ($0.value.mutationToken ?? accountMutationToken) == mutationToken }) else {
      log.warning("mixed account generations in trusted realtime buffer; refusing projection")
      return nil
    }
    let result = await sync.applyUpdatesFromRealtime(updates, mutationToken: mutationToken)
    if !result.succeeded {
      PerformanceTrace.breadcrumb(
        "trusted pointer buffered realtime apply failed",
        category: "sync.realtime",
        level: .warning,
        data: [
          "bucket": key.traceKind,
          "updates": updates.count,
          "applied": result.appliedCount,
          "failed": result.failedCount,
          "reason": reason,
        ]
      )
      log.error(
        "failed to apply \(result.failedCount) buffered realtime update(s) for bucket \(key); keeping pointer before \(targetSeq) (reason=\(reason))"
      )
      return nil
    }
    return maxUpdateDate(in: updates)
  }

  private func bufferRealtimeUpdate(
    _ update: InlineProtocol.Update,
    at sequence: Int64,
    mutationToken: AuthAccountMutationToken?
  ) {
    let bytes = (try? update.serializedData().count) ?? (Self.maxBufferedRealtimeBytes + 1)
    if let existing = bufferedRealtimeUpdates.updateValue(
      BufferedRealtimeUpdate(update: update, bytes: bytes, mutationToken: mutationToken),
      forKey: sequence
    ) {
      bufferedRealtimeBytes -= existing.bytes
    }
    bufferedRealtimeBytes += bytes
  }

  @discardableResult
  private func removeBufferedRealtimeUpdate(at sequence: Int64) -> InlineProtocol.Update? {
    guard let removed = bufferedRealtimeUpdates.removeValue(forKey: sequence) else { return nil }
    bufferedRealtimeBytes -= removed.bytes
    return removed.update
  }

  private func retainBufferedRealtimeUpdates(after sequence: Int64) {
    bufferedRealtimeUpdates = bufferedRealtimeUpdates.filter { $0.key > sequence }
    bufferedRealtimeBytes = bufferedRealtimeUpdates.values.reduce(0) { $0 + $1.bytes }
  }

  private func clearBufferedRealtimeUpdates() {
    bufferedRealtimeUpdates.removeAll(keepingCapacity: false)
    bufferedRealtimeBytes = 0
  }

  private func maxUpdateDate(in updates: [InlineProtocol.Update]) -> Int64 {
    var maxDate: Int64 = 0
    for update in updates where update.date > 0 {
      maxDate = max(maxDate, update.date)
    }
    return maxDate
  }

  private func orderUpdatesBySeq(_ updates: [InlineProtocol.Update]) -> [InlineProtocol.Update] {
    guard updates.count > 1 else { return updates }

    var lastSeq: Int64 = -1
    var needsSort = false
    for update in updates {
      guard update.hasSeq else { continue }
      let seq = Int64(update.seq)
      if seq < lastSeq {
        needsSort = true
        break
      }
      lastSeq = seq
    }

    guard needsSort else { return updates }

    log.debug("reordering \(updates.count) updates for bucket \(key) by seq")
    return updates
      .enumerated()
      .sorted { lhs, rhs in
        let lhsSeq = lhs.element.hasSeq ? Int64(lhs.element.seq) : Int64.max
        let rhsSeq = rhs.element.hasSeq ? Int64(rhs.element.seq) : Int64.max
        if lhsSeq == rhsSeq {
          return lhs.offset < rhs.offset
        }
        return lhsSeq < rhsSeq
      }
      .map(\.element)
  }

  /// Update state from external source (e.g. realtime updates)
  func updateState(seq: Int64, date: Int64) {
    if seq > self.seq {
      self.seq = seq
      self.date = date
      log.trace("updated state for bucket \(key) to seq=\(seq), date=\(date)")
    }
  }

#if DEBUG || DEBUG_BUILD
  func debugFetchLatest() async {
    await fetchNewUpdates()
  }

  func debugRewindState(seq: Int64, date: Int64) async {
    self.seq = seq
    self.date = date
    fetchSeqEnd = nil
    needsFetch = true
    await fetchNewUpdates()
  }

  func debugOverflowRealtimeBufferAndRecover() async -> Bool {
    let overflowCount = Self.maxBufferedRealtimeUpdates + 1
    let firstSyntheticSeq = seq + 2
    guard firstSyntheticSeq >= 1,
          firstSyntheticSeq <= Int64(Int32.max) - Int64(overflowCount - 1)
    else { return false }

    let syntheticDate = max(date, Int64(Date().timeIntervalSince1970))
    let updates = (0 ..< overflowCount).map { offset in
      InlineProtocol.Update.with {
        $0.seq = Int32(firstSyntheticSeq + Int64(offset))
        $0.date = syntheticDate
      }
    }
    await processRealtimeUpdates(updates)
    return true
  }
#endif

  func snapshot() -> SyncBucketSnapshot {
    SyncBucketSnapshot(
      key: key,
      seq: seq,
      date: date,
      isFetching: isFetching,
      needsFetch: needsFetch
    )
  }
}
