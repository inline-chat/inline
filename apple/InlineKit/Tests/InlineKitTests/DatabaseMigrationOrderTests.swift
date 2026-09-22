import GRDB
import Testing

@testable import InlineKit

@Suite("Database Migration Order")
struct DatabaseMigrationOrderTests {
  private let dialogFoldersMigration = "dialog folders"
  private let messagePayloadMigration = "message block content payload"
  private let repairMigration = "repair invalid cached user presence"
  private let previousTailMigration = "dialog folder pinned order"

  @Test("existing databases acquire persistent removal evidence without changing cursors")
  func upgradesRemovalRevision() throws {
    let migrator = makeMigrator()
    let writer = try DatabaseQueue()
    try migrator.migrate(writer, upTo: "agent thread context and catalog")
    try writer.write { db in
      try DbBucketState(bucketType: 2, entityId: 0, date: 100, seq: 7).insert(db)
    }
    try migrator.migrate(writer)
    try writer.write { (db: Database) throws in
      #expect(try SyncRemovalRevision.read(db) == 0)
      try SyncRemovalRevision.advance(db)
      #expect(try SyncRemovalRevision.read(db) == 1)
      #expect(try DbBucketState.fetchOne(db)?.seq == 7)
    }
    try migrator.migrate(writer)
    #expect(try writer.read { try SyncRemovalRevision.read($0) } == 1)
  }

  @Test("missing removal evidence fails instead of admitting revision zero")
  func missingRemovalEvidenceFails() throws {
    let writer = try DatabaseQueue()
    try makeMigrator().migrate(writer)
    try writer.write { db in
      try db.execute(sql: "DELETE FROM sync_removal_revision")
      #expect(throws: DatabaseError.self) { try SyncRemovalRevision.read(db) }
      #expect(throws: DatabaseError.self) { try SyncRemovalRevision.advance(db) }
    }
  }

  @Test("upgrading repairs removal evidence deleted by older account cleanup")
  func repairsLegacyAccountCleanup() throws {
    let writer = try DatabaseQueue()
    let migrator = makeMigrator()
    try migrator.migrate(writer, upTo: "sequenced member projection")
    try writer.write { db in
      try db.execute(sql: "DELETE FROM sync_removal_revision")
      try DbBucketState(bucketType: 2, entityId: 0, date: 100, seq: 7).insert(db)
    }
    try migrator.migrate(writer)
    try writer.write { db in
      #expect(try SyncRemovalRevision.read(db) == 0)
      #expect(try DbBucketState.fetchOne(db)?.seq == 7)
      try SyncRemovalRevision.advance(db)
      #expect(try SyncRemovalRevision.read(db) == 1)
    }
  }

  @Test("account cleanup clears account data and reseeds usable sync metadata")
  func accountCleanupReseedsRemovalEvidence() throws {
    let writer = try DatabaseQueue()
    try makeMigrator().migrate(writer)
    try writer.write { db in
      try User(id: 1, email: nil, firstName: "Previous account").insert(db)
      try DbBucketState(bucketType: 2, entityId: 0, date: 100, seq: 7).insert(db)
      try SyncRemovalRevision.advance(db)
      try AppDatabase.clearTables(db)
      #expect(try User.fetchCount(db) == 0)
      #expect(try DbBucketState.fetchCount(db) == 0)
      #expect(try SyncRemovalRevision.read(db) == 0)
      try SyncRemovalRevision.advance(db)
      #expect(try SyncRemovalRevision.read(db) == 1)
      try AppDatabase.clearTables(db)
      #expect(try SyncRemovalRevision.read(db) == 0)
    }
  }

  @Test("repair migration preserves existing removal evidence")
  func repairPreservesExistingRemovalEvidence() throws {
    let writer = try DatabaseQueue()
    let migrator = makeMigrator()
    try migrator.migrate(writer, upTo: "sequenced member projection")
    try writer.write { db in
      try SyncRemovalRevision.advance(db)
      try SyncRemovalRevision.advance(db)
    }
    try migrator.migrate(writer)
    #expect(try writer.read { try SyncRemovalRevision.read($0) } == 2)
  }

  @Test("message payload follows the earlier dialog folders migration")
  func messagePayloadFollowsDialogFolders() {
    let migrations = makeMigrator().migrations

    #expect(migrations.firstIndex(of: dialogFoldersMigration).map { folderIndex in
      migrations.firstIndex(of: messagePayloadMigration).map { payloadIndex in
        payloadIndex == folderIndex + 1
      } ?? false
    } ?? false)
  }

  @Test("databases with both historically inverted migration IDs remain compatible")
  func acceptsHistoricallyInvertedMigrationIdentifiers() throws {
    let migrator = makeMigrator()
    let writer = try DatabaseQueue()

    // GRDB records applied identifiers as a set, so applying these two migrations
    // in the historical order produces the same durable state as this prefix.
    try migrator.migrate(writer, upTo: messagePayloadMigration)

    #expect(try writer.read { db in
      try migrator.hasSchemaChanges(db) == false
    })
    try migrator.migrate(writer)
    #expect(try writer.read(migrator.appliedMigrations) == migrator.migrations)
  }

  @Test("presence repair follows the committed migration tail")
  func presenceRepairIsAppended() {
    let migrations = makeMigrator().migrations

    #expect(migrations.firstIndex(of: previousTailMigration).map { tailIndex in
      migrations.firstIndex(of: repairMigration).map { repairIndex in
        repairIndex > tailIndex
      } ?? false
    } ?? false)
  }

  @Test("an existing database applies the appended presence repair")
  func upgradesFromPreviousTail() throws {
    let migrator = makeMigrator()
    let writer = try DatabaseQueue()
    try migrator.migrate(writer, upTo: previousTailMigration)

    try writer.write { db in
      try User(id: 1, email: nil, firstName: "Mo").insert(db)
      try db.execute(
        sql: "UPDATE user SET lastOnline = ? WHERE id = 1",
        arguments: [Int64(1_723_000_000_000)]
      )
    }

    #expect(try writer.read { db in
      try Bool.fetchOne(
        db,
        sql: "SELECT lastOnline IS NULL FROM user WHERE id = 1"
      ) == false
    })

    try migrator.migrate(writer)

    #expect(try writer.read { db in
      try Bool.fetchOne(
        db,
        sql: "SELECT lastOnline IS NULL FROM user WHERE id = 1"
      ) == true
    })
    #expect(try writer.read(migrator.appliedMigrations).contains(repairMigration))
  }

  @Test("development databases tolerate the repair identifier from its old WIP position")
  func acceptsPreviouslyRecordedWIPOrder() throws {
    let migrator = makeMigrator()
    let writer = try DatabaseQueue()
    try migrator.migrate(writer, upTo: "dialog collapsed max id")

    try writer.write { db in
      try User(id: 1, email: nil, firstName: "Mo").insert(db)
      try db.execute(
        sql: "UPDATE user SET lastOnline = ? WHERE id = 1",
        arguments: [Int64(1_723_000_000_000)]
      )
      _ = try AppDatabase.repairInvalidCachedUserPresence(in: db)
      try db.execute(
        sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
        arguments: [repairMigration]
      )
    }

    try migrator.migrate(writer)

    #expect(try writer.read(migrator.appliedMigrations) == migrator.migrations)
  }

  private func makeMigrator() -> DatabaseMigrator {
    var migrator = AppDatabase.empty().migrator
    migrator.eraseDatabaseOnSchemaChange = false
    return migrator
  }
}
