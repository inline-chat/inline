import InlineProtocol
import RealtimeV2

/// In-memory no-op sync storage for tests that do not exercise catch-up.
struct StubSyncStorage: SyncStorage {
  func canonicalPeer(forChatID chatID: Int64) async -> InlineProtocol.Peer? {
    .with { $0.chat.chatID = chatID }
  }

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
