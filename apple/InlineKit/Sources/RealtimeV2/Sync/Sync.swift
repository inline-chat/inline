import Foundation
import InlineProtocol
import Logger

actor Sync {
  private var log = Log.scoped("RealtimeV2.Sync", level: .trace)

  private var applyUpdates: ApplyUpdates
  private var syncStorage: SyncStorage
  private weak var client: ProtocolClient?

  private var buckets: [BucketKey: BucketActor] = [:]

  init(applyUpdates: ApplyUpdates, syncStorage: SyncStorage, client: ProtocolClient) {
    self.applyUpdates = applyUpdates
    self.syncStorage = syncStorage
    self.client = client
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
    let bucketActor = BucketActor(key: key, seq: bucketState.seq, date: bucketState.date, client: client, sync: self)
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
        let _ = try await client.callRpc(method: .getUpdatesState, input: .getUpdatesState(.with {
          $0.date = state.lastSyncDate
        }))
        log.trace("sent get updates state request with date: \(state.lastSyncDate)")
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

  private func getBucketKey(for update: InlineProtocol.Update) -> BucketKey? {
    switch update.update {
      case let .newMessage(payload):
        return .chat(peer: payload.message.peerID)
      case let .editMessage(payload):
        return .chat(peer: payload.message.peerID)
      case let .deleteMessages(payload):
        return .chat(peer: payload.peerID)
      case let .messageAttachment(payload):
        return .chat(peer: payload.peerID)
      case let .updateReaction(payload):
        return .chat(peer: .with { $0.chat = .with { $0.chatID = payload.reaction.chatID } })
      case let .deleteReaction(payload):
        return .chat(peer: .with { $0.chat = .with { $0.chatID = payload.chatID } })

      case let .deleteChat(payload):
        return .chat(peer: payload.peerID)
      case let .markAsUnread(payload):
        return .chat(peer: payload.peerID)

      case let .spaceMemberAdd(payload):
        return .space(id: payload.member.spaceID)
      case let .spaceMemberDelete(payload):
        return .space(id: payload.spaceID)
      case let .joinSpace(payload):
        return .space(id: payload.space.id)

      case .updateUserStatus, .updateUserSettings, .newChat:
        return .user

      case let .participantAdd(payload):
        return .chat(peer: .with { $0.chat = .with { $0.chatID = payload.chatID } })
      case let .participantDelete(payload):
        return .chat(peer: .with { $0.chat = .with { $0.chatID = payload.chatID } })

      default:
        return nil
    }
  }
}

// MARK: - BucketActor

/// Actor responsible for fetching and applying updates for a single bucket (chat, space, or user).
actor BucketActor {
  private var log = Log.scoped("RealtimeV2.Sync.BucketActor", level: .debug)

  private weak var client: ProtocolClient?
  private weak var sync: Sync?

  var key: BucketKey
  var seq: Int64
  var date: Int64

  /// Prevents concurrent fetch operations
  private var isFetching: Bool = false

  /// Buffer to accumulate updates during fetch loop before applying them all at once
  private var pendingUpdates: [InlineProtocol.Update] = []

  init(key: BucketKey, seq: Int64, date: Int64, client: ProtocolClient?, sync: Sync?) {
    self.key = key
    self.seq = seq
    self.date = date
    self.client = client
    self.sync = sync
  }

  /// Determines if an update should be processed based on its type during sync catch-up.
  ///
  /// We selectively apply only critical structure changes for now:
  /// - spaceMemberDelete (User removed from space)
  /// - participantDelete (User removed from chat)
  private func shouldProcessUpdate(_ update: InlineProtocol.Update) -> Bool {
    switch update.update {
      case .spaceMemberDelete:
        true
      case .participantDelete:
        true
      case .deleteChat:
        true
      case .deleteMessages:
        true
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
    guard !isFetching else {
      log.trace("fetch already in progress for bucket \(key), skipping")
      return
    }

    guard let client else {
      log.error("client is nil, cannot fetch updates")
      return
    }

    guard let sync else {
      log.error("sync reference is nil, cannot persist state")
      return
    }

    isFetching = true
    pendingUpdates.removeAll()

    // Local state tracking for the loop
    var currentSeq = seq
    var finalSeq: Int64 = seq
    var finalDate: Int64 = date
    var totalFetched = 0
    var isFinal = false

    // On a cold start (no seq/date), attempt a small catch-up instead of immediately fast-forwarding.
    // We cap totalLimit to 50 to avoid pulling large history; if the server still reports TOO_LONG we
    // fall back to fast-forward behavior.
    let isColdStart = seq == 0 || date == 0
    let coldStartTotalLimit: Int32 = 50

    defer {
      isFetching = false
    }

    do {
      log.debug("starting fetch for bucket \(key) from seq \(seq)")

      // Fetch loop: accumulate all updates until final=true
      while !isFinal {
        let result = try await client.callRpc(method: .getUpdates, input: .getUpdates(.with {
          $0.bucket = key.toProtocolBucket()
          $0.startSeq = currentSeq
          if isColdStart {
            $0.totalLimit = coldStartTotalLimit
          }
        }))

        guard case let .getUpdates(payload) = result else {
          log.error("failed to parse getUpdates result")
          return
        }

        // Handle gaps (TOO_LONG)
        if payload.resultType == .tooLong {
          log.warning("getUpdates returned TOO_LONG for bucket \(key). Resetting to server state.")
          // We accept the gap and fast-forward.
          // TODO: In the future, we might want to clear local data for this bucket or attempt a more robust recovery.
          finalSeq = payload.seq
          finalDate = payload.date
          isFinal = true // Stop fetching
          pendingUpdates.removeAll() // Discard pending
          break
        }

        // Validate seq: if server seq is behind or equal to our local seq (and not TOO_LONG), something is wrong or
        // it's a dupe
        if payload.seq < currentSeq {
          log.warning("server seq (\(payload.seq)) < local seq (\(currentSeq)), skipping fetch for bucket \(key)")
          return
        }

        // Filter and accumulate updates
        let filteredUpdates = payload.updates.filter { update in
          // Skip duplicates
          if update.hasSeq, update.seq <= self.seq {
            log.trace("skipping duplicate update with seq \(update.seq)")
            return false
          }

          // Filter by supported types
          return shouldProcessUpdate(update)
        }

        pendingUpdates.append(contentsOf: filteredUpdates)
        totalFetched += filteredUpdates.count

        // Update loop variables
        currentSeq = payload.seq
        finalSeq = payload.seq
        finalDate = payload.date
        isFinal = payload.final
      }

      // Apply all accumulated updates in one batch
      if !pendingUpdates.isEmpty {
        log.debug("applying \(pendingUpdates.count) updates for bucket \(key)")
        await sync.applyUpdatesFromBucket(pendingUpdates)
      }

      // Update bucket state
      seq = finalSeq
      date = finalDate

      // Persist state to storage
      await sync.saveBucketState(for: key, seq: finalSeq, date: finalDate)

      log.debug("completed fetch for bucket \(key): applied \(totalFetched) updates, new seq=\(finalSeq)")

    } catch {
      log.error("failed to fetch updates for bucket \(key): \(error)")
      // We exit; next sync attempt will retry from the last saved seq
    }
  }

  /// Update state from external source (e.g. realtime updates)
  func updateState(seq: Int64, date: Int64) {
    if seq > self.seq {
      self.seq = seq
      self.date = date
      log.trace("updated state for bucket \(key) to seq=\(seq), date=\(date)")
    }
  }
}
