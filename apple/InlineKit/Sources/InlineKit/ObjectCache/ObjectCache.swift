import Combine
import Foundation
import GRDB
import Logger

/// Identifies one record the cache can hold.
public enum ObjectID: Hashable, Sendable {
  case user(Int64)
  case chat(Int64)
  case space(Int64)

  fileprivate var kind: ObjectKind {
    switch self {
      case .user: .user
      case .chat: .chat
      case .space: .space
    }
  }
}

/// Tunable bounds for `ObjectCache`. Adjust here; nothing else encodes these numbers.
enum ObjectCacheLimits {
  /// Records per kind that are re-read after every write to that kind's tables,
  /// most recently used first. Higher keeps more records fresh without being asked,
  /// at the cost of a larger batch read per write. Records past this limit are
  /// marked stale and re-read when next requested.
  static let tracked = 512

  /// Records of all kinds kept in memory. Past this, the least recently used are
  /// dropped until `memory * evictionKeepRatio` remain.
  static let memory = 4_096

  /// Share of `memory` kept by one eviction pass. Lower evicts less often but in bigger steps.
  static let evictionKeepRatio = 0.75
}

private enum ObjectKind: CaseIterable, Sendable {
  case user
  case chat
  case space

  /// Tables whose writes can change a record of this kind.
  var tables: [String] {
    switch self {
      case .user: [User.databaseTableName, File.databaseTableName]
      case .chat: [Chat.databaseTableName]
      case .space: [Space.databaseTableName]
    }
  }
}

private enum ObjectRecord: Equatable, Sendable {
  case user(UserInfo)
  case chat(Chat)
  case space(Space)
}

/// The answer to one cache request: immutable copies plus what the cache knows
/// about each requested ID, so a view can decide whether to wait for `changes`.
public struct ObjectSnapshot: Sendable {
  public enum State: Sendable, Equatable {
    /// Read from the database and kept current by the cache's table trackers.
    case fresh
    /// A previously read value. A revalidation is already scheduled.
    case stale
    /// The database has no such row.
    case missing
    /// Never read. Use `load` or `warm`, or `get` when the first frame needs it.
    case unloaded
  }

  fileprivate var records: [ObjectID: ObjectRecord] = [:]
  fileprivate var states: [ObjectID: State] = [:]

  public func user(_ id: Int64) -> UserInfo? {
    guard case let .user(value) = records[.user(id)] else { return nil }
    return value
  }

  public func chat(_ id: Int64) -> Chat? {
    guard case let .chat(value) = records[.chat(id)] else { return nil }
    return value
  }

  public func space(_ id: Int64) -> Space? {
    guard case let .space(value) = records[.space(id)] else { return nil }
    return value
  }

  public func state(of id: ObjectID) -> State {
    states[id] ?? .unloaded
  }
}

/// In-memory cache of users, chats and spaces for views.
///
/// Three ways in, all taking `[ObjectID]`:
/// - `get` answers now, reading unloaded IDs synchronously. For first-frame UI.
/// - `load` reads unloaded and stale IDs off the main thread. For everything else.
/// - `warm` starts a `load` and returns; a later `cached` or `get` then hits memory.
///
/// One tracker per kind watches that kind's tables. After a write, the most
/// recently used `trackedLimit` records of the kind are re-read in one batch and
/// stay fresh; the rest are marked stale and revalidate when next requested.
@MainActor
public final class ObjectCache {
  public static let shared = ObjectCache(database: .shared)

  /// IDs whose value changed, was first loaded, or was cleared.
  public let changes = PassthroughSubject<Set<ObjectID>, Never>()

  private struct Entry {
    /// nil when the database has no such row.
    var record: ObjectRecord?
    var isFresh: Bool
    /// Start order of the read that produced `record`; an older read never replaces a newer one.
    var readSequence: UInt64
    var lastUsed: UInt64
  }

  private let log = Log.scoped("ObjectCache", enableTracing: false)
  private let database: AppDatabase
  private let trackedLimit: Int
  private let memoryLimit: Int

