import Auth
import InlineProtocol
import RealtimeV2

// TODO: Replace with proper SyncStorage implementation using GRDB
struct StubSyncStorage: SyncStorage {
  func getState() async -> SyncState {
    SyncState(lastSyncDate: 0)
  }

  func setState(_ state: SyncState) async {
    // TODO: Persist to database
  }

  func getBucketState(for key: BucketKey) async -> BucketState {
    BucketState(date: 0, seq: 0)
  }

  func setBucketState(for key: BucketKey, state: BucketState) async {
    // TODO: Persist to database
  }

  func setBucketStates(states: [BucketKey: BucketState]) async {
    // TODO: Persist to database in single transaction
  }

  func clearSyncState() async {
    // TODO: Persist to database
  }
}

/// Wrapper
public enum Api {
  public static let realtime = RealtimeV2(
    transport: WebSocketTransport2(),
    auth: Auth.shared,
    applyUpdates: InlineApplyUpdates(),
    syncStorage: GRDBSyncStorage(),
    persistenceHandler: DefaultTransactionPersistenceHandler()
  )
}
