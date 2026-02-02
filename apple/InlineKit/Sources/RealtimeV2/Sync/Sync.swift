import Foundation
import InlineProtocol
import Logger

public struct SyncConfig: Sendable {
  public var enableMessageUpdates: Bool
  public var lastSyncSafetyGapSeconds: Int64

  public init(enableMessageUpdates: Bool, lastSyncSafetyGapSeconds: Int64) {
    self.enableMessageUpdates = enableMessageUpdates
    self.lastSyncSafetyGapSeconds = lastSyncSafetyGapSeconds
  }

  public static let `default` = SyncConfig(enableMessageUpdates: false, lastSyncSafetyGapSeconds: 15)
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

actor Sync {
  private var log = Log.scoped("RealtimeV2.Sync", level: .trace)

  private var applyUpdates: ApplyUpdates
  private var syncStorage: SyncStorage
  private weak var client: ProtocolClientType?
  private var config: SyncConfig
  private var stats: SyncStats = .empty

  private var buckets: [BucketKey: BucketActor] = [:]

  init(applyUpdates: ApplyUpdates, syncStorage: SyncStorage, client: ProtocolClientType, config: SyncConfig) {
    self.applyUpdates = applyUpdates
    self.syncStorage = syncStorage
    self.client = client
    self.config = config
  }

  // MARK: - Public API

  /// Process incoming updates (pushed from server)
  func process(updates: [InlineProtocol.Update]) async {
    log.trace("applying \(updates.count) updates")

    var applyingUpdates: [InlineProtocol.Update] = []

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
          // All other updates are applied directly for now.
          // TODO: In the future, we should queue these updates into BucketActors
          // to ensure strict ordering with fetched history.
          applyingUpdates.append(update)
      }
    }

