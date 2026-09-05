import Auth
import InlineProtocol
import RealtimeV2

// TODO: Replace with proper SyncStorage implementation using GRDB
struct StubSyncStorage: SyncStorage {
  func getState() async -> SyncState {
    SyncState(lastSyncDate: 0)
  }

  @discardableResult
  func setState(_ state: SyncState) async -> Bool {
    // TODO: Persist to database
    true
  }

  func getBucketState(for key: BucketKey) async -> BucketState {
    BucketState(date: 0, seq: 0)
  }

  @discardableResult
  func setBucketState(for key: BucketKey, state: BucketState) async -> Bool {
    // TODO: Persist to database
    true
  }

  func advanceBucketState(for key: BucketKey, state: BucketState) async -> BucketState? {
    state
  }

  @discardableResult
  func removeBucketState(for key: BucketKey) async -> Bool {
    // TODO: Persist to database
    true
  }

  @discardableResult
  func setBucketStates(states: [BucketKey: BucketState]) async -> Bool {
    // TODO: Persist to database in single transaction
    true
  }

  @discardableResult
  func clearSyncState() async -> Bool {
    // TODO: Persist to database
    true
  }
}

/// Wrapper
public enum Api {
  public static let realtime: RealtimeV2 = {
    let realtime = RealtimeV2(
      transport: NegotiatingRealtimeTransport(
        auth: Auth.shared.handle,
        rsaPublicKeys: InlineProtocolTrustRoots.production
      ),
      auth: Auth.shared.handle,
      applyUpdates: InlineApplyUpdates(),
      syncStorage: GRDBSyncStorage(),
      persistenceHandler: DefaultTransactionPersistenceHandler(),
      blockerResolver: ChatTransactionBlockerResolver(),
      storageIsReady: { AppDatabase.shared.isPersistent }
    )

    Task(priority: .utility) {
      guard Auth.shared.handle.isLoggedIn(), AppDatabase.shared.isPersistent else { return }
      await ReservedChatIDPool.shared.scheduleRefill(realtimeV2: realtime)
    }

    Task(priority: .utility) {
      // Keep consuming connection events while the import runs, so disconnect
      // cancels old work and rearms one attempt. Ordinary updating/connected
      // cycles must not rescan the database after every incoming message.
      var importTask: Task<Void, Never>?
      defer { importTask?.cancel() }
      for await state in await realtime.connectionStates() {
        guard !Task.isCancelled else { return }
        switch state {
        case .connecting:
          importTask?.cancel()
          importTask = nil
        case .connected:
          guard importTask == nil else { continue }
          importTask = Task(priority: .utility) {
            await DialogTranslationMigration.importPending(realtime: realtime)
          }
        case .updating:
          break
        }
      }
    }

    return realtime
  }()

  /// Opens the shared persistent-storage boundary for every account-scoped
  /// producer owned by InlineKit. This keeps sidecar database work from racing
  /// ahead of the realtime admission gate after an early-launch promotion.
  public static func admitPersistentStorage() async -> Bool {
    guard await realtime.admitPersistentStorage() else { return false }
    if Auth.shared.handle.isLoggedIn() {
      await ReservedChatIDPool.shared.resume(realtimeV2: realtime)
    }
    return true
  }
}
