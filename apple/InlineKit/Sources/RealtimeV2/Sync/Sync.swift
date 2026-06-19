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
  public var bucketsTracked: Int
  public var lastDirectApplyAt: Int64
  public var lastBucketFetchAt: Int64
  public var lastBucketFetchFailureAt: Int64
  public var lastSyncDate: Int64
  public var buckets: [SyncBucketSnapshot]

  public init(
    directUpdatesApplied: Int64,
    bucketUpdatesApplied: Int64,
    bucketUpdatesSkipped: Int64,
    bucketUpdatesDuplicateSkipped: Int64,
    bucketFetchCount: Int64,
    bucketFetchFailures: Int64,
    bucketFetchTooLong: Int64,
    bucketFetchFollowups: Int64,
    bucketsTracked: Int,
    lastDirectApplyAt: Int64,
    lastBucketFetchAt: Int64,
    lastBucketFetchFailureAt: Int64,
    lastSyncDate: Int64,
    buckets: [SyncBucketSnapshot]
  ) {
    self.directUpdatesApplied = directUpdatesApplied
    self.bucketUpdatesApplied = bucketUpdatesApplied
    self.bucketUpdatesSkipped = bucketUpdatesSkipped
    self.bucketUpdatesDuplicateSkipped = bucketUpdatesDuplicateSkipped
    self.bucketFetchCount = bucketFetchCount
    self.bucketFetchFailures = bucketFetchFailures
    self.bucketFetchTooLong = bucketFetchTooLong
    self.bucketFetchFollowups = bucketFetchFollowups
    self.bucketsTracked = bucketsTracked
    self.lastDirectApplyAt = lastDirectApplyAt
    self.lastBucketFetchAt = lastBucketFetchAt
    self.lastBucketFetchFailureAt = lastBucketFetchFailureAt
    self.lastSyncDate = lastSyncDate
    self.buckets = buckets
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
  case rewindTrackedBucketsAndFetch

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
      case .rewindTrackedBucketsAndFetch:
        "Rewind Tracked Buckets"
    }
  }

  public var detail: String {
    switch self {
      case .forceDiscovery:
        "Queues getUpdatesState and the user bucket without changing local cursors."
      case .clearStateAndFetch:
        "Clears global and bucket cursors, then runs normal discovery from a cold local state."
      case .seedZeroDateAndFetch:
        "Stores lastSyncDate=0 so the next discovery exercises bounded cold-start lookback."
      case .seedStaleDateAndFetch:
        "Stores a 15-day-old global cursor so discovery exercises stale-state repair."
      case .rewindTrackedBucketsAndFetch:
        "Moves currently tracked bucket cursors back and queues catch-up for those buckets."
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
      case .rewindTrackedBucketsAndFetch:
        "backward.end.circle.fill"
    }
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
  private static let getUpdatesStateTimeout: Duration = .seconds(15)
  private static let getUpdatesStateRetryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(5)]
  private static let initialSyncStateLookbackSeconds: Int64 = 5 * 24 * 60 * 60
  private static let staleSyncStateMaxAgeSeconds: Int64 = 14 * 24 * 60 * 60
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
  private var syncActivityListener: (@Sendable (Bool) async -> Void)?

  private var buckets: [BucketKey: BucketActor] = [:]
  private let bucketFetchLimiter: FetchLimiter

  init(applyUpdates: ApplyUpdates, syncStorage: SyncStorage, client: ProtocolClientType, config: SyncConfig) {
    self.applyUpdates = applyUpdates
    self.syncStorage = syncStorage
    self.client = client
    self.config = config
    bucketFetchLimiter = FetchLimiter(limit: config.maxConcurrentBucketFetches)
  }

  // MARK: - Public API

  /// Process incoming updates (pushed from server)
  func process(updates: [InlineProtocol.Update]) async {
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
      recordDirectApply(count: result.appliedCount)
      if result.succeeded {
        let maxAppliedDate = maxUpdateDate(in: applyingUpdates)
        await updateLastSyncDate(maxAppliedDate: maxAppliedDate, source: "direct")
        // Update bucket states based on applied updates
        await updateBucketStates(for: applyingUpdates)
      } else {
        log.error(
          "failed to apply \(result.failedCount) direct updates; skipping direct sync cursor advancement"
        )
      }
    }

    // Apply bucketed updates (sequenced) via BucketActor ordering/buffering.
    if !bucketedUpdates.isEmpty {
      for (key, updates) in bucketedUpdates {
        let actor = await getBucketActor(key: key)
        await actor.processRealtimeUpdates(updates)
      }
    }
  }

  func connectionStateChanged(state: RealtimeConnectionState) {
    log.trace("connection state changed to \(state)")

    switch state {
      case .connected:
        // Always fetch user bucket on connection to catch up on personal events (kicks, bans, new dialogs)
        fetchUserBucket()
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
  @discardableResult
  func saveBucketState(for key: BucketKey, seq: Int64, date: Int64) async -> Bool {
    log.trace("saving bucket state for \(key): seq=\(seq), date=\(date)")
    let saved = await syncStorage.setBucketState(for: key, state: BucketState(date: date, seq: seq))
    if !saved {
      log.error("failed to save bucket state for \(key): seq=\(seq), date=\(date)")
    }
    return saved
  }

  func discardBucketState(for key: BucketKey) async {
    log.debug("discarding sync bucket state for \(key)")
    buckets.removeValue(forKey: key)
    await syncStorage.removeBucketState(for: key)
  }

  /// Apply updates from bucket actor
  func applyUpdatesFromBucket(
    _ updates: [InlineProtocol.Update],
    sidecars: InlineProtocol.UpdateSidecars? = nil
  ) async -> UpdateApplyResult {
    await applyUpdates.apply(updates: updates, source: .syncCatchup, sidecars: sidecars)
  }

  /// Apply sequenced realtime updates through the same engine, but with realtime side effects.
  func applyUpdatesFromRealtime(_ updates: [InlineProtocol.Update]) async -> UpdateApplyResult {
    await applyUpdates.apply(updates: updates, source: .realtime)
  }

  /// Fetch and apply a bounded current-state snapshot for a chat bucket.
  func repairChatBucket(peer: InlineProtocol.Peer, reason: String) async -> Bool {
    guard let client else {
      log.error("client is nil, cannot repair chat bucket")
      return false
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
        return false
      }

      let historyResult = try await client.callRpc(method: .getChatHistory, input: .getChatHistory(.with {
        $0.peerID = peer.toInputPeer()
        $0.mode = .historyModeLatest
        $0.limit = Self.chatRepairHistoryLimit
      }), timeout: Self.chatRepairTimeout)
      guard case let .getChatHistory(history) = historyResult else {
        log.error("failed to parse getChatHistory result during chat repair")
        return false
      }

      let repaired = await applyUpdates.repairChat(ChatRepairSnapshot(
        peer: peer,
        chat: chat,
        history: history,
        reason: reason
      ))
      if !repaired {
        log.error("failed to apply chat repair snapshot")
      }
      return repaired
    } catch {
      log.error("failed to repair chat bucket", error: error)
      return false
    }
  }

  func updateConfig(_ config: SyncConfig) async {
    self.config = config
    await bucketFetchLimiter.setLimit(config.maxConcurrentBucketFetches)
    log.debug("updated sync config: messageUpdates=true, gap=\(config.lastSyncSafetyGapSeconds)s")
    await publishSyncActivityIfNeeded()
  }

  func clearSyncState() async {
    log.debug("clearing sync state and bucket cache")
    stats = .empty
    buckets.removeAll()
    await syncStorage.clearSyncState()
    activeBucketFetches = 0
    await publishSyncActivityIfNeeded()
  }

  func getStats() async -> SyncStats {
    var snapshot = stats
    let state = await syncStorage.getState()
    snapshot.lastSyncDate = state.lastSyncDate
    let bucketSnapshots = await getBucketSnapshots()
    snapshot.buckets = bucketSnapshots
    snapshot.bucketsTracked = bucketSnapshots.count
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
        buckets.removeAll()
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

      case .rewindTrackedBucketsAndFetch:
        let snapshots = await getBucketSnapshots()
        guard !snapshots.isEmpty else {
          return SyncDebugScenarioResult(
            scenario: scenario,
            succeeded: false,
            summary: "No tracked buckets yet. Open a chat or wait for sync hints first."
          )
        }

        var rewound = 0
        for snapshot in snapshots {
          guard let actor = buckets[snapshot.key] else { continue }
          let newSeq = max(0, snapshot.seq - 25)
          let newDate = max(0, snapshot.date - 60 * 60)
          let saved = await saveBucketState(for: snapshot.key, seq: newSeq, date: newDate)
          guard saved else { continue }
          await actor.debugRewindState(seq: newSeq, date: newDate)
          rewound += 1
        }

        guard rewound > 0 else {
          return SyncDebugScenarioResult(
            scenario: scenario,
            succeeded: false,
            summary: "Failed to save rewound bucket state."
          )
        }

        return SyncDebugScenarioResult(
          scenario: scenario,
          succeeded: true,
          summary: "Rewound \(rewound) tracked bucket(s) and queued catch-up."
        )
    }
  }

  private func queueDebugDiscovery() {
    fetchUserBucket()
    getStateFromServer()
  }