  private var entries: [ObjectID: Entry] = [:]
  private var useClock: UInt64 = 0
  private var readSequence: UInt64 = 0
  /// Bumped by `clear`; reads started earlier are discarded.
  private var generation: UInt64 = 0
  /// Bumped on every tracked write; a read that straddles one is stored stale.
  private var writeEpochs: [ObjectKind: UInt64] = [:]

  private var trackers: [AnyDatabaseCancellable] = []
  private var trackedWriter: (any DatabaseWriter)?
  /// Identifies the current tracker start; a start that finishes after `stopTracking` is discarded.
  private var trackingAttempt: UInt64 = 0
  private(set) var trackerStart: Task<Void, Never>?
  private var kindsToRevalidate: Set<ObjectKind> = []
  private var idsToRevalidate: Set<ObjectID> = []
  private var revalidation: Task<Void, Never>?

  private var userPublishers: [Int64: PassthroughSubject<UserInfo?, Never>] = [:]
  private var chatPublishers: [Int64: PassthroughSubject<Chat?, Never>] = [:]

  init(
    database: AppDatabase,
    trackedLimit: Int = ObjectCacheLimits.tracked,
    memoryLimit: Int = ObjectCacheLimits.memory
  ) {
    self.database = database
    self.trackedLimit = trackedLimit
    self.memoryLimit = max(memoryLimit, trackedLimit)
  }

  // MARK: - Uniform API

  /// What is in memory right now. Never touches the database.
  public func cached(_ ids: [ObjectID]) -> ObjectSnapshot {
    snapshot(ids)
  }

  /// Answers now. Unloaded IDs are read synchronously in one batch; stale values
  /// are returned as they are and revalidated in the background.
  public func get(_ ids: [ObjectID]) -> ObjectSnapshot {
    ensureTracking()
    let unloaded = ids.filter { entries[$0] == nil }
    if !unloaded.isEmpty {
      let read = beginRead()
      do {
        let records = try database.reader.read { db in try Self.fetch(db, unloaded) }
        finishRead(read, ids: unloaded, records: records)
      } catch {
        log.error("Failed to read objects", error: error)
      }
    }
    revalidate(ids.filter { entries[$0]?.isFresh == false })
    return snapshot(ids)
  }

  /// Reads unloaded and stale IDs off the main thread, then answers.
  @discardableResult
  public func load(_ ids: [ObjectID]) async -> ObjectSnapshot {
    ensureTracking()
    let needed = ids.filter { entries[$0]?.isFresh != true }
    if !needed.isEmpty {
      await read(needed)
    }
    return snapshot(ids)
  }

  /// Starts loading without waiting, so a later `cached` or `get` hits memory.
  public func warm(_ ids: [ObjectID]) {
    guard ids.contains(where: { entries[$0]?.isFresh != true }) else { return }
    Task { await load(ids) }
  }

  public func clear() {
    BotAgentDirectory.shared.clear()
    stopTracking()
    generation &+= 1
    revalidation?.cancel()
    revalidation = nil
    kindsToRevalidate.removeAll()
    idsToRevalidate.removeAll()
    let cleared = Set(entries.keys)
    entries.removeAll()

    userPublishers.values.forEach { $0.send(nil) }
    chatPublishers.values.forEach { $0.send(nil) }
    userPublishers.removeAll()
    chatPublishers.removeAll()
    if !cleared.isEmpty {
      changes.send(cleared)
    }
  }

  // MARK: - Reads

  private struct ReadToken {
    let sequence: UInt64
    let generation: UInt64
    let writeEpochs: [ObjectKind: UInt64]
  }

  private func beginRead() -> ReadToken {
    readSequence &+= 1
    return ReadToken(sequence: readSequence, generation: generation, writeEpochs: writeEpochs)
  }

  private func read(_ ids: [ObjectID]) async {
    let token = beginRead()
    do {
      let records = try await database.reader.read { db in try Self.fetch(db, ids) }
      finishRead(token, ids: ids, records: records)
    } catch {
      log.error("Failed to load objects", error: error)
    }
  }

