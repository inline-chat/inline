import Foundation
import GRDB
import InlineProtocol
import RealtimeV2

// MARK: - Database Models

/// Database representation of a bucket state
struct DbBucketState: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "sync_bucket_state"

  let bucketType: Int
  let entityId: Int64
  var date: Int64
  var seq: Int64

  enum Columns {
    static let bucketType = Column(CodingKeys.bucketType)
    static let entityId = Column(CodingKeys.entityId)
    static let date = Column(CodingKeys.date)
    static let seq = Column(CodingKeys.seq)
  }
}

/// Database representation of the global sync state
struct DbGlobalSyncState: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "sync_global_state"

  // Singleton ID, always 1
  let id: Int64 = 1
  var lastSyncDate: Int64
}

/// Survives deletion of individual roots and cursors. Account token admission
/// separately fences database/account replacement.
enum SyncRemovalRevision {
  static func read(_ db: Database) throws -> Int64 {
    guard let revision = try Int64.fetchOne(db, sql: "SELECT revision FROM sync_removal_revision WHERE id = 1") else {
      throw DatabaseError(resultCode: .SQLITE_CORRUPT, message: "Missing sync removal revision")
    }
    return revision
  }

  static func advance(_ db: Database) throws {
    try db.execute(sql: "UPDATE sync_removal_revision SET revision = revision + 1 WHERE id = 1")
    guard db.changesCount == 1 else {
      throw DatabaseError(resultCode: .SQLITE_CORRUPT, message: "Missing sync removal revision")
    }
  }
}

// MARK: - Storage Implementation

public struct GRDBSyncStorage: SyncStorage {
  private let db: AppDatabase

  public init(db: AppDatabase = .shared) {
    self.db = db
  }

  public func getRemovalRevision() async throws -> Int64 {
    try await db.reader.read { try SyncRemovalRevision.read($0) }
  }

  public func getState() async throws -> SyncState {
    try await db.reader.read { db in
      if let state = try DbGlobalSyncState.fetchOne(db) {
        return SyncState(lastSyncDate: state.lastSyncDate)
      }
      return SyncState(lastSyncDate: 0)
    }
  }

  @discardableResult
  public func setState(_ state: SyncState) async -> Bool {
    do {
      try await db.dbWriter.write { db in
        let dbState = DbGlobalSyncState(lastSyncDate: state.lastSyncDate)
        try dbState.save(db)
      }
      return true
    } catch {
      AppDatabase.log.error("Failed to save global sync state: \(error)")
      return false
    }
  }

  public func getBucketState(for key: BucketKey) async throws -> BucketState {
    try await db.reader.read { db in
      if let state = try DbBucketState
        .filter(
          DbBucketState.Columns.bucketType == key.getBucket()
            && DbBucketState.Columns.entityId == key.getEntityId()
        )
        .fetchOne(db) {
        return BucketState(date: state.date, seq: state.seq)
      }
      return BucketState(date: 0, seq: 0)
    }
  }

  @discardableResult
  public func setBucketState(for key: BucketKey, state: BucketState) async -> Bool {
    do {
      try await db.dbWriter.write { db in
        let dbState = DbBucketState(
          bucketType: key.getBucket(),
          entityId: key.getEntityId(),
          date: state.date,
          seq: state.seq
        )
        try dbState.save(db)
      }
      return true
    } catch {
      AppDatabase.log.error("Failed to save bucket state for \(key): \(error)")
      return false
    }
  }

  public func advanceBucketState(for key: BucketKey, state: BucketState) async -> BucketState? {
    do {
      return try await db.dbWriter.write { database in
        try Self.advanceBucketState(for: key, state: state, in: database)
      }
    } catch {
      AppDatabase.log.error("Failed to advance bucket state for \(key): \(error)")
      return nil
    }
  }

  @discardableResult
  public func removeBucketState(for key: BucketKey) async -> Bool {
    do {
      try await db.dbWriter.write { db in
        _ = try DbBucketState
          .filter(
            DbBucketState.Columns.bucketType == key.getBucket()
              && DbBucketState.Columns.entityId == key.getEntityId()
          )
          .deleteAll(db)
      }
      return true
    } catch {
      AppDatabase.log.error("Failed to remove bucket state for \(key): \(error)")
      return false
    }
  }

  @discardableResult
  public func setBucketStates(states: [BucketKey: BucketState]) async -> Bool {
    do {
      try await db.dbWriter.write { db in
        for (key, state) in states {
          let existing = try DbBucketState
            .filter(
              DbBucketState.Columns.bucketType == key.getBucket()
                && DbBucketState.Columns.entityId == key.getEntityId()
            )
            .fetchOne(db)
          if let existing, existing.seq > state.seq {
            continue
          }
          let dbState = DbBucketState(
            bucketType: key.getBucket(),
            entityId: key.getEntityId(),
            date: max(existing?.date ?? 0, state.date),
            seq: state.seq
          )
          try dbState.save(db)
        }
      }
      return true
    } catch {
      AppDatabase.log.error("Failed to save bucket states batch: \(error)")
      return false
    }
  }

  @discardableResult
  public func clearSyncState() async -> Bool {
    do {
      try await db.dbWriter.write { db in
        _ = try DbBucketState.deleteAll(db)
        _ = try DbGlobalSyncState.deleteAll(db)
      }
      return true
    } catch {
      AppDatabase.log.error("Failed to clear sync state: \(error)")
      return false
    }
  }
}

extension GRDBSyncStorage {
  static func advanceBucketState(
    for key: BucketKey,
    state: BucketState,
    in database: Database
  ) throws -> BucketState {
    let existing = try DbBucketState
      .filter(
        DbBucketState.Columns.bucketType == key.getBucket()
          && DbBucketState.Columns.entityId == key.getEntityId()
      )
      .fetchOne(database)

    if let existing, existing.seq > state.seq {
      return BucketState(date: existing.date, seq: existing.seq)
    }

    let effectiveState = BucketState(
      date: max(existing?.date ?? 0, state.date),
      seq: state.seq
    )
    try DbBucketState(
      bucketType: key.getBucket(),
      entityId: key.getEntityId(),
      date: effectiveState.date,
      seq: effectiveState.seq
    ).save(database)
    return effectiveState
  }

  /// Seeds a resource cursor carried by an authoritative snapshot without ever
  /// moving an already-newer local cursor backwards.
  static func seedSnapshotBucketState(
    for key: BucketKey,
    seq: Int64,
    in database: Database
  ) throws -> BucketState {
    let existing = try DbBucketState
      .filter(
        DbBucketState.Columns.bucketType == key.getBucket()
          && DbBucketState.Columns.entityId == key.getEntityId()
      )
      .fetchOne(database)

    if let existing, seq <= existing.seq {
      return BucketState(date: existing.date, seq: existing.seq)
    }
    try DbBucketState(
      bucketType: key.getBucket(),
      entityId: key.getEntityId(),
      date: 0,
      seq: seq
    ).save(database)
    return BucketState(date: 0, seq: seq)
  }
}