#endif

  // MARK: - Private Helpers

  private func chatHasNewUpdates(_ payload: InlineProtocol.UpdateChatHasNewUpdates) {
    log.trace("chat has new updates: \(payload)")
    Task {
      let bucketActor = await getBucketActor(key: .chat(peer: payload.peerID))
      await bucketActor.noteHasNewUpdatesAndMaybeFetch(upToSeq: Int64(payload.updateSeq))
    }
  }

  private func spaceHasNewUpdates(_ payload: InlineProtocol.UpdateSpaceHasNewUpdates) {
    log.trace("space has new updates: \(payload)")
    Task {
      let bucketActor = await getBucketActor(key: .space(id: payload.spaceID))
      await bucketActor.noteHasNewUpdatesAndMaybeFetch(upToSeq: Int64(payload.updateSeq))
    }
  }

  private func fetchUserBucket() {
    log.trace("fetching user bucket updates")
    Task {
      let bucketActor = await getBucketActor(key: .user)
      await bucketActor.fetchNewUpdates()
    }
  }

  private func getBucketActor(key: BucketKey) async -> BucketActor {
    if let bucketActor = buckets[key] {
      return bucketActor
    }
    let bucketState = await syncStorage.getBucketState(for: key)
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

  /// Get the state from the server
  private func getStateFromServer() {
    Task { await fetchStateFromServerWithRetry() }
  }

  private func fetchStateFromServerWithRetry() async {
    guard let client else {
      log.error("client is nil")
      return
    }

    let state = await preparedSyncState()
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
        // Note: We use callRpc to ensure we wait for the server's acknowledgement,
        // but the primary mechanism for sync is the server pushing 'hasNewUpdates'
        // events in response to this call (or as part of the result).
        let result = try await client.callRpc(method: .getUpdatesState, input: .getUpdatesState(.with {
          $0.date = state.lastSyncDate
        }), timeout: Self.getUpdatesStateTimeout)
        span.end(
          "attempt=\(attempt) success=true duration_ms=\(PerformanceTrace.elapsedMilliseconds(since: attemptStartedAt))"
        )
        log.trace("sent get updates state request with date: \(state.lastSyncDate)")
        if case let .getUpdatesState(payload) = result {
          log.trace(
            "received get updates state date: \(payload.date), updatesFound=\(payload.hasUpdatesFound ? String(payload.updatesFound) : "unknown")"
          )
          if payload.hasUpdatesFound, !payload.updatesFound {
            await updateLastSyncDate(maxAppliedDate: payload.date, source: "getUpdatesState:empty")
          }
        }
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

  private func preparedSyncState() async -> SyncState {
    var state = await syncStorage.getState()

    // Handle uninitialized or too old state
    let now = Int64(Date().timeIntervalSince1970)

    if state.lastSyncDate == 0 {
      // Temporary rollout safety: when sync state is missing, ask the server for the past 5 days so
      // we re-trigger buckets that may have changed while clients upgrade. Once all clients run the
      // new sync engine we can narrow or remove this lookback window.
      let seedDate = max(0, now - Self.initialSyncStateLookbackSeconds)
      log.info("Sync state uninitialized (date=0). Seeding lookback to \(seedDate) (5 days ago)")
      state = SyncState(lastSyncDate: seedDate)
      if await syncStorage.setState(state) == false {
        log.error("failed to persist initialized sync lookback state: \(seedDate)")
      }
    } else if now - state.lastSyncDate > Self.staleSyncStateMaxAgeSeconds {
      let seedDate = max(0, now - Self.initialSyncStateLookbackSeconds)
      log.warning("Sync state too old (> 14 days). Seeding bounded lookback to \(seedDate) (5 days ago)")
      state = SyncState(lastSyncDate: seedDate)
      if await syncStorage.setState(state) == false {
        log.error("failed to persist stale sync lookback state: \(seedDate)")
      }
    }

    return state
  }

  private func updateBucketStates(for updates: [InlineProtocol.Update]) async {
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
      guard saved else {
        log.error("failed to save batch bucket states: \(statesToSave.count)")
        return
      }
    }

    for (key, state) in maxStates {
      if let actor = buckets[key] {
        await actor.updateState(seq: state.seq, date: state.date)
      }
    }
  }

  private func maxUpdateDate(in updates: [InlineProtocol.Update]) -> Int64 {
    var maxDate: Int64 = 0
    for update in updates where update.date > 0 {
      maxDate = max(maxDate, update.date)
    }
    return maxDate
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

  func updateLastSyncDate(maxAppliedDate: Int64, source: String) async {
    guard maxAppliedDate > 0 else { return }

    let gap = config.lastSyncSafetyGapSeconds
    let proposed = max(0, maxAppliedDate - gap)
    let currentState = await syncStorage.getState()

    guard proposed > currentState.lastSyncDate else {
      log.trace(
        "skipping lastSyncDate update from \(source): current=\(currentState.lastSyncDate), proposed=\(proposed)"
      )
      return
    }

    let newState = SyncState(lastSyncDate: proposed)
    let saved = await syncStorage.setState(newState)
    guard saved else {
      log.error(
        "failed to update lastSyncDate from \(currentState.lastSyncDate) to \(proposed) (source=\(source))"
      )
      return
    }
    stats.lastSyncDate = proposed
    log.debug(
      "updated lastSyncDate from \(currentState.lastSyncDate) to \(proposed) (maxAppliedDate=\(maxAppliedDate), gap=\(gap)s, source=\(source))"
    )
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
      case let .chatVisibility(payload):
        .chat(peer: .with { $0.chat = .with { $0.chatID = payload.chatID } })
      case let .chatInfo(payload):
        .chat(peer: .with { $0.chat = .with { $0.chatID = payload.chatID } })
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
  private var limit: Int
  private var inFlight: Int = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(limit: Int) {
    self.limit = max(1, limit)
  }

  func setLimit(_ newLimit: Int) {
    limit = max(1, newLimit)
    resumeWaitersIfPossible()
  }

  func acquire() async {
    if inFlight < limit {
      inFlight += 1
      return
    }

    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
    // Note: `release()` increments `inFlight` before resuming this continuation.
  }

  func release() {
    if inFlight > 0 {
      inFlight -= 1
    }
    resumeWaitersIfPossible()
  }

  private func resumeWaitersIfPossible() {
    while inFlight < limit, !waiters.isEmpty {
      inFlight += 1
      let continuation = waiters.removeFirst()
      continuation.resume()
    }
  }
}

// MARK: - BucketActor

/// Actor responsible for fetching and applying updates for a single bucket (chat, space, or user).
actor BucketActor {
  private var log = Log.scoped("RealtimeV2.Sync.BucketActor")

  private static let updatesPageLimit: Int32 = 200
  private static let maxTotalUpdates: Int64 = 1000
  private static let getUpdatesTimeout: Duration = .seconds(30)

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
  private var lastNonProgressRepairTargetSeq: Int64?

  /// Buffer to accumulate updates during fetch loop before applying them all at once
  private var pendingUpdates: [InlineProtocol.Update] = []
  private var pendingSidecars = InlineProtocol.UpdateSidecars()
  private var pendingSidecarUserIds = Set<Int64>()
  private var pendingSidecarChatIds = Set<Int64>()
  private var pendingSidecarDialogKeys = Set<String>()
  private var pendingSidecarSpaceIds = Set<Int64>()

  /// Buffer for out-of-order realtime updates. We only apply contiguous seqs starting at (seq + 1).
  private var bufferedRealtimeUpdates: [Int64: InlineProtocol.Update] = [:]

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

  /// Determines if an update should be processed based on its type during sync catch-up.
  ///
  /// We selectively apply only critical structure changes for now
  /// (membership, chat metadata, and other non-history state).
  private func shouldProcessUpdate(_ update: InlineProtocol.Update) -> Bool {
    switch update.update {
      case .spaceMemberDelete:
        true
      case .participantDelete:
        true
      case .chatVisibility:
        true
      case .chatInfo:
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
      case .newMessage, .editMessage, .messageAttachment:
        true
      case .chatSkipPts:
        true
      default:
        // Note: We explicitly skip other updates (like messages) during catch-up for now
        // to keep the initial implementation focused on structural consistency.
        // This implies we might have gaps in message history if we rely solely on sync,
        // but message history is typically fetched via separate APIs.
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

    // Buffer incoming updates
    for update in updates {
      guard update.hasSeq, update.seq > 0 else { continue }
      let incomingSeq = Int64(update.seq)
      // Skip duplicates/outdated updates.
      guard incomingSeq > seq else { continue }
      bufferedRealtimeUpdates[incomingSeq] = update
    }

    // If catch-up has already fetched a pending batch, defer realtime draining until
    // that batch is committed to preserve monotonic per-bucket apply order.
    if isFetching, !pendingUpdates.isEmpty {
      log.trace("deferring realtime drain for bucket \(key) while catch-up batch is pending")
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
      bufferedRealtimeUpdates = bufferedRealtimeUpdates.filter { $0.key > seq }
    }

    var contiguous: [InlineProtocol.Update] = []
    var nextSeq = seq
    var nextDate = date

    // Drain a contiguous run starting at the next expected seq.
    while let next = bufferedRealtimeUpdates[nextSeq + 1] {
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
    let result = await sync.applyUpdatesFromRealtime(contiguous)
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
    let toleratedFailure = result.failedCount > 0 &&
      (result.appliedCount > 0 || contiguous.count == 1)
    guard result.succeeded || toleratedFailure else {
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
    if toleratedFailure {
      PerformanceTrace.breadcrumb(
        "realtime drain apply failure tolerated",
        category: "sync.realtime",
        level: .warning,
        data: [
          "bucket": key.traceKind,
          "updates": contiguous.count,
          "applied": result.appliedCount,
          "failed": result.failedCount,
        ]
      )
      log.warning(
        "tolerating \(result.failedCount) realtime apply failure(s) for bucket \(key); advancing to seq=\(nextSeq)"
      )
    }

    for update in contiguous where update.hasSeq {
      bufferedRealtimeUpdates.removeValue(forKey: Int64(update.seq))
    }
    let saved = await sync.saveBucketState(for: key, seq: nextSeq, date: nextDate)
    guard saved else {
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

    seq = nextSeq
    date = nextDate
    let maxAppliedDate = maxUpdateDate(in: contiguous)
    await sync.updateLastSyncDate(maxAppliedDate: maxAppliedDate, source: "realtime:\(key)")
    return true
  }

  func fetchNewUpdates() async {
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

    await sync.bucketFetchActivityStarted()

    // If we had a scheduled retry, cancel it since we're actively attempting a fetch now.
    retryTask?.cancel()
    retryTask = nil

    var finishedWithoutRetry = true
    while true {
      needsFetch = false
      let ok = await fetchNewUpdatesOnce()
      if ok {
        resetRetryState()
      } else {
        finishedWithoutRetry = false
        scheduleRetry()
        break
      }

      // If we have buffered realtime updates, keep fetching until we've filled the gap.
      _ = await drainBufferedRealtimeUpdates()

      guard needsFetch || bufferedRealtimeUpdates.isEmpty == false else { break }
      log.trace("follow-up fetch requested for bucket \(key)")
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
    await sync.bucketFetchActivityEnded()
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
    var hardEndSeq: Int64? = fetchSeqEnd
    if let maxBuffered = bufferedRealtimeUpdates.keys.max() {
      hardEndSeq = max(hardEndSeq ?? 0, maxBuffered)
    }
    if let bound = hardEndSeq, bound <= currentSeq {
      // Avoid invalid requests (server requires seqEnd >= startSeq).
      hardEndSeq = nil
    }

    // When the server reports TOO_LONG, it returns a slice boundary seq. We temporarily use `sliceEndSeq`
    // to fetch up to that boundary, then restore `hardEndSeq` (if any) and continue.
    var sliceEndSeq: Int64? = nil

    // On a cold start (no seq/date), attempt a small catch-up instead of immediately fast-forwarding.
    // We cap the first request to avoid pulling large history. If a chat bucket reports TOO_LONG,
    // continue with bounded slices rather than marking stale history as caught up.
    let isColdStart = seq == 0 || date == 0
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
        await fetchLimiter.acquire()
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
        pageCount += 1

        guard case let .getUpdates(payload) = result else {
          log.error("failed to parse getUpdates result")
          resultLabel = "parse_failed"
          return false
        }

        let totalCount = payload.updates.count

        // Defensive guard: if the server reports non-final but does not advance seq,
        // we'd spin this loop forever and keep the sync actor busy.
        if !payload.final, payload.seq == currentSeq {
          let pointerSeq = max(hardEndSeq ?? 0, Int64(payload.seq))
          if totalCount == 0, payload.resultType == .empty, pendingUpdates.isEmpty {
            PerformanceTrace.breadcrumb(
              "sync bucket fetch trusted empty pointer",
              category: "sync.catchup",
              level: .warning,
              data: [
                "bucket": key.traceKind,
                "seq": payload.seq,
                "target_seq": pointerSeq,
              ]
            )
            if await trustServerPointer(
              targetSeq: pointerSeq,
              targetDate: payload.date,
              reason: "empty_non_progress"
            ) {
              resultLabel = "trusted_empty_pointer"
              return true
            }
            resultLabel = "empty_pointer_save_failed"
            return false
          }

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
          if await repairChatSnapshotIfNeeded(
            targetSeq: pointerSeq,
            targetDate: payload.date,
            reason: "non_progress",
            advanceCursor: true
          ) {
            resultLabel = "repaired_non_progress"
            return true
          }
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
            let repairedSeq = hardEndSeq ?? Int64(payload.seq)
            if await repairChatSnapshotIfNeeded(
              targetSeq: repairedSeq,
              targetDate: payload.date,
              reason: "cold_too_long",
              advanceCursor: true
            ) {
              resultLabel = "repaired_too_long"
              return true
            }
          }
          if isColdStart, shouldFastForwardColdTooLong {
            // On cold start, prefer fast-forwarding to a known upper bound (e.g. updateSeq from
            // chatHasNewUpdates). This prevents huge catch-up costs on first-run and avoids getting
            // stuck behind if the server only returns a slice boundary for TOO_LONG.
            finalSeq = hardEndSeq ?? payload.seq
            finalDate = payload.date
            isFinal = true // Stop fetching
            clearPendingCatchupBatch() // Discard pending
            break
          }

          // Slice within max total updates.
          // Note: keep `hardEndSeq` intact so we can continue slicing until we reach it.
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
            // Legacy server semantics: treat `payload.seq` as latestSeq and slice locally.
            hardEndSeq = max(hardEndSeq ?? 0, serverSeq)
            sliceEndSeq = min(serverSeq, currentSeq + Self.maxTotalUpdates)
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
          bufferedRealtimeUpdates.removeAll()
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
          let shouldProcess = shouldProcessUpdate(update)
          if !shouldProcess {
            log.trace("skipping update in bucket catch-up: \(String(describing: update.update))")
          }
          return shouldProcess
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
            "trusting getUpdates pointer ahead of delivered updates for bucket \(key) (deliveredSeq=\(maxDeliveredSeq), pointerSeq=\(payload.seq), total=\(totalCount), delivered=\(filteredUpdates.count))"
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

      // Apply all accumulated updates in one batch, ordered by seq
      var catchupAppliedSeqs = Set<Int64>()
      if !pendingUpdates.isEmpty {
        // Realtime draining is deferred while this batch is pending so we preserve
        // monotonic per-bucket ordering.
        let orderedUpdates = orderUpdatesBySeq(pendingUpdates)
        catchupAppliedSeqs = Set(orderedUpdates.compactMap { update in
          update.hasSeq ? Int64(update.seq) : nil
        })
        log.debug("applying \(orderedUpdates.count) updates for bucket \(key)")
        let applyStartedAt = Date()
        let applySpan = PerformanceTrace.begin(
          "SyncBucketApply",
          category: .sync,
          "bucket=\(key.traceKind) updates=\(orderedUpdates.count) sidecars=\(hasPendingSidecars)"
        )
        let result = await sync.applyUpdatesFromBucket(
          orderedUpdates,
          sidecars: hasPendingSidecars ? pendingSidecars : nil
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
            reason: "apply_failed",
            advanceCursor: true
          ) {
            resultLabel = "repaired_apply_failed"
            return true
          }
          resultLabel = "apply_failed"
          return false
        }
        maxAppliedDate = max(maxAppliedDate, maxUpdateDate(in: orderedUpdates))
        clearPendingCatchupBatch()
      }

      let bufferedMaxDate = await applyBufferedRealtimeUpdates(
        upTo: finalSeq,
        excluding: catchupAppliedSeqs,
        reason: "catchup_pointer"
      )
      maxAppliedDate = max(maxAppliedDate, bufferedMaxDate)

      if totalFetched > 0 || totalSkipped > 0 || totalDuplicateSkipped > 0 {
        await sync.recordBucketUpdatesApplied(
          applied: totalFetched,
          skipped: totalSkipped,
          duplicates: totalDuplicateSkipped
        )
      }

      // Update bucket state (never regress behind a newer realtime-applied seq).
      let committedSeq: Int64
      let committedDate: Int64
      if finalSeq > seq {
        committedSeq = finalSeq
        committedDate = max(max(date, finalDate), bufferedMaxDate)
      } else {
        committedSeq = seq
        committedDate = max(date, bufferedMaxDate)
      }
      let saved = await sync.saveBucketState(for: key, seq: committedSeq, date: committedDate)
      guard saved else {
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

      seq = committedSeq
      date = committedDate

      if maxAppliedDate > 0 {
        await sync.updateLastSyncDate(maxAppliedDate: maxAppliedDate, source: "bucket:\(key)")
      }

      if let fetchSeqEnd, committedSeq >= fetchSeqEnd {
        self.fetchSeqEnd = nil
      }

      log.debug(
        "completed fetch for bucket \(key): applied \(totalFetched) updates, skipped \(totalSkipped), new seq=\(committedSeq)"
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
        bufferedRealtimeUpdates.removeAll()
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
      !pendingSidecars.spaces.isEmpty
  }

  private func clearPendingCatchupBatch() {
    pendingUpdates.removeAll()
    pendingSidecars = InlineProtocol.UpdateSidecars()
    pendingSidecarUserIds.removeAll()
    pendingSidecarChatIds.removeAll()
    pendingSidecarDialogKeys.removeAll()
    pendingSidecarSpaceIds.removeAll()
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

    let normalized = errorCode
      .replacingOccurrences(of: "_", with: "")
      .lowercased()

    return normalized == "peeridinvalid"
      || normalized == "chatidinvalid"
      || normalized == "spaceidinvalid"
  }

  private func resetRetryState() {
    retryAttempt = 0
    retryTask?.cancel()
    retryTask = nil
  }

  private func scheduleRetry() {
    // Avoid scheduling multiple concurrent retries.
    guard retryTask == nil else { return }

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
      await self.fetchNewUpdates()
    }
  }

  private func clearRetryTask() {
    retryTask = nil
  }

  private var shouldFastForwardColdTooLong: Bool {
    switch key {
      case .chat:
        false
      case .space, .user:
        true
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
    reason: String,
    advanceCursor: Bool
  ) async -> Bool {
    guard case let .chat(peer) = key, let sync else { return false }
    guard targetSeq > seq else { return false }

    if !advanceCursor {
      guard lastNonProgressRepairTargetSeq != targetSeq else { return false }
      lastNonProgressRepairTargetSeq = targetSeq
    }

    let repaired = await sync.repairChatBucket(peer: peer, reason: reason)
    guard repaired else { return false }
    guard advanceCursor else { return true }

    let bufferedMaxDate = await applyBufferedRealtimeUpdates(upTo: targetSeq, reason: "repair:\(reason)")
    let committedDate = max(targetDate, bufferedMaxDate)
    let saved = await sync.saveBucketState(for: key, seq: targetSeq, date: committedDate)
    guard saved else {
      log.error("failed to save bucket state after chat repair for \(key): seq=\(targetSeq), date=\(committedDate)")
      return false
    }

    seq = targetSeq
    date = committedDate
    clearPendingCatchupBatch()
    bufferedRealtimeUpdates = bufferedRealtimeUpdates.filter { $0.key > targetSeq }
    if let fetchSeqEnd, targetSeq >= fetchSeqEnd {
      self.fetchSeqEnd = nil
    }
    if committedDate > 0 {
      await sync.updateLastSyncDate(maxAppliedDate: committedDate, source: "repair:\(key)")
    }
    return true
  }

  private func trustServerPointer(targetSeq: Int64, targetDate: Int64, reason: String) async -> Bool {
    guard let sync else { return false }
    guard targetSeq >= seq else { return false }

    let bufferedMaxDate = await applyBufferedRealtimeUpdates(upTo: targetSeq, reason: reason)
    let nextDate = targetDate > 0 ? max(date, targetDate) : date
    let committedDate = max(nextDate, bufferedMaxDate)
    guard targetSeq > seq || committedDate > date else {
      log.warning("trusting server pointer for bucket \(key) without local cursor change (seq=\(seq), reason=\(reason))")
      return true
    }

    let saved = await sync.saveBucketState(for: key, seq: targetSeq, date: committedDate)
    guard saved else {
      log.error("failed to save trusted server pointer for \(key): seq=\(targetSeq), date=\(committedDate)")
      return false
    }

    log.warning("trusting server pointer for bucket \(key): seq \(seq) -> \(targetSeq) (reason=\(reason))")
    seq = targetSeq
    date = committedDate
    clearPendingCatchupBatch()
    bufferedRealtimeUpdates = bufferedRealtimeUpdates.filter { $0.key > targetSeq }
    if let fetchSeqEnd, targetSeq >= fetchSeqEnd {
      self.fetchSeqEnd = nil
    }
    if committedDate > 0 {
      await sync.updateLastSyncDate(maxAppliedDate: committedDate, source: "pointer:\(key)")
    }
    return true
  }

  @discardableResult
  private func applyBufferedRealtimeUpdates(
    upTo targetSeq: Int64,
    excluding excludedSeqs: Set<Int64> = [],
    reason: String
  ) async -> Int64 {
    guard targetSeq > seq else { return 0 }
    guard let sync else {
      log.error("sync reference is nil, cannot apply buffered realtime updates")
      return 0
    }

    let entries = bufferedRealtimeUpdates
      .filter { seq, _ in
        seq > self.seq &&
          seq <= targetSeq &&
          !excludedSeqs.contains(seq)
      }
      .sorted { $0.key < $1.key }

    guard !entries.isEmpty else { return 0 }

    let updates = entries.map(\.value)
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
      log.warning(
        "tolerating \(result.failedCount) buffered realtime apply failure(s) for bucket \(key) while trusting pointer \(targetSeq) (reason=\(reason))"
      )
    }

    for (seq, _) in entries {
      bufferedRealtimeUpdates.removeValue(forKey: seq)
    }
    return maxUpdateDate(in: updates)
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
  func debugRewindState(seq: Int64, date: Int64) async {
    self.seq = seq
    self.date = date
    fetchSeqEnd = nil
    needsFetch = true
    await fetchNewUpdates()
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