    // Apply the direct updates
    if !applyingUpdates.isEmpty {
      await applyUpdates.apply(updates: applyingUpdates)
      recordDirectApply(count: applyingUpdates.count)
      let maxAppliedDate = maxUpdateDate(in: applyingUpdates)
      await updateLastSyncDate(maxAppliedDate: maxAppliedDate, source: "direct")
      // Update bucket states based on applied updates
      await updateBucketStates(for: applyingUpdates)
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

  /// Save bucket state to storage after successful update application
  func saveBucketState(for key: BucketKey, seq: Int64, date: Int64) async {
    log.trace("saving bucket state for \(key): seq=\(seq), date=\(date)")
    await syncStorage.setBucketState(for: key, state: BucketState(date: date, seq: seq))
  }

  /// Apply updates from bucket actor
  func applyUpdatesFromBucket(_ updates: [InlineProtocol.Update]) async {
    await applyUpdates.apply(updates: updates)
  }

  func updateConfig(_ config: SyncConfig) async {
    self.config = config
    for (_, actor) in buckets {
      await actor.updateConfig(config)
    }
    log.debug("updated sync config: enableMessageUpdates=\(config.enableMessageUpdates), gap=\(config.lastSyncSafetyGapSeconds)s")
  }

  func clearSyncState() async {
    log.debug("clearing sync state and bucket cache")
    stats = .empty
    buckets.removeAll()
    await syncStorage.clearSyncState()
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

  // MARK: - Private Helpers

  private func chatHasNewUpdates(_ payload: InlineProtocol.UpdateChatHasNewUpdates) {
    log.trace("chat has new updates: \(payload)")
    Task {
      let bucketActor = await getBucketActor(key: .chat(peer: payload.peerID))
      await bucketActor.fetchNewUpdates()
    }
  }

  private func spaceHasNewUpdates(_ payload: InlineProtocol.UpdateSpaceHasNewUpdates) {
    log.trace("space has new updates: \(payload)")
    Task {
      let bucketActor = await getBucketActor(key: .space(id: payload.spaceID))
      await bucketActor.fetchNewUpdates()
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
      enableMessageUpdates: config.enableMessageUpdates
    )
    buckets[key] = bucketActor
    return bucketActor
  }

  /// Get the state from the server
  private func getStateFromServer() {
    Task {
      guard let client else {
        log.error("client is nil")
        return
      }
      var state = await syncStorage.getState()

      // Handle uninitialized or too old state
      let now = Int64(Date().timeIntervalSince1970)
      // 14 days in seconds
      let maxSyncAge: Int64 = 14 * 24 * 60 * 60

      if state.lastSyncDate == 0 {
        // Temporary rollout safety: when sync state is missing, ask the server for the past 5 days so
        // we re-trigger buckets that may have changed while clients upgrade. Once all clients run the
        // new sync engine we can narrow or remove this lookback window.
        let fiveDays: Int64 = 5 * 24 * 60 * 60
        let seedDate = max(0, now - fiveDays)
        log.info("Sync state uninitialized (date=0). Seeding lookback to \(seedDate) (5 days ago)")
        state = SyncState(lastSyncDate: seedDate)
        await syncStorage.setState(state)
      } else if now - state.lastSyncDate > maxSyncAge {
        log.warning("Sync state too old (> 14 days). Resetting to now: \(now)")
        // TODO: We should clear the client cache and refetch everything here because
        // we might have missed too many updates and the gap is too large to sync reliably
        // or efficiently. For now, we just reset the cursor to avoid a massive fetch storm.
        state = SyncState(lastSyncDate: now)
        await syncStorage.setState(state)
      }

      do {
        // Note: We use callRpc to ensure we wait for the server's acknowledgement,
        // but the primary mechanism for sync is the server pushing 'hasNewUpdates'
        // events in response to this call (or as part of the result).
        let result = try await client.callRpc(method: .getUpdatesState, input: .getUpdatesState(.with {
          $0.date = state.lastSyncDate
        }), timeout: nil)
        log.trace("sent get updates state request with date: \(state.lastSyncDate)")
        if case let .getUpdatesState(payload) = result {
          await updateLastSyncDate(maxAppliedDate: payload.date, source: "getUpdatesState")
        }
      } catch {
        log.error("failed to get updates state: \(error)")
      }
    }
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
      // Prepare for batch storage update
      statesToSave[key] = BucketState(date: state.date, seq: state.seq)

      // Also update in-memory BucketActor if it exists
      if let actor = buckets[key] {
        await actor.updateState(seq: state.seq, date: state.date)
      }
    }

    if !statesToSave.isEmpty {
      log.trace("saving batch bucket states: \(statesToSave.count)")
      await syncStorage.setBucketStates(states: statesToSave)
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
    await syncStorage.setState(newState)
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
      case let .joinSpace(payload):
        .space(id: payload.space.id)
      case .updateUserStatus, .updateUserSettings, .newChat, .dialogArchived:
        .user
      case let .participantAdd(payload):
        .chat(peer: .with { $0.chat = .with { $0.chatID = payload.chatID } })
      case let .participantDelete(payload):
        .chat(peer: .with { $0.chat = .with { $0.chatID = payload.chatID } })
      case let .chatVisibility(payload):
        .chat(peer: .with { $0.chat = .with { $0.chatID = payload.chatID } })
      case let .pinnedMessages(payload):
        .chat(peer: payload.peerID)
      default:
        nil
    }
  }
}

// MARK: - BucketActor

/// Actor responsible for fetching and applying updates for a single bucket (chat, space, or user).
actor BucketActor {
  private var log = Log.scoped("RealtimeV2.Sync.BucketActor", level: .debug)

  private static let maxTotalUpdates: Int64 = 1000

  private weak var client: ProtocolClientType?
  private weak var sync: Sync?

  var key: BucketKey
  var seq: Int64
  var date: Int64
  private var enableMessageUpdates: Bool

  /// Prevents concurrent fetch operations
  private var isFetching: Bool = false
  private var needsFetch: Bool = false

  /// Buffer to accumulate updates during fetch loop before applying them all at once
  private var pendingUpdates: [InlineProtocol.Update] = []

  init(
    key: BucketKey,
    seq: Int64,
    date: Int64,
    client: ProtocolClientType?,
    sync: Sync?,
    enableMessageUpdates: Bool
  ) {
    self.key = key
    self.seq = seq
    self.date = date
    self.client = client
    self.sync = sync
    self.enableMessageUpdates = enableMessageUpdates
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
      case .spaceMemberUpdate:
        true
      case .spaceMemberAdd:
        true
      case .dialogArchived:
        true
      case .pinnedMessages:
        true
      case .newMessage, .editMessage, .messageAttachment:
        enableMessageUpdates
      default:
        // Note: We explicitly skip other updates (like messages) during catch-up for now
        // to keep the initial implementation focused on structural consistency.
        // This implies we might have gaps in message history if we rely solely on sync,
        // but message history is typically fetched via separate APIs.
        false
    }
  }

  func fetchNewUpdates() async {
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

    while true {
      needsFetch = false
      await fetchNewUpdatesOnce()
      guard needsFetch else { break }
      log.trace("follow-up fetch requested for bucket \(key)")
    }
  }