  private func finishRead(_ token: ReadToken, ids: [ObjectID], records: [ObjectID: ObjectRecord]) {
    guard token.generation == generation else { return }
    var changed: Set<ObjectID> = []
    var straddledWrite: [ObjectID] = []
    for id in ids {
      let existing = entries[id]
      if let existing, existing.readSequence > token.sequence { continue }
      let record = records[id]
      let isFresh = token.writeEpochs[id.kind] == writeEpochs[id.kind]
      if existing == nil || existing?.record != record {
        changed.insert(id)
      }
      entries[id] = Entry(
        record: record, isFresh: isFresh, readSequence: token.sequence,
        lastUsed: existing?.lastUsed ?? nextUse()
      )
      if !isFresh {
        straddledWrite.append(id)
      }
    }
    trimToMemoryLimit()
    revalidate(straddledWrite)
    publish(changed)
  }

  private nonisolated static func fetch(_ db: Database, _ ids: [ObjectID]) throws -> [ObjectID: ObjectRecord] {
    var userIDs: [Int64] = []
    var chatIDs: [Int64] = []
    var spaceIDs: [Int64] = []
    for id in ids {
      switch id {
        case let .user(id): userIDs.append(id)
        case let .chat(id): chatIDs.append(id)
        case let .space(id): spaceIDs.append(id)
      }
    }

    var records: [ObjectID: ObjectRecord] = [:]
    if !userIDs.isEmpty {
      let users = try User
        .filter(ids: userIDs)
        .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
        .asRequest(of: UserInfo.self)
        .fetchAll(db)
      for user in users {
        records[.user(user.id)] = .user(user)
      }
    }
    if !chatIDs.isEmpty {
      for chat in try Chat.fetchAll(db, ids: chatIDs) {
        records[.chat(chat.id)] = .chat(chat)
      }
    }
    if !spaceIDs.isEmpty {
      for space in try Space.fetchAll(db, ids: spaceIDs) {
        records[.space(space.id)] = .space(space)
      }
    }
    return records
  }

  private func snapshot(_ ids: [ObjectID]) -> ObjectSnapshot {
    var snapshot = ObjectSnapshot()
    for id in ids {
      guard var entry = entries[id] else { continue }
      entry.lastUsed = nextUse()
      entries[id] = entry
      if let record = entry.record {
        snapshot.records[id] = record
        snapshot.states[id] = entry.isFresh ? .fresh : .stale
      } else {
        snapshot.states[id] = entry.isFresh ? .missing : .stale
      }
    }
    return snapshot
  }

  private func nextUse() -> UInt64 {
    useClock &+= 1
    return useClock
  }

