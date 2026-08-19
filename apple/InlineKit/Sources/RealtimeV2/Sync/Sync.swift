import Foundation
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

  private struct ActiveDiscoveryRound {
    let generation: UInt64
    var observedTarget = false
    var pendingTargets: [BucketKey: DiscoveryTarget] = [:]
  }

  private struct PendingDiscoveryRound {
    let checkpoint: Int64
    var pendingTargets: [BucketKey: DiscoveryTarget]
  }

  private enum StateFetchAttemptError: Error {
    case invalidResponse
    case invalidDate
    case missingUserSequence
    case missingDiscoveryTargets
    case userCheckpointWriteFailed
    case globalCheckpointWriteFailed
  }

  private static let getUpdatesStateTimeout: Duration = .seconds(15)
  private static let getUpdatesStateRetryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(5)]
  private static let chatRepairTimeout: Duration = .seconds(20)
  private static let chatRepairHistoryLimit: Int32 = 50

  private var log = Log.scoped("RealtimeV2.Sync")

  private var applyUpdates: ApplyUpdates
  private var syncStorage: SyncStorage
  // Must be a strong reference: Sync/BucketActor schedule async Tasks that can easily outlive
  // the caller's local reference. A weak ref here makes sync silently stop working.
  private var client: ProtocolClientType?
  private var config: SyncConfig
  private var stats: SyncStats = .empty
  private var activeBucketFetches = 0
  private var isSyncActivityActive = false
  private var isStateFetchInFlight = false
  private var isStateFetchPending = false
  private var nextDiscoveryRoundGeneration: UInt64 = 0
  private var pendingDiscoveryRounds: [UInt64: PendingDiscoveryRound] = [:]
  private var queuedDiscoveryTargets: [BucketKey: DiscoveryTarget] = [:]
  private var activeDiscoveryRound: ActiveDiscoveryRound?
  private var syncActivityListener: (@Sendable (Bool) async -> Void)?

  private var buckets: [BucketKey: BucketActor] = [:]
  private let bucketFetchLimiter: FetchLimiter
  private var generation: UInt64 = 0
  private var acceptsWork = false
  private var isResetting = false
  private var rootTasks: [UUID: Task<Void, Never>] = [:]
  private var operationsInProgress = 0
  private var operationDrainWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    applyUpdates: ApplyUpdates,
    syncStorage: SyncStorage,
    client: ProtocolClientType,
    config: SyncConfig,
    acceptsWork: Bool = true
  ) {
    self.applyUpdates = applyUpdates
    self.syncStorage = syncStorage
    self.client = client
    self.config = config
    self.acceptsWork = acceptsWork
    bucketFetchLimiter = FetchLimiter(limit: config.maxConcurrentBucketFetches)
  }

  // MARK: - Public API

  /// Process incoming updates (pushed from server)
  func process(updates: [InlineProtocol.Update]) async {
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
          if update.hasSeq, update.seq > 0, let key = getBucketKey(for: update) {
            // Route sequenced updates through BucketActor so we can enforce strict per-bucket ordering
            // and fetch missing history when we detect gaps.
            bucketedUpdates[key, default: []].append(update)
            continue
          }

          // Non-sequenced updates are applied directly.
          applyingUpdates.append(update)
      }
    }

    // Apply the direct updates
    if !applyingUpdates.isEmpty {
      let result = await applyUpdates.apply(updates: applyingUpdates, source: .realtime)
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
          log.warning("direct participant grant update failed; fetching user bucket for sidecar-backed recovery")
          fetchUserBucket()
        }
      }
    }

    // Apply bucketed updates (sequenced) via BucketActor ordering/buffering.
    if !bucketedUpdates.isEmpty {
      for (key, updates) in bucketedUpdates {
        guard let actor = await getBucketActor(key: key, generation: expectedGeneration) else { return }
        await actor.processRealtimeUpdates(updates)
        guard isCurrent(expectedGeneration) else { return }
      }
    }
  }

  func connectionStateChanged(state: RealtimeConnectionState) {
    log.trace("connection state changed to \(state)")

    switch state {
      case .connected:
        // Resolve the global checkpoint first. A fresh account installs the current
        // user sequence; an existing account then catches that bucket up incrementally.
        getStateFromServer()

      case .connecting:
        // We could pause buckets here if needed
        break

      case .updating:
        break
    }
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
    guard acceptsWork, !isResetting else { return }
    for (key, state) in states {
      if let actor = buckets[key] {
        await actor.installSnapshotState(state)
      }
    }
  }

  func discardBucketState(for key: BucketKey) async {
    log.debug("discarding sync bucket state for \(key)")
    buckets.removeValue(forKey: key)
    await syncStorage.removeBucketState(for: key)
  }

  /// Apply updates from bucket actor
  func applyUpdatesFromBucket(
    _ updates: [InlineProtocol.Update],
    sidecars: InlineProtocol.UpdateSidecars? = nil,
    bucketCommit: UpdateBucketCommit? = nil
  ) async -> UpdateApplyResult {
    await applyUpdates.apply(
      updates: updates,
      source: .syncCatchup,
      sidecars: sidecars,
      bucketCommit: bucketCommit
    )
  }

  /// Apply sequenced realtime updates through the same engine, but with realtime side effects.
  func applyUpdatesFromRealtime(
    _ updates: [InlineProtocol.Update],
    bucketCommit: UpdateBucketCommit? = nil
  ) async -> UpdateApplyResult {
    await applyUpdates.apply(
      updates: updates,
      source: .realtime,
      sidecars: nil,
      bucketCommit: bucketCommit
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
      let chatResult = try await client.callRpc(method: .getChat, input: .getChat(.with {
        $0.peerID = peer.toInputPeer()
      }), timeout: Self.chatRepairTimeout)
      guard case let .getChat(chat) = chatResult else {
        log.error("failed to parse getChat result during chat repair")
        return nil
      }
      guard chat.hasChat, chat.chat.id > 0 else {
        log.error("getChat result omitted a valid chat during chat repair")
        return nil
      }

      let participantsResult = try await client.callRpc(
        method: .getChatParticipants,
        input: .getChatParticipants(.with { $0.chatID = chat.chat.id }),
        timeout: Self.chatRepairTimeout
      )
      guard case let .getChatParticipants(participants) = participantsResult else {
        log.error("failed to parse getChatParticipants result during chat repair")
        return nil
      }

      let historyResult = try await client.callRpc(method: .getChatHistory, input: .getChatHistory(.with {
        $0.peerID = peer.toInputPeer()
        $0.mode = .historyModeLatest
        $0.limit = Self.chatRepairHistoryLimit
      }), timeout: Self.chatRepairTimeout)
      guard case let .getChatHistory(history) = historyResult else {
        log.error("failed to parse getChatHistory result during chat repair")
        return nil
      }

      let repaired = await applyUpdates.repairChat(ChatRepairSnapshot(
        peer: peer,
        chat: chat,
        participants: participants,
        history: history,
        targetState: targetState,
        reason: reason
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

  func updateConfig(_ config: SyncConfig) async {
    self.config = config
    await bucketFetchLimiter.setLimit(config.maxConcurrentBucketFetches)
    log.debug("updated sync config: messageUpdates=true, gap=\(config.lastSyncSafetyGapSeconds)s")
    await publishSyncActivityIfNeeded()
  }

  func activateGeneration() {
    generation &+= 1
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
    activeBucketFetches = 0
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
    snapshot.activeBucketFetches = activeBucketFetches
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
        activeBucketFetches = 0
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

  private func fetchUserBucket() {
    log.trace("fetching user bucket updates")
    launchRootTask { sync, generation in
      guard let bucketActor = await sync.getBucketActor(key: .user, generation: generation) else { return }
      await bucketActor.fetchNewUpdates()
    }
  }

  private func getBucketActor(key: BucketKey, generation expectedGeneration: UInt64) async -> BucketActor? {
    guard isCurrent(expectedGeneration) else { return nil }
    if let bucketActor = buckets[key] {
      return bucketActor
    }
    let bucketState: BucketState
    do {
      bucketState = try await syncStorage.getBucketState(for: key)
    } catch {
      log.error("failed to load sync bucket state for \(key): \(error)")
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
      fetchLimiter: bucketFetchLimiter
    )
    buckets[key] = bucketActor
    return bucketActor
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
      return
    }
    let launched = launchRootTask { sync, generation in
      await sync.fetchStateFromServerWithRetry(generation: generation)
    }
    isStateFetchInFlight = launched
  }

  private func fetchStateFromServerWithRetry(generation expectedGeneration: UInt64) async {
    defer {
      isStateFetchInFlight = false
      if isStateFetchPending {
        isStateFetchPending = false
        getStateFromServer()
      }
    }
    guard isCurrent(expectedGeneration) else { return }
    guard let client else {
      log.error("client is nil")
      return
    }

    guard let state = await preparedSyncState(generation: expectedGeneration) else { return }
    let isFreshCheckpoint = state.lastSyncDate == 0
    if !isFreshCheckpoint {
      fetchUserBucket()
    }
    let maxAttempts = Self.getUpdatesStateRetryDelays.count + 1
    let totalStartedAt = Date()
    PerformanceTrace.breadcrumb(
      "sync state check started",
      category: "sync.lifecycle",
      data: [
        "last_sync_age_sec": max(0, nowSeconds() - state.lastSyncDate),
        "max_attempts": maxAttempts,
      ]
    )

    for attempt in 1 ... maxAttempts {
      let attemptStartedAt = Date()
      let span = PerformanceTrace.begin(
        "SyncGetUpdatesState",
        category: .sync,
        "attempt=\(attempt) last_sync_age_sec=\(max(0, nowSeconds() - state.lastSyncDate))"
      )
      do {
        guard isCurrent(expectedGeneration), !Task.isCancelled else { return }
        if !isFreshCheckpoint {
          nextDiscoveryRoundGeneration &+= 1
          var round = ActiveDiscoveryRound(generation: nextDiscoveryRoundGeneration)
          round.pendingTargets = queuedDiscoveryTargets
          round.observedTarget = !queuedDiscoveryTargets.isEmpty
          queuedDiscoveryTargets.removeAll()
          activeDiscoveryRound = round
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
          guard let seededUser = await syncStorage.advanceBucketState(
            for: .user,
            state: BucketState(date: payload.date, seq: Int64(payload.seq))
          ) else {
            throw StateFetchAttemptError.userCheckpointWriteFailed
          }
          await installSnapshotBucketStates([.user: seededUser])
          let seededGlobal = await syncStorage.setState(SyncState(lastSyncDate: payload.date))
          guard seededGlobal else {
            throw StateFetchAttemptError.globalCheckpointWriteFailed
          }
          stats.lastSyncDate = payload.date
        } else if payload.hasUpdatesFound {
          let round = activeDiscoveryRound ?? ActiveDiscoveryRound(generation: nextDiscoveryRoundGeneration)
          activeDiscoveryRound = nil
          try await stageDiscoveryCheckpoint(
            payload.date,
            updatesFound: payload.updatesFound,
            round: round,
            generation: expectedGeneration
          )
        } else {
          throw StateFetchAttemptError.invalidResponse
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
        activeDiscoveryRound = nil
        span.end(
          "attempt=\(attempt) success=false duration_ms=\(PerformanceTrace.elapsedMilliseconds(since: attemptStartedAt))"
        )
        log.error("failed to get updates state (attempt \(attempt)/\(maxAttempts)): \(error)")
        guard attempt < maxAttempts else {
          PerformanceTrace.breadcrumb(
            "sync state check failed",
            category: "sync.lifecycle",
            level: .warning,
            data: [
              "attempts": attempt,
              "duration_ms": PerformanceTrace.elapsedMilliseconds(since: totalStartedAt),
            ]
          )
          return
        }
        let delay = Self.getUpdatesStateRetryDelays[attempt - 1]
        do {
          try await Task.sleep(for: delay)
        } catch {
          return
        }
      }
    }
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

  func bucketFetchActivityStarted() async {
    activeBucketFetches += 1
    await publishSyncActivityIfNeeded()
  }

  func bucketFetchActivityEnded() async {
    activeBucketFetches = max(0, activeBucketFetches - 1)
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
      // A hint received after a state result belongs to the next discovery
      // round. Keeping it until that round is opened prevents a later
      // updatesFound=true response from borrowing a target from the old round.
      mergeDiscoveryTarget(target, for: key, into: &queuedDiscoveryTargets)
      return
    }
    round.observedTarget = true
    mergeDiscoveryTarget(target, for: key, into: &round.pendingTargets)
    activeDiscoveryRound = round
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
      pendingTargets: round.pendingTargets
    )
    guard await commitDiscoveryCheckpointsIfReady(generation: expectedGeneration) else {
      throw StateFetchAttemptError.globalCheckpointWriteFailed
    }
  }

  private func commitDiscoveryCheckpointsIfReady(generation expectedGeneration: UInt64? = nil) async -> Bool {
    for roundGeneration in pendingDiscoveryRounds.keys.sorted() {
      guard let round = pendingDiscoveryRounds[roundGeneration], round.pendingTargets.isEmpty else {
        // A later discovery result cannot move the shared date past an older
        // round whose target is still unapplied.
        break
      }
      let saved = await updateLastSyncDate(
        maxAppliedDate: round.checkpoint,
        source: "getUpdatesState:converged",
        generation: expectedGeneration
      )
      guard saved else { return false }
      pendingDiscoveryRounds.removeValue(forKey: roundGeneration)
    }
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
    guard acceptsWork, !isResetting else { return false }
    let id = UUID()
    let expectedGeneration = generation
    let task = Task { [weak self] in
      guard let self else { return }
      await operation(self, expectedGeneration)
      await self.finishRootTask(id)
    }
    rootTasks[id] = task
    return true
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
      case let .updateReaction(payload):
        .chat(peer: .with { $0.chat = .with { $0.chatID = payload.reaction.chatID } })
      case let .deleteReaction(payload):
        .chat(peer: .with { $0.chat = .with { $0.chatID = payload.chatID } })
      case let .deleteChat(payload):
        .chat(peer: payload.peerID)
      case let .markAsUnread(payload):
        .chat(peer: payload.peerID)
      case let .spaceMemberAdd(payload):
        .space(id: payload.member.spaceID)
      case let .spaceMemberDelete(payload):
        .space(id: payload.spaceID)
      case let .spaceMemberUpdate(payload):
        .space(id: payload.member.spaceID)
      case .joinSpace:
        .user
      case .updateUserStatus, .updateUserSettings, .updatedUser, .dialogArchived, .dialogNotificationSettings:
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
      case .messageActionInvoked, .messageActionAnswered, .dialogFollowMode, .dialogCollapsedMaxID:
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
    let isActive = activeBucketFetches > 0
    guard isActive != isSyncActivityActive else { return }
    isSyncActivityActive = isActive
    if let syncActivityListener {
      await syncActivityListener(isActive)
    }
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

  private static let updatesPageLimit: Int32 = 200
  private static let maxTotalUpdates: Int64 = 1000
  private static let maxBufferedRealtimeUpdates = 4_096
  private static let maxBufferedRealtimeBytes = 16 * 1024 * 1024
  private static let getUpdatesTimeout: Duration = .seconds(30)
  private static let maxAutomaticRetryAttempts = 3

  // Strong ref for the same reason as Sync.client.
  private var client: ProtocolClientType?
  private weak var sync: Sync?
  private let fetchLimiter: FetchLimiter

  var key: BucketKey
  var seq: Int64
  var date: Int64
  private var fetchSeqEnd: Int64? = nil

  /// Prevents concurrent fetch operations
  private var isFetching: Bool = false
  private var needsFetch: Bool = false

  private var retryTask: Task<Void, Never>?
  private var retryAttempt: Int = 0
  private var isInvalidated: Bool = false
  private var activeOperations = 0
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []
  /// Buffer to accumulate updates during fetch loop before applying them all at once
  private var pendingUpdates: [InlineProtocol.Update] = []
  private var pendingSidecars = InlineProtocol.UpdateSidecars()
  private var pendingSidecarUserIds = Set<Int64>()
  private var pendingSidecarChatIds = Set<Int64>()
  private var pendingSidecarDialogKeys = Set<String>()
  private var pendingSidecarSpaceIds = Set<Int64>()
  private var pendingSidecarUserGroupIds = Set<Int64>()

  private struct BufferedRealtimeUpdate {
    let update: InlineProtocol.Update
    let bytes: Int
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
    fetchLimiter: FetchLimiter
  ) {
    self.key = key
    self.seq = seq
    self.date = date
    self.client = client
    self.sync = sync
    self.fetchLimiter = fetchLimiter
  }

  /// Advances an already-created actor when an authoritative account snapshot
  /// installs a newer resource cursor in GRDB.
  func installSnapshotState(_ state: BucketState) {
    guard !isInvalidated, state.seq > seq else { return }
    seq = state.seq
    date = max(date, state.date)
    clearPendingCatchupBatch()
    retainBufferedRealtimeUpdates(after: state.seq)
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
      case .dialogFollowMode, .dialogCollapsedMaxID:
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
  func processRealtimeUpdates(_ updates: [InlineProtocol.Update]) async {
    guard !isInvalidated else { return }
    beginOperation()
    defer { endOperation() }

    // Buffer incoming updates
    for update in updates {
      guard update.hasSeq, update.seq > 0 else { continue }
      let incomingSeq = Int64(update.seq)
      // Skip duplicates/outdated updates.
      guard incomingSeq > seq else { continue }
      bufferRealtimeUpdate(update, at: incomingSeq)
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

    // If catch-up has already fetched a pending batch, defer realtime draining until
    // that batch is committed to preserve monotonic per-bucket apply order.
    if isFetching, !pendingUpdates.isEmpty {
      log.trace("deferring realtime drain for bucket \(key) while catch-up batch is pending")
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

    let drained = await drainBufferedRealtimeUpdates()
    guard drained else { return }

    // If we still have buffered updates, we're missing at least one seq and must fetch history.
    guard !bufferedRealtimeUpdates.isEmpty else { return }

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
    guard upToSeq > 0 else { return true }
    // Ignore stale hints.
    guard upToSeq > seq else { return false }
    fetchSeqEnd = max(fetchSeqEnd ?? 0, upToSeq)
    return true
  }

  func noteHasNewUpdatesAndMaybeFetch(upToSeq: Int64) async {
    if noteHasNewUpdates(upToSeq: upToSeq) {
      await fetchNewUpdates()
    }
  }

  private func drainBufferedRealtimeUpdates() async -> Bool {
    guard !isInvalidated else { return true }

    guard let sync else {
      log.error("sync reference is nil, cannot apply realtime updates")
      return false
    }

    guard !bufferedRealtimeUpdates.isEmpty else { return true }

    // Drop any buffered updates that are now behind our applied cursor.
    if bufferedRealtimeUpdates.count > 0 {
      retainBufferedRealtimeUpdates(after: seq)
    }

    var contiguous: [InlineProtocol.Update] = []
    var nextSeq = seq
    var nextDate = date

    // Drain a contiguous run starting at the next expected seq.
    while let next = bufferedRealtimeUpdates[nextSeq + 1]?.update {
      contiguous.append(next)
      nextSeq = Int64(next.seq)
      nextDate = next.date
    }

    guard !contiguous.isEmpty else { return true }

    log.debug("applying \(contiguous.count) realtime updates for bucket \(key) (new seq=\(nextSeq))")
    let span = PerformanceTrace.begin(
      "SyncRealtimeDrain",
      category: .sync,
      "bucket=\(key.traceKind) updates=\(contiguous.count) start_seq=\(seq) end_seq=\(nextSeq)"
    )
    let startedAt = Date()
    let targetState = BucketState(date: nextDate, seq: nextSeq)
    let result = await sync.applyUpdatesFromRealtime(
      contiguous,
      bucketCommit: UpdateBucketCommit(key: key, state: targetState)
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
      Task { await self.fetchNewUpdates() }
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

    seq = saved.seq
    date = saved.date
    retainBufferedRealtimeUpdates(after: saved.seq)
    if let fetchSeqEnd, saved.seq >= fetchSeqEnd {
      self.fetchSeqEnd = nil
    }
    await sync.bucketDidAdvance(key: key, state: saved)
    return true
  }

  func fetchNewUpdates(reportsSyncActivity: Bool = true) async {
    guard !isInvalidated else { return }

    // Guard against concurrent fetch operations
    if isFetching {
      needsFetch = true
      log.trace("fetch already in progress for bucket \(key), scheduling follow-up")
      if let sync {
        await sync.recordBucketFetchFollowup()
      }
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

    if reportsSyncActivity {
      await sync.bucketFetchActivityStarted()
    }

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
        resetRetryState()
      } else {
        finishedWithoutRetry = false
        scheduleRetry()
        break
      }

      // If we have buffered realtime updates, keep fetching until we've filled the gap.
      _ = await drainBufferedRealtimeUpdates()

      let hasOutstandingFetchTarget = fetchSeqEnd.map { $0 > seq } ?? false
      guard needsFetch || bufferedRealtimeUpdates.isEmpty == false || hasOutstandingFetchTarget else { break }
      // One invocation owns one bounded difference tranche. A large backlog is
      // continued as background work so it cannot monopolize the actor or keep
      // the account-wide Updating presentation active for the entire backlog.
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
    if reportsSyncActivity {
      await sync.bucketFetchActivityEnded()
    }
    if scheduleBackgroundFollowUp, !isInvalidated {
      Task { await self.fetchNewUpdates(reportsSyncActivity: false) }
    }
  }

  private func fetchNewUpdatesOnce() async -> Bool {
    guard let client else {
      log.error("client is nil, cannot fetch updates")
      return false
    }

    guard let sync else {
      log.error("sync reference is nil, cannot persist state")
      return false
    }

    await sync.recordBucketFetchStart()

    clearPendingCatchupBatch()

    let fetchStartedAt = Date()
    let fetchSpan = PerformanceTrace.begin(
      "SyncBucketFetchOnce",
      category: .sync,
      "bucket=\(key.traceKind) start_seq=\(seq)"
    )
    var pageCount = 0
    var resultLabel = "unknown"

    // Local state tracking for the loop
    var currentSeq = seq
    var finalSeq: Int64 = seq
    var finalDate: Int64 = date
    var totalFetched = 0
    var totalSkipped = 0
    var totalDuplicateSkipped = 0
    var isFinal = false
    var maxAppliedDate: Int64 = 0
    defer {
      fetchSpan.end(
        "bucket=\(key.traceKind) result=\(resultLabel) pages=\(pageCount) fetched=\(totalFetched) skipped=\(totalSkipped) duplicates=\(totalDuplicateSkipped) duration_ms=\(PerformanceTrace.elapsedMilliseconds(since: fetchStartedAt))"
      )
    }

    // Snapshot an optional upper bound so a live connection doesn't keep chasing a moving target.
    var requestedEndSeq: Int64? = fetchSeqEnd
    if let maxBuffered = bufferedRealtimeUpdates.keys.max() {
      requestedEndSeq = max(requestedEndSeq ?? 0, maxBuffered)
    }
    var hardEndSeq = requestedEndSeq.map { min($0, currentSeq + Self.maxTotalUpdates) }
    if let requestedEndSeq, let hardEndSeq, requestedEndSeq > hardEndSeq {
      fetchSeqEnd = max(fetchSeqEnd ?? 0, requestedEndSeq)
    }
    if let bound = hardEndSeq, bound <= currentSeq {
      // Avoid invalid requests (server requires seqEnd >= startSeq).
      hardEndSeq = nil
    }

    // When the server reports TOO_LONG, it returns a slice boundary seq. We temporarily use `sliceEndSeq`
    // to fetch up to that boundary, then restore `hardEndSeq` (if any) and continue.
    var sliceEndSeq: Int64? = nil

    // On a cold start (no sequence), attempt a small catch-up instead of immediately fast-forwarding.
    // We cap the first request to avoid pulling large history. If a chat bucket reports TOO_LONG,
    // continue with bounded slices rather than marking stale history as caught up.
    let isColdStart = seq == 0
    let coldStartTotalLimit: Int32 = 50

    do {
      log.debug("starting fetch for bucket \(key) from seq \(seq)")

      // Fetch loop: accumulate all updates until final=true
      while !isFinal {
        log.debug("getUpdates request bucket \(key) startSeq=\(currentSeq) coldStart=\(isColdStart)")

        let requestSeqEnd: Int64? = sliceEndSeq ?? hardEndSeq

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

        let result: InlineProtocol.RpcResult.OneOf_Result?
        let rpcStartedAt = Date()
        let rpcSpan = PerformanceTrace.begin(
          "SyncBucketRPC",
          category: .sync,
          "bucket=\(key.traceKind) start_seq=\(currentSeq) seq_end=\(requestSeqEnd ?? 0)"
        )
        do {
          result = try await client.callRpc(method: .getUpdates, input: .getUpdates(.with {
          $0.bucket = key.toProtocolBucket()
          $0.startSeq = currentSeq
          if isColdStart, sliceEndSeq == nil {
            $0.totalLimit = coldStartTotalLimit
          } else {
            $0.totalLimit = Int32(Self.maxTotalUpdates)
          }
          $0.limit = Self.updatesPageLimit
          if let requestSeqEnd {
            $0.seqEnd = requestSeqEnd
          }
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
          log.error("failed to parse getUpdates result")
          resultLabel = "parse_failed"
          return false
        }

        let totalCount = payload.updates.count

        if payload.resultType != .tooLong {
          guard let requiresSnapshotRepair = validatePageEnvelope(payload, startSeq: currentSeq) else {
            resultLabel = "invalid_page_envelope"
            return false
          }
          if requiresSnapshotRepair {
            guard await repairChatSnapshotIfNeeded(
              targetSeq: payload.seq,
              targetDate: payload.date,
              reason: "server_classified_gap"
            ) else {
              resultLabel = "snapshot_repair_required"
              return false
            }
            resultLabel = "repaired_server_classified_gap"
            return true
          }

          // A final empty page is authoritative even when an earlier push hint
          // advertised a higher sequence. Retaining that stale target would make
          // the outer fetch loop immediately issue the same request forever.
          if payload.resultType == .empty,
             payload.final,
             payload.seq == currentSeq {
            if let requestedEndSeq,
               fetchSeqEnd.map({ $0 <= requestedEndSeq }) == true {
              fetchSeqEnd = nil
            }
            hardEndSeq = nil
            sliceEndSeq = nil
          }
        }

        // Defensive guard: if the server reports non-final but does not advance seq,
        // we'd spin this loop forever and keep the sync actor busy.
        if !payload.final, payload.seq == currentSeq {
          log.error(
            "non-progress getUpdates response for bucket \(key) (seq=\(payload.seq), total=\(totalCount), result=\(payload.resultType)); aborting fetch loop"
          )
          resultLabel = "non_progress"
          PerformanceTrace.breadcrumb(
            "sync bucket fetch non-progress response",
            category: "sync.catchup",
            level: .warning,
            data: [
              "bucket": key.traceKind,
              "seq": payload.seq,
              "updates": totalCount,
            ]
          )
          return false
        }

        // Handle gaps (TOO_LONG)
        if payload.resultType == .tooLong {
          log.warning(
            "getUpdates TOO_LONG for bucket \(key) (startSeq=\(currentSeq), seq=\(payload.seq), date=\(payload.date))"
          )
          PerformanceTrace.event(
            "SyncBucketTooLong",
            category: .sync,
            "bucket=\(key.traceKind) start_seq=\(currentSeq) seq=\(payload.seq)"
          )
          PerformanceTrace.breadcrumb(
            "sync bucket fetch too long",
            category: "sync.catchup",
            level: .warning,
            data: [
              "bucket": key.traceKind,
              "start_seq": currentSeq,
              "seq": payload.seq,
            ]
          )
          await sync.recordBucketFetchTooLong()
          if isColdStart, shouldRepairColdChatTooLong {
            let repairedSeq = Int64(payload.seq)
            if await repairChatSnapshotIfNeeded(
              targetSeq: repairedSeq,
              targetDate: payload.date,
              reason: "cold_too_long"
            ) {
              resultLabel = "repaired_too_long"
              return true
            }
          }
          // Slice within max total updates and commit each slice before fetching the next one.
          //
          // Server behaviors:
          // - New: returns a slice boundary seq (<= currentSeq + maxTotalUpdates)
          // - Legacy: returns latestSeq (can be far ahead); we derive our own boundary via `currentSeq + maxTotalUpdates`.
          let serverSeq = Int64(payload.seq)
          if serverSeq <= currentSeq {
            log.error("TOO_LONG seq \(serverSeq) is not ahead of currentSeq \(currentSeq) for bucket \(key)")
            resultLabel = "too_long_invalid_seq"
            return true
          }
          let seqGap = serverSeq - currentSeq
          if seqGap > Self.maxTotalUpdates {
            // Legacy server semantics: remember latestSeq, but commit one bounded slice at a time.
            fetchSeqEnd = max(fetchSeqEnd ?? 0, serverSeq)
            hardEndSeq = min(serverSeq, currentSeq + Self.maxTotalUpdates)
            sliceEndSeq = hardEndSeq
          } else {
            // New server semantics: `payload.seq` is already the slice boundary.
            sliceEndSeq = serverSeq
          }
          continue
        }

        // Validate seq: if server seq is behind or equal to our local seq (and not TOO_LONG), something is wrong or
        // it's a dupe
        if payload.seq < currentSeq {
          log.warning(
            "server seq (\(payload.seq)) < local seq (\(currentSeq)), skipping fetch for bucket \(key)"
          )
          // Treat this as a non-retryable stop condition. We can't make progress if the server
          // reports a seq behind our cursor.
          clearBufferedRealtimeUpdates()
          resultLabel = "server_behind"
          return true
        }

        if payload.hasSidecars {
          mergeSidecars(payload.sidecars)
        }

        // Filter and accumulate updates
        var duplicateSkipped = 0
        let filteredUpdates = payload.updates.filter { update in
          // Skip duplicates
          if update.hasSeq, update.seq <= self.seq {
            log.trace("skipping duplicate update with seq \(update.seq) in bucket \(key)")
            duplicateSkipped += 1
            return false
          }
          guard shouldProcessUpdate(update) else {
            log.error(
              "unsupported update in bucket catch-up; refusing to advance cursor: \(String(describing: update.update))"
            )
            return false
          }
          return true
        }

        // A generated-but-unowned constructor is a current contract mismatch
        // and must not be filtered into apparent success. A truly unknown
        // future oneof has no typed case and is accepted above as a deliberate
        // compatibility no-op.
        if filteredUpdates.count != payload.updates.count - duplicateSkipped {
          resultLabel = "unsupported_update"
          return false
        }

        let skippedCount = totalCount - filteredUpdates.count
        let nonDuplicateSkipped = max(0, skippedCount - duplicateSkipped)
        totalSkipped += nonDuplicateSkipped
        totalDuplicateSkipped += duplicateSkipped

        log.debug(
          "getUpdates response bucket \(key) seq=\(payload.seq) date=\(payload.date) final=\(payload.final) result=\(payload.resultType) total=\(totalCount) applied=\(filteredUpdates.count) skipped=\(skippedCount)"
        )
        let maxDeliveredSeq = filteredUpdates
          .compactMap { update in update.hasSeq ? Int64(update.seq) : nil }
          .max() ?? currentSeq
        if Int64(payload.seq) > maxDeliveredSeq {
          log.warning(
            "advancing getUpdates pointer with explicit sequence accounting for bucket \(key) (deliveredSeq=\(maxDeliveredSeq), pointerSeq=\(payload.seq), total=\(totalCount), delivered=\(filteredUpdates.count), skipped=\(payload.skippedSequences.count))"
          )
        }

        pendingUpdates.append(contentsOf: filteredUpdates)
        totalFetched += filteredUpdates.count

        // Update loop variables
        currentSeq = payload.seq
        finalSeq = payload.seq
        finalDate = payload.date
        isFinal = payload.final

        if isFinal, sliceEndSeq != nil {
          // We finished a bounded slice; continue fetching (bounded by hardEndSeq if present),
          // or unbounded to learn if more exists.
          sliceEndSeq = nil
          if let hardEndSeq, currentSeq >= hardEndSeq {
            isFinal = true
          } else {
            isFinal = false
          }
        }
      }

      // Apply all accumulated updates in one batch, ordered by seq. Any live
      // updates covered by the authoritative pointer are applied before the
      // same owner commits that pointer.
      let orderedUpdates = orderUpdatesBySeq(pendingUpdates)
      let catchupAppliedSeqs = Set(orderedUpdates.compactMap { update in
        update.hasSeq ? Int64(update.seq) : nil
      })
      let bufferedEntries = bufferedRealtimeUpdates
        .filter { bufferedSeq, _ in
          bufferedSeq > seq &&
            bufferedSeq <= finalSeq &&
            !catchupAppliedSeqs.contains(bufferedSeq)
        }
        .sorted { $0.key < $1.key }
      let bufferedUpdates = bufferedEntries.map(\.value.update)
      let bufferedMaxDate = maxUpdateDate(in: bufferedUpdates)
      let committedSeq = max(seq, finalSeq)
      // A final empty response at the existing sequence disproves a stale push
      // hint, but its response timestamp is not progress for this bucket.
      let authoritativeDate = finalSeq > seq ? max(date, finalDate) : date
      let committedDate = max(authoritativeDate, bufferedMaxDate)
      let bucketCommit = UpdateBucketCommit(
        key: key,
        state: BucketState(date: committedDate, seq: committedSeq)
      )
      var committedBucketState: BucketState?

      if !orderedUpdates.isEmpty {
        // Realtime draining is deferred while this batch is pending so we preserve
        // monotonic per-bucket ordering.
        log.debug("applying \(orderedUpdates.count) updates for bucket \(key)")
        let applyStartedAt = Date()
        let applySpan = PerformanceTrace.begin(
          "SyncBucketApply",
          category: .sync,
          "bucket=\(key.traceKind) updates=\(orderedUpdates.count) sidecars=\(hasPendingSidecars)"
        )
        let result = await sync.applyUpdatesFromBucket(
          orderedUpdates,
          sidecars: hasPendingSidecars ? pendingSidecars : nil,
          bucketCommit: bufferedUpdates.isEmpty ? bucketCommit : nil
        )
        let durationMs = PerformanceTrace.elapsedMilliseconds(since: applyStartedAt)
        applySpan.end(
          "bucket=\(key.traceKind) updates=\(orderedUpdates.count) applied=\(result.appliedCount) failed=\(result.failedCount) duration_ms=\(durationMs)"
        )
        PerformanceTrace.slowBreadcrumb(
          "slow sync catch-up apply",
          category: "sync.catchup",
          durationMs: durationMs,
          thresholdMs: 750,
          data: [
            "bucket": key.traceKind,
            "updates": orderedUpdates.count,
            "applied": result.appliedCount,
            "failed": result.failedCount,
          ]
        )
        guard result.succeeded else {
          log.error(
            "failed to apply \(result.failedCount) catch-up updates for bucket \(key); keeping seq=\(seq)"
          )
          PerformanceTrace.breadcrumb(
            "sync catch-up apply failed",
            category: "sync.catchup",
            level: .warning,
            data: [
              "bucket": key.traceKind,
              "updates": orderedUpdates.count,
              "applied": result.appliedCount,
              "failed": result.failedCount,
            ]
          )
          await sync.recordBucketUpdatesApplied(
            applied: result.appliedCount,
            skipped: totalSkipped + result.failedCount,
            duplicates: totalDuplicateSkipped
          )
          if await repairChatSnapshotIfNeeded(
            targetSeq: finalSeq,
            targetDate: finalDate,
            reason: "apply_failed"
          ) {
            resultLabel = "repaired_apply_failed"
            return true
          }
          resultLabel = "apply_failed"
          return false
        }
        maxAppliedDate = max(maxAppliedDate, maxUpdateDate(in: orderedUpdates))
        committedBucketState = result.committedBucketState
      }

      if !bufferedUpdates.isEmpty || orderedUpdates.isEmpty {
        let result = await sync.applyUpdatesFromRealtime(
          bufferedUpdates,
          bucketCommit: bucketCommit
        )
        guard result.succeeded else {
          log.error(
            "failed to apply \(result.failedCount) buffered realtime updates for bucket \(key); keeping seq=\(seq)"
          )
          resultLabel = "buffered_apply_failed"
          return false
        }
        committedBucketState = result.committedBucketState
      }
      maxAppliedDate = max(maxAppliedDate, bufferedMaxDate)

      if totalFetched > 0 || totalSkipped > 0 || totalDuplicateSkipped > 0 {
        await sync.recordBucketUpdatesApplied(
          applied: totalFetched,
          skipped: totalSkipped,
          duplicates: totalDuplicateSkipped
        )
      }

      // Production GRDB commits the pointer in the final model transaction.
      // Test/non-GRDB apply owners use the existing monotonic storage fallback.
      let saved: BucketState?
      if let committedBucketState {
        saved = committedBucketState
      } else {
        saved = await sync.saveBucketState(for: key, seq: committedSeq, date: committedDate)
      }
      guard let saved else {
        PerformanceTrace.breadcrumb(
          "sync bucket state save failed",
          category: "sync.catchup",
          level: .warning,
          data: [
            "bucket": key.traceKind,
            "seq": committedSeq,
          ]
        )
        resultLabel = "state_save_failed"
        return false
      }

      seq = saved.seq
      date = saved.date
      clearPendingCatchupBatch()
      retainBufferedRealtimeUpdates(after: saved.seq)

      await sync.bucketDidAdvance(key: key, state: saved, authoritative: true)

      if let fetchSeqEnd, saved.seq >= fetchSeqEnd {
        self.fetchSeqEnd = nil
      }

      log.debug(
        "completed fetch for bucket \(key): applied \(totalFetched) updates, skipped \(totalSkipped), new seq=\(saved.seq)"
      )
      resultLabel = "success"

    } catch {
      if isNonRetryableBucketError(error) {
        log.warning("non-retryable getUpdates error for bucket \(key): \(error)")
        PerformanceTrace.breadcrumb(
          "sync bucket fetch non-retryable error",
          category: "sync.catchup",
          level: .warning,
          data: [
            "bucket": key.traceKind,
          ]
        )
        isInvalidated = true
        clearBufferedRealtimeUpdates()
        clearPendingCatchupBatch()
        needsFetch = false
        fetchSeqEnd = nil
        seq = 0
        date = 0
        await sync.discardBucketState(for: key)
        resultLabel = "non_retryable_error"
        return true
      }
      log.error("failed to fetch updates for bucket \(key): \(error)")
      PerformanceTrace.breadcrumb(
        "sync bucket fetch failed",
        category: "sync.catchup",
        level: .warning,
        data: [
          "bucket": key.traceKind,
        ]
      )
      await sync.recordBucketFetchFailure()
      // We exit; next sync attempt will retry from the last saved seq
      resultLabel = "error"
      return false
    }

    resultLabel = "success"
    return true
  }

  private var hasPendingSidecars: Bool {
    !pendingSidecars.users.isEmpty ||
      !pendingSidecars.chats.isEmpty ||
      !pendingSidecars.dialogs.isEmpty ||
      !pendingSidecars.spaces.isEmpty ||
      !pendingSidecars.userGroups.isEmpty
  }

  private func clearPendingCatchupBatch() {
    pendingUpdates.removeAll()
    pendingSidecars = InlineProtocol.UpdateSidecars()
    pendingSidecarUserIds.removeAll()
    pendingSidecarChatIds.removeAll()
    pendingSidecarDialogKeys.removeAll()
    pendingSidecarSpaceIds.removeAll()
    pendingSidecarUserGroupIds.removeAll()
  }

  private func mergeSidecars(_ sidecars: InlineProtocol.UpdateSidecars) {
    for user in sidecars.users where pendingSidecarUserIds.insert(user.id).inserted {
      pendingSidecars.users.append(user)
    }

    for chat in sidecars.chats where pendingSidecarChatIds.insert(chat.id).inserted {
      pendingSidecars.chats.append(chat)
    }

    for space in sidecars.spaces where pendingSidecarSpaceIds.insert(space.id).inserted {
      pendingSidecars.spaces.append(space)
    }

    for userGroup in sidecars.userGroups where pendingSidecarUserGroupIds.insert(userGroup.id).inserted {
      pendingSidecars.userGroups.append(userGroup)
    }

    for dialog in sidecars.dialogs {
      guard let key = sidecarDialogKey(dialog) else { continue }
      guard pendingSidecarDialogKeys.insert(key).inserted else { continue }
      pendingSidecars.dialogs.append(dialog)
    }
  }

  private func sidecarDialogKey(_ dialog: InlineProtocol.Dialog) -> String? {
    switch dialog.peer.type {
      case let .user(user):
        "user:\(user.userID)"
      case let .chat(chat):
        "chat:\(chat.chatID)"
      case nil:
        nil
    }
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

  private func resetRetryState() {
    retryAttempt = 0
    retryTask?.cancel()
    retryTask = nil
  }

  private func scheduleRetry() {
    // Avoid scheduling multiple concurrent retries.
    guard retryTask == nil, !isInvalidated else { return }

    needsFetch = true
    guard retryAttempt < Self.maxAutomaticRetryAttempts else {
      log.error(
        "automatic retry limit reached for bucket \(key); preserving the last committed cursor until a new server hint, reconnect, or explicit recovery"
      )
      PerformanceTrace.breadcrumb(
        "sync bucket automatic retry limit reached",
        category: "sync.catchup",
        level: .warning,
        data: [
          "bucket": key.traceKind,
          "attempts": retryAttempt,
        ]
      )
      return
    }

    // 1s, 2s, 4s, ... up to 30s
    let delaySeconds = min(30, 1 << min(retryAttempt, 5))
    retryAttempt += 1

    log.warning("scheduling retry for bucket \(key) in \(delaySeconds)s")
    retryTask = Task {
      do {
        try await Task.sleep(for: .seconds(delaySeconds))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      self.clearRetryTask()
      await self.fetchNewUpdates(reportsSyncActivity: false)
    }
  }

  private func clearRetryTask() {
    retryTask = nil
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
    clearBufferedRealtimeUpdates()
    clearPendingCatchupBatch()
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

  private var shouldRepairColdChatTooLong: Bool {
    switch key {
      case .chat:
        true
      case .space, .user:
        false
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
    clearPendingCatchupBatch()
    retainBufferedRealtimeUpdates(after: saved.seq)
    if let fetchSeqEnd, saved.seq >= fetchSeqEnd {
      self.fetchSeqEnd = nil
    }
    await sync.bucketDidAdvance(key: key, state: saved, authoritative: true)
    return true
  }

  /// Validates that a lossless page accounts for every sequence it advances.
  /// Returns whether the server requires an authoritative snapshot repair.
  private func validatePageEnvelope(
    _ payload: InlineProtocol.GetUpdatesResult,
    startSeq: Int64
  ) -> Bool? {
    guard payload.resultType == .slice || payload.resultType == .empty else {
      log.error("invalid getUpdates result type \(payload.resultType) for bucket \(key)")
      return nil
    }
    guard payload.seq >= startSeq else {
      log.error("getUpdates page moved backwards for bucket \(key): start=\(startSeq), end=\(payload.seq)")
      return nil
    }

    var accounted = Set<Int64>()
    for update in payload.updates {
      guard update.hasSeq else {
        log.error("getUpdates page included an unsequenced update for bucket \(key)")
        return nil
      }
      let updateSeq = Int64(update.seq)
      guard updateSeq > startSeq, updateSeq <= payload.seq, accounted.insert(updateSeq).inserted else {
        log.error("getUpdates page included an invalid or duplicate sequence \(updateSeq) for bucket \(key)")
        return nil
      }
    }

    var requiresSnapshotRepair = false
    for skipped in payload.skippedSequences {
      guard skipped.seq > startSeq, skipped.seq <= payload.seq, accounted.insert(skipped.seq).inserted else {
        log.error("getUpdates page included an invalid or duplicate skipped sequence \(skipped.seq) for bucket \(key)")
        return nil
      }
      switch skipped.reason {
        case .irrelevantToBucket:
          break
        case .snapshotRepairRequired:
          requiresSnapshotRepair = true
        case .unspecified, .UNRECOGNIZED:
          log.error("getUpdates page included an unknown skipped-sequence reason for bucket \(key)")
          return nil
      }
    }

    guard Int64(accounted.count) == payload.seq - startSeq else {
      log.error(
        "getUpdates page did not account for every sequence for bucket \(key): start=\(startSeq), end=\(payload.seq), accounted=\(accounted.count)"
      )
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
    let result = await sync.applyUpdatesFromRealtime(updates)
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

  private func bufferRealtimeUpdate(_ update: InlineProtocol.Update, at sequence: Int64) {
    let bytes = (try? update.serializedData().count) ?? (Self.maxBufferedRealtimeBytes + 1)
    if let existing = bufferedRealtimeUpdates.updateValue(
      BufferedRealtimeUpdate(update: update, bytes: bytes),
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
