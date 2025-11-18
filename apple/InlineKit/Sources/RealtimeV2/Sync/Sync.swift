import InlineProtocol
import Logger

actor Sync {
  private var log = Log.scoped("RealtimeV2.Sync", level: .debug)

  private var applyUpdates: ApplyUpdates
  private var syncStorage: SyncStorage
  private weak var client: ProtocolClient?

  private var buckets: [BucketKey: BucketActor] = [:]

  init(applyUpdates: ApplyUpdates, syncStorage: SyncStorage, client: ProtocolClient) {
    self.applyUpdates = applyUpdates
    self.syncStorage = syncStorage
    self.client = client
  }

  // Process incoming updates
  func process(updates: [InlineProtocol.Update]) async {
    log.trace("applying \(updates.count) updates")

    // Which updates should be applied directly without bucket processing
    var applyingUpdates: [InlineProtocol.Update] = []

    for update in updates {
      switch update.update {
        case let .chatHasNewUpdates(payload):
          chatHasNewUpdates(payload)
          // No need to process this update further
          continue

        case let .spaceHasNewUpdates(payload):
          spaceHasNewUpdates(payload)
          // No need to process this update further
          continue

        default:
          // TODO: apply update to the bucket actor
          break
      }

      // Check for apply
      // if let bucketKey = getBucketKey(update: update), update.hasSeq, update.hasDate {
      // Register update in the bucket actor
      // let bucketActor = await getBucketActor(key: bucketKey)
      // bucketActor.add(update: update)
      // } else {
      // Apply update directly without order
      applyingUpdates.append(update)
      // }
    }

    // TODO: Check for "hasNewUpdates" updates to trigger the bucket actors to fetch new updates

    // Apply updates
    await applyUpdates.apply(updates: applyingUpdates)
  }

  func connectionStateChanged(state: RealtimeConnectionState) {
    log.trace("connection state changed to \(state)")

    switch state {
      case .connected:
        getStateFromServer()

      case .connecting:
        // TODO: pause the sync?
        break

      case .updating:
        // Note (@mo): Ignore this state for now, seems irrelevant and we may remove it from the connection state as
        // this is purely
        // for representational purposes in the UI.
        break
    }
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

  private func getBucketActor(key: BucketKey) async -> BucketActor {
    if let bucketActor = buckets[key] {
      return bucketActor
    }
    let bucketState = await syncStorage.getBucketState(for: key)
    let bucketActor = BucketActor(key: key, seq: bucketState.seq, date: bucketState.date, client: client)
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
      let state = await syncStorage.getState()

      // Note(@Mo): We call the client directly to skip the transaction system
      let _ = try await client.sendRpc(method: .getUpdatesState, input: .getUpdatesState(.with {
        $0.date = state.lastSyncDate
      }))
      log.trace("sent get updates state request with date: \(state.lastSyncDate)")
    }
  }

  /// MARK: - Helpers
  /// Get the bucket key for the update (chat, space, user)
  private func getBucketKey(update: InlineProtocol.Update) -> BucketKey? {
    switch update.update {
      case let .deleteMessages(payload):
        .chat(peer: payload.peerID)
      default:
        nil
    }
  }
}

enum BucketActorState: Sendable {
  case running
  case paused
}

actor BucketActor {
  private var log = Log.scoped("RealtimeV2.Sync.BucketActor", level: .debug)

  private weak var client: ProtocolClient?

  /// When it's set to true, the bucket state will be saved to the storage as buck from the Sync wrapper
  var needsSave: Bool = false

  var state: BucketActorState = .running
  var key: BucketKey
  var seq: Int64
  var date: Int64

  init(key: BucketKey, seq: Int64, date: Int64, client: ProtocolClient?) {
    self.key = key
    self.seq = seq
    self.date = date
    self.client = client
  }

  func fetchNewUpdates() async {
    // Fetch new updates for the bucket
    guard let client else {
      log.error("client is nil")
      return
    }

    do {
      let result = try await client.callRpc(method: .getUpdates, input: .getUpdates(.with {
        $0.bucket = key.toProtocolBucket()
        $0.startSeq = seq
      }))

      guard case let .getUpdates(payload) = result else {
        log.error("failed to parse getUpdates result")
        return
      }

      // Apply updates
      // if not final (payload.final) fetch next batch
      // update seq with (payload.seq) after applying
      // update date with (payload.date) after applying
      // run all these updates... payload.updates
    } catch {
      log.error("failed to fetch updates in bucket actor: \(error)")
    }
  }

  nonisolated func add(update: InlineProtocol.Update) {
    // add to ordered collection
    // start processing the update
    // or request gap filling?
  }

  /// Return true upon successful processing
  func process(update: InlineProtocol.Update) async -> Bool {
    log.trace("processing update")

    // update.seq
    // update.date

    // switch update.update {
    //   case let .deleteMessages(UpdateDeleteMessages):
    // }

    return true
  }
}
