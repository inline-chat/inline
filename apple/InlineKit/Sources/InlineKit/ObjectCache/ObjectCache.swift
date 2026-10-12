import Combine
import Foundation
import GRDB
import InlineObjectCache
import Logger

/// In-memory cache of users, chats, spaces and messages for views.
///
/// Three ways in, all taking `[ObjectID]`:
/// - `get` answers now, reading unloaded IDs synchronously. For first-frame UI.
/// - `load` reads unloaded and stale IDs off the main thread. For everything else.
/// - `warm` starts a `load` and returns; a later `cached` or `get` then hits memory.
///
/// `ensure` goes one step further and asks the server for records the database
/// does not have, through `remoteLoader`.
///
/// The cache itself is `ObjectStore` from `InlineObjectCache`; this type binds it
/// to the app database: it reads records, and runs one tracker per kind that
/// tells the store when that kind's tables were written.
@MainActor
public final class ObjectCache {
  public static let shared: ObjectCache = {
    let cache = ObjectCache(database: .shared)
    cache.remoteLoader = ObjectRemoteLoader { await ObjectRemoteFetcher.fetch($0) }
    return cache
  }()

  /// IDs whose value changed, was first loaded, or was cleared.
  public var changes: PassthroughSubject<Set<ObjectID>, Never> {
    store.changes
  }

  /// Fetches records the database lacks. Nil means `ensure` only loads locally.
  public var remoteLoader: ObjectRemoteLoader<ObjectID>?

  private let database: AppDatabase
  let store: ObjectStore<DatabaseObjectSource>

  private var trackers: [AnyDatabaseCancellable] = []
  private var trackedWriter: (any DatabaseWriter)?
  /// Identifies the current tracker start; a start that finishes after `stopTracking` is discarded.
  private var trackingAttempt: UInt64 = 0
  private(set) var trackerStart: Task<Void, Never>?

  var userPublishers: [Int64: PassthroughSubject<UserInfo?, Never>] = [:]
  var chatPublishers: [Int64: PassthroughSubject<Chat?, Never>] = [:]
  private var publisherFeed: AnyCancellable?

  init(
    database: AppDatabase,
    trackedLimit: (@Sendable (ObjectKind) -> Int)? = nil,
    memoryLimit: Int = ObjectCacheLimits.memory
  ) {
    self.database = database
    store = ObjectStore(
      source: DatabaseObjectSource(database: database),
      limits: ObjectStoreLimits(
        tracked: trackedLimit ?? ObjectCacheLimits.tracked,
        memory: memoryLimit,
        evictionKeepRatio: ObjectCacheLimits.evictionKeepRatio
      ),
      onError: { Log.shared.error("Object cache read failed", error: $0) }
    )
    publisherFeed = store.changes.sink { [weak self] in self?.feedPublishers($0) }
  }

  // MARK: - Uniform API

  /// What is in memory right now. Never reads synchronously; stale values are
  /// returned as they are and revalidated in the background.
  public func cached(_ ids: [ObjectID]) -> ObjectSnapshot {
    store.cached(ids)
  }

  /// Answers now. Unloaded IDs are read synchronously in one batch; stale values
  /// are returned as they are and revalidated in the background.
  public func get(_ ids: [ObjectID]) -> ObjectSnapshot {
    ensureTracking()
    return store.get(ids)
  }

  /// Reads unloaded and stale IDs off the main thread, then answers.
  @discardableResult
  public func load(_ ids: [ObjectID]) async -> ObjectSnapshot {
    ensureTracking()
    return await store.load(ids)
  }

  /// Starts loading without waiting, so a later `cached` or `get` hits memory.
  public func warm(_ ids: [ObjectID]) {
    ensureTracking()
    store.warm(ids)
  }

  /// Loads `ids`, asks the server for those the database lacks or holds only as
  /// placeholders, then answers with whatever is local afterwards.
  @discardableResult
  public func ensure(_ ids: [ObjectID]) async -> ObjectSnapshot {
    let local = await load(ids)
    guard let remoteLoader else { return local }
    let incomplete = ids.filter { Self.needsRemote($0, in: local) }
    guard !incomplete.isEmpty else { return local }
    await remoteLoader.ensure(incomplete)
    return await load(ids)
  }

  public func clear() {
    BotAgentDirectory.shared.clear()
    stopTracking()
    remoteLoader?.reset()
    store.reset()

    userPublishers.values.forEach { $0.send(nil) }
    chatPublishers.values.forEach { $0.send(nil) }
    userPublishers.removeAll()
    chatPublishers.removeAll()
  }

  /// A record is incomplete when the database has no row, or has only the
  /// nameless placeholder user row that saving a message creates for an unknown sender.
  static func needsRemote(_ id: ObjectID, in snapshot: ObjectSnapshot) -> Bool {
    guard let record = snapshot.record(id) else { return snapshot.state(of: id) != .unloaded }
    guard case let .user(info) = record else { return false }
    return info.user.needsDisplayNameFetch
  }

  private func feedPublishers(_ changed: Set<ObjectID>) {
    for id in changed {
      switch id {
        case let .user(userID):
          guard let publisher = userPublishers[userID] else { continue }
          if case let .user(value) = store.peek(id) { publisher.send(value) } else { publisher.send(nil) }
        case let .chat(chatID):
          guard let publisher = chatPublishers[chatID] else { continue }
          if case let .chat(value) = store.peek(id) { publisher.send(value) } else { publisher.send(nil) }
        case .space, .message:
          break
      }
    }
  }

  // MARK: - Tracking

  /// Number of live database observations; constant however many records are cached.
  var trackerCount: Int {
    trackers.count
  }

  private func ensureTracking() {
    let writer = database.dbWriter
    if let trackedWriter, trackedWriter === writer { return }
    if trackedWriter != nil {
      // The database was replaced under us; nothing cached describes the new one.
      clear()
    }
    trackedWriter = writer
    trackingAttempt &+= 1
    let attempt = trackingAttempt
    // Starting an observation waits for the writer, so it never runs on the main thread.
    trackerStart = Task.detached { [weak self] in
      let started = ObjectKind.allCases.map { kind in
        DatabaseRegionObservation(tracking: kind.tables.map { Table($0) })
          .start(in: writer, onError: { error in
            Log.shared.error("Object tracker failed", error: error)
          }, onChange: { _ in
            Task { @MainActor in self?.tablesDidChange(kind, attempt: attempt) }
          })
      }
      await self?.didStartTrackers(started, attempt: attempt)
    }
  }

  private func didStartTrackers(_ started: [AnyDatabaseCancellable], attempt: UInt64) {
    guard attempt == trackingAttempt else {
      started.forEach { $0.cancel() }
      return
    }
    trackers = started
    // Writes made before the trackers attached went unseen.
    store.noteUnseenWrites()
  }

  private func tablesDidChange(_ kind: ObjectKind, attempt: UInt64) {
    guard attempt == trackingAttempt else { return }
    store.noteWrite(kind)
  }

  private func stopTracking() {
    trackingAttempt &+= 1
    trackers.forEach { $0.cancel() }
    trackers.removeAll()
    trackedWriter = nil
  }
}