  private func trimToMemoryLimit() {
    guard entries.count > memoryLimit else { return }
    let excess = entries.count - Int(Double(memoryLimit) * ObjectCacheLimits.evictionKeepRatio)
    for (id, _) in entries.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }).prefix(excess) {
      entries.removeValue(forKey: id)
    }
  }

  private func publish(_ changed: Set<ObjectID>) {
    guard !changed.isEmpty else { return }
    for id in changed {
      switch id {
        case let .user(userID):
          guard let publisher = userPublishers[userID] else { continue }
          if case let .user(value) = entries[id]?.record { publisher.send(value) } else { publisher.send(nil) }
        case let .chat(chatID):
          guard let publisher = chatPublishers[chatID] else { continue }
          if case let .chat(value) = entries[id]?.record { publisher.send(value) } else { publisher.send(nil) }
        case .space:
          break
      }
    }
    changes.send(changed)
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
            Task { @MainActor in self?.tablesDidChange(kind) }
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
    // Writes made before the trackers attached went unseen, so everything read
    // in that gap is checked once, tracked or not.
    for kind in ObjectKind.allCases {
      tablesDidChange(kind)
    }
    revalidate(Array(entries.keys))
  }

  private func stopTracking() {
    trackingAttempt &+= 1
    trackers.forEach { $0.cancel() }
    trackers.removeAll()
    trackedWriter = nil
  }

  private func tablesDidChange(_ kind: ObjectKind) {
    guard trackedWriter != nil else { return }
    writeEpochs[kind, default: 0] &+= 1
    for (id, entry) in entries where id.kind == kind && entry.isFresh {
      entries[id]?.isFresh = false
    }
    kindsToRevalidate.insert(kind)
    startRevalidation()
  }

  private func revalidate(_ ids: [ObjectID]) {
    guard !ids.isEmpty else { return }
    idsToRevalidate.formUnion(ids)
    startRevalidation()
  }

  private func startRevalidation() {
    guard revalidation == nil else { return }
    let startedIn = generation
    revalidation = Task { [weak self] in
      // Writes that land during a read are picked up by the next pass, so a
      // burst of writes costs one extra read rather than one read per write.
      while let self, let ids = self.nextRevalidationBatch(generation: startedIn) {
        await self.read(ids)
      }
    }
  }

  private func nextRevalidationBatch(generation startedIn: UInt64) -> [ObjectID]? {
    guard startedIn == generation, !Task.isCancelled else { return nil }
    var ids = idsToRevalidate
    idsToRevalidate.removeAll()
    for kind in kindsToRevalidate {
      let tracked = entries
        .filter { $0.key.kind == kind }
        .sorted { $0.value.lastUsed > $1.value.lastUsed }
        .prefix(trackedLimit)
      ids.formUnion(tracked.map(\.key))
    }
    kindsToRevalidate.removeAll()
    ids = ids.filter { entries[$0]?.isFresh == false }
    guard !ids.isEmpty else {
      revalidation = nil
      return nil
    }
    return Array(ids)
  }
}

// MARK: - Conveniences

/// One-record forms of the core calls. They add no behavior of their own.
public extension ObjectCache {
  func cached(_ id: ObjectID) -> ObjectSnapshot {
    cached([id])
  }

  func get(_ id: ObjectID) -> ObjectSnapshot {
    get([id])
  }

  @discardableResult
  func load(_ id: ObjectID) async -> ObjectSnapshot {
    await load([id])
  }

  func warm(_ id: ObjectID) {
    warm([id])
  }

  func getCachedUser(id: Int64) -> UserInfo? {
    cached(.user(id)).user(id)
  }

  func getCachedChat(id: Int64) -> Chat? {
    cached(.chat(id)).chat(id)
  }

  func getCachedSpace(id: Int64) -> Space? {
    cached(.space(id)).space(id)
  }

  func getUser(id: Int64) -> UserInfo? {
    get(.user(id)).user(id)
  }

  func getChat(id: Int64) -> Chat? {
    get(.chat(id)).chat(id)
  }

  func getSpace(id: Int64) -> Space? {
    get(.space(id)).space(id)
  }

  func loadUser(id: Int64) async -> UserInfo? {
    await load(.user(id)).user(id)
  }

  func loadChat(id: Int64) async -> Chat? {
    await load(.chat(id)).chat(id)
  }

  func loadSpace(id: Int64) async -> Space? {
    await load(.space(id)).space(id)
  }

  /// Emits the user whenever it changes. Subscribing reads it synchronously if unloaded.
  func getUserPublisher(id: Int64) -> PassthroughSubject<UserInfo?, Never> {
    if let publisher = userPublishers[id] { return publisher }
    let publisher = PassthroughSubject<UserInfo?, Never>()
    userPublishers[id] = publisher
    _ = getUser(id: id)
    return publisher
  }

  /// Emits the chat whenever it changes. Subscribing reads it synchronously if unloaded.
  func getChatPublisher(id: Int64) -> PassthroughSubject<Chat?, Never> {
    if let publisher = chatPublishers[id] { return publisher }
    let publisher = PassthroughSubject<Chat?, Never>()
    chatPublishers[id] = publisher
    _ = getChat(id: id)
    return publisher
  }
}
