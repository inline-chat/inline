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
/// to the app database: it reads records, and an `ObjectChangeTracker` on the
/// writer tells the store which records each commit wrote.
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

  private var tracker: ObjectChangeTracker?
  /// Rowid of each cached message, so a deleted or renumbered message row reaches the key it is cached under.
  private var messageIDsByRowID: [Int64: ObjectID] = [:]
  private var messageRowIDsByID: [ObjectID: Int64] = [:]
  /// Users holding each profile photo file, so a photo that moves to another user refreshes both.
  private var photoOwners: [String: Set<Int64>] = [:]
  private var photoIDsByUser: [Int64: Set<String>] = [:]
  private let memoryLimit: Int
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
    self.memoryLimit = memoryLimit
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
    OwnedBotsDirectory.shared.clear()
    MentionRosterRefresher.shared.clear()
    stopTracking()
    remoteLoader?.reset()
    store.reset()

    userPublishers.values.forEach { $0.send(nil) }
    chatPublishers.values.forEach { $0.send(nil) }
    userPublishers.removeAll()
    chatPublishers.removeAll()
    messageIDsByRowID.removeAll()
    messageRowIDsByID.removeAll()
    photoOwners.removeAll()
    photoIDsByUser.removeAll()
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
          trackPhotoIDs(of: userID)
          guard let publisher = userPublishers[userID] else { continue }
          if case let .user(value) = store.peek(id) { publisher.send(value) } else { publisher.send(nil) }
        case let .chat(chatID):
          guard let publisher = chatPublishers[chatID] else { continue }
          if case let .chat(value) = store.peek(id) { publisher.send(value) } else { publisher.send(nil) }
        case .message:
          trackMessageRowID(id)
        case .space:
          break
      }
    }
  }

  private func trackMessageRowID(_ id: ObjectID) {
    let rowID: Int64? = if case let .message(value) = store.peek(id) { value.globalId } else { nil }
    // A renumbered row can already map to another key; only drop this key's own mapping.
    if let old = messageRowIDsByID[id], old != rowID, messageIDsByRowID[old] == id {
      messageIDsByRowID.removeValue(forKey: old)
    }
    messageRowIDsByID[id] = rowID
    if let rowID { messageIDsByRowID[rowID] = id }
    // Evictions aren't announced; drop entries for records no longer in memory now and then.
    if messageRowIDsByID.count > 2 * memoryLimit {
      for (id, rowID) in messageRowIDsByID where store.peek(id) == nil {
        messageRowIDsByID.removeValue(forKey: id)
        if messageIDsByRowID[rowID] == id { messageIDsByRowID.removeValue(forKey: rowID) }
      }
    }
  }

  private func trackPhotoIDs(of userID: Int64) {
    let photos: Set<String> = if case let .user(value) = store.peek(.user(userID)) {
      Set(value.profilePhoto?.map(\.id) ?? [])
    } else {
      []
    }
    let old = photoIDsByUser[userID] ?? []
    for fileID in old.subtracting(photos) {
      photoOwners[fileID]?.remove(userID)
      if photoOwners[fileID]?.isEmpty == true { photoOwners.removeValue(forKey: fileID) }
    }
    for fileID in photos.subtracting(old) {
      photoOwners[fileID, default: []].insert(userID)
    }
    photoIDsByUser[userID] = photos.isEmpty ? nil : photos
    if photoIDsByUser.count > 2 * memoryLimit {
      for (userID, fileIDs) in photoIDsByUser where store.peek(.user(userID)) == nil {
        photoIDsByUser.removeValue(forKey: userID)
        for fileID in fileIDs {
          photoOwners[fileID]?.remove(userID)
          if photoOwners[fileID]?.isEmpty == true { photoOwners.removeValue(forKey: fileID) }
        }
      }
    }
  }

  // MARK: - Tracking

  /// Number of live database observers; constant however many records are cached.
  var trackerCount: Int {
    tracker == nil ? 0 : 1
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
    // Adding an observer waits for the writer, so it never runs on the main thread.
    trackerStart = Task.detached { [weak self] in
      let tracker = ObjectChangeTracker { changes in
        Task { @MainActor in self?.writesDidCommit(changes, attempt: attempt) }
      }
      // The writer holds observers weakly with this extent; the cache keeps it alive while tracking.
      writer.add(transactionObserver: tracker, extent: .observerLifetime)
      await self?.didStartTracker(tracker, attempt: attempt)
    }
  }

  private func didStartTracker(_ started: ObjectChangeTracker, attempt: UInt64) {
    guard attempt == trackingAttempt else { return }
    tracker = started
    // Writes made before the tracker attached went unseen.
    store.noteUnseenWrites()
  }

  private func writesDidCommit(_ changes: ObjectChanges, attempt: UInt64) {
    guard attempt == trackingAttempt else { return }
    var ids = changes.ids
    for rowID in changes.messageRowIDs {
      if let id = messageIDsByRowID[rowID] { ids.insert(id) }
    }
    for fileID in changes.fileIDs {
      for userID in photoOwners[fileID] ?? [] { ids.insert(.user(userID)) }
    }
    store.noteWrites(ids, touching: Array(changes.writtenKinds))
    for kind in changes.kinds {
      store.noteWrite(kind)
    }
  }

  private func stopTracking() {
    trackingAttempt &+= 1
    // Released, the observer stops: the writer holds it weakly.
    tracker = nil
    trackedWriter = nil
  }
}
