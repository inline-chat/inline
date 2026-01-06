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

// MARK: - Storage Implementation

public struct GRDBSyncStorage: SyncStorage {
  private let db: AppDatabase

  public init(db: AppDatabase = .shared) {
    self.db = db
  }

  public func getState() async -> SyncState {
    do {
      return try await db.reader.read { db in
        if let state = try DbGlobalSyncState.fetchOne(db) {
          return SyncState(lastSyncDate: state.lastSyncDate)
        }
        return SyncState(lastSyncDate: 0)
      }
    } catch {
      AppDatabase.log.error("Failed to fetch global sync state: \(error)")
      return SyncState(lastSyncDate: 0)
    }
  }

  public func setState(_ state: SyncState) async {
    do {
      try await db.dbWriter.write { db in
        let dbState = DbGlobalSyncState(lastSyncDate: state.lastSyncDate)
        try dbState.save(db)
      }
    } catch {
      AppDatabase.log.error("Failed to save global sync state: \(error)")
    }
  }

  public func getBucketState(for key: BucketKey) async -> BucketState {
    do {
      return try await db.reader.read { db in
        if let state = try DbBucketState
          .filter(
            DbBucketState.Columns.bucketType == key.getBucket()
              && DbBucketState.Columns.entityId == key.getEntityId()
          )
          .fetchOne(db)
        {
          return BucketState(date: state.date, seq: state.seq)
        }
        return BucketState(date: 0, seq: 0)
      }
    } catch {
      AppDatabase.log.error("Failed to fetch bucket state for \(key): \(error)")
      return BucketState(date: 0, seq: 0)
    }
  }

  public func setBucketState(for key: BucketKey, state: BucketState) async {
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
    } catch {
      AppDatabase.log.error("Failed to save bucket state for \(key): \(error)")
    }
  }

  public func setBucketStates(states: [BucketKey: BucketState]) async {
    do {
      try await db.dbWriter.write { db in
        for (key, state) in states {
          let dbState = DbBucketState(
            bucketType: key.getBucket(),
            entityId: key.getEntityId(),
            date: state.date,
            seq: state.seq
          )
          try dbState.save(db)
        }
      }
    } catch {
      AppDatabase.log.error("Failed to save bucket states batch: \(error)")
    }
  }

  public func clearSyncState() async {
    do {
      try await db.dbWriter.write { db in
        _ = try DbBucketState.deleteAll(db)
        _ = try DbGlobalSyncState.deleteAll(db)
      }
    } catch {
      AppDatabase.log.error("Failed to clear sync state: \(error)")
    }
  }
}
