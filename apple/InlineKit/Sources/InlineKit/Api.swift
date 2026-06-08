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
      transport: WebSocketTransport2(),
      auth: Auth.shared.handle,
      applyUpdates: InlineApplyUpdates(),
      syncStorage: GRDBSyncStorage(),
      persistenceHandler: DefaultTransactionPersistenceHandler(),
      blockerResolver: ChatTransactionBlockerResolver()
    )

    Task(priority: .utility) {
      guard Auth.shared.handle.token() != nil else { return }
      try? await ReservedChatIDPool.shared.refillIfNeeded(realtimeV2: realtime)
    }

    return realtime
  }()
}