  private func fetchNewUpdatesOnce() async {
    guard let client else {
      log.error("client is nil, cannot fetch updates")
      return
    }

    guard let sync else {
      log.error("sync reference is nil, cannot persist state")
      return
    }

    await sync.recordBucketFetchStart()

    pendingUpdates.removeAll()

    // Local state tracking for the loop
    var currentSeq = seq
    var finalSeq: Int64 = seq
    var finalDate: Int64 = date
    var totalFetched = 0
    var totalSkipped = 0
    var totalDuplicateSkipped = 0
    var isFinal = false
    var sliceEndSeq: Int64? = nil

    // On a cold start (no seq/date), attempt a small catch-up instead of immediately fast-forwarding.
    // We cap totalLimit to 50 to avoid pulling large history; if the server still reports TOO_LONG we
    // fall back to fast-forward behavior.
    let isColdStart = seq == 0 || date == 0
    let coldStartTotalLimit: Int32 = 50

    do {
      log.debug("starting fetch for bucket \(key) from seq \(seq)")

      // Fetch loop: accumulate all updates until final=true
      while !isFinal {
        log.debug("getUpdates request bucket \(key) startSeq=\(currentSeq) coldStart=\(isColdStart)")
        let result = try await client.callRpc(method: .getUpdates, input: .getUpdates(.with {
          $0.bucket = key.toProtocolBucket()
          $0.startSeq = currentSeq
          if isColdStart {
            $0.totalLimit = coldStartTotalLimit
          } else if sliceEndSeq != nil {
            $0.totalLimit = Int32(Self.maxTotalUpdates)
          }
          if let sliceEndSeq {
            $0.seqEnd = sliceEndSeq
          }
        }), timeout: nil)

        guard case let .getUpdates(payload) = result else {
          log.error("failed to parse getUpdates result")
          return
        }

        let totalCount = payload.updates.count

        // Handle gaps (TOO_LONG)
        if payload.resultType == .tooLong {
          log.warning(
            "getUpdates TOO_LONG for bucket \(key) (startSeq=\(currentSeq), seq=\(payload.seq), date=\(payload.date))"
          )
          await sync.recordBucketFetchTooLong()
          let seqGap = Int64(payload.seq) - currentSeq
          if isColdStart {
            // On cold start, fast-forward immediately to avoid a TOO_LONG loop.
            finalSeq = payload.seq
            finalDate = payload.date
            isFinal = true // Stop fetching
            pendingUpdates.removeAll() // Discard pending
            break
          }
          if seqGap > Self.maxTotalUpdates {
            // We accept the gap and fast-forward.
            // TODO: For chat buckets, clear cached history and refetch to avoid gaps.
            finalSeq = payload.seq
            finalDate = payload.date
            isFinal = true // Stop fetching
            pendingUpdates.removeAll() // Discard pending
            break
          }

          // Slice within max total updates.
          sliceEndSeq = payload.seq
          continue
        }

        // Validate seq: if server seq is behind or equal to our local seq (and not TOO_LONG), something is wrong or
        // it's a dupe
        if payload.seq < currentSeq {
          log.warning(
            "server seq (\(payload.seq)) < local seq (\(currentSeq)), skipping fetch for bucket \(key)"
          )
          return
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
            log.trace("skipping update in bucket catch-up: \(update.update)")
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

        pendingUpdates.append(contentsOf: filteredUpdates)
        totalFetched += filteredUpdates.count

        // Update loop variables
        currentSeq = payload.seq
        finalSeq = payload.seq
        finalDate = payload.date
        isFinal = payload.final
      }

      // Apply all accumulated updates in one batch, ordered by seq
      if !pendingUpdates.isEmpty {
        // TODO: Ensure ordering between catch-up batches and realtime updates for the same bucket.
        let orderedUpdates = orderUpdatesBySeq(pendingUpdates)
        log.debug("applying \(orderedUpdates.count) updates for bucket \(key)")
        await sync.applyUpdatesFromBucket(orderedUpdates)
        let maxAppliedDate = maxUpdateDate(in: orderedUpdates)
        await sync.updateLastSyncDate(maxAppliedDate: maxAppliedDate, source: "bucket:\(key)")
      }
      if totalFetched > 0 || totalSkipped > 0 || totalDuplicateSkipped > 0 {
        await sync.recordBucketUpdatesApplied(
          applied: totalFetched,
          skipped: totalSkipped,
          duplicates: totalDuplicateSkipped
        )
      }

      // Update bucket state
      seq = finalSeq
      date = finalDate

      // Persist state to storage
      await sync.saveBucketState(for: key, seq: finalSeq, date: finalDate)

      log.debug(
        "completed fetch for bucket \(key): applied \(totalFetched) updates, skipped \(totalSkipped), new seq=\(finalSeq)"
      )

    } catch {
      log.error("failed to fetch updates for bucket \(key): \(error)")
      await sync.recordBucketFetchFailure()
      // We exit; next sync attempt will retry from the last saved seq
    }
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

  func updateConfig(_ config: SyncConfig) {
    enableMessageUpdates = config.enableMessageUpdates
  }

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
