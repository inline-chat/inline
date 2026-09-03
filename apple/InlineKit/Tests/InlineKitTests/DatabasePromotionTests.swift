import Auth
import Foundation
import GRDB
import Testing

@testable import InlineKit

@Suite("Database Promotion")
final class DatabasePromotionTests {
  @Test("persistent-store admission classifies only transient authority and SQLite contention as retryable")
  func classifiesPersistentStoreAdmissionFailures() {
    #expect(AppDatabase.persistentOpenFailure(for: .locked)?.disposition == .retryable)
    #expect(AppDatabase.persistentOpenFailure(for: .notFound)?.disposition == .terminal)
    #expect(AppDatabase.persistentOpenFailure(for: .error(status: -50))?.reason == .keychainFailure)

    let busy = AppDatabase.persistentOpenFailure(
      for: DatabaseError(resultCode: .SQLITE_BUSY_SNAPSHOT)
    )
    #expect(busy.reason == .databaseBusy)
    #expect(busy.disposition == .retryable)
    #expect(busy.sqliteCode == Int32(ResultCode.SQLITE_BUSY.rawValue))
    #expect(busy.sqliteExtendedCode == Int32(ResultCode.SQLITE_BUSY_SNAPSHOT.rawValue))

    let corrupt = AppDatabase.persistentOpenFailure(
      for: DatabaseError(resultCode: .SQLITE_CORRUPT_VTAB)
    )
    #expect(corrupt.reason == .databaseUnreadable)
    #expect(corrupt.disposition == .terminal)

    let full = AppDatabase.persistentOpenFailure(
      for: DatabaseError(resultCode: .SQLITE_FULL)
    )
    #expect(full.reason == .databaseFull)
    #expect(full.disposition == .terminal)

    let wrongCandidate = DatabaseError(resultCode: .SQLITE_NOTADB)
    let protectedDataDelay = AppDatabase.persistentOpenFailure(
      afterExhaustingCandidatesWith: .locked,
      lastError: wrongCandidate
    )
    #expect(protectedDataDelay.reason == .keychainLocked)
    #expect(protectedDataDelay.disposition == .retryable)

    let missingAuthority = AppDatabase.persistentOpenFailure(
      afterExhaustingCandidatesWith: .notFound,
      lastError: wrongCandidate
    )
    #expect(missingAuthority.reason == .keyUnavailable)
    #expect(missingAuthority.disposition == .terminal)

    let provenUnreadable = AppDatabase.persistentOpenFailure(
      afterExhaustingCandidatesWith: .available(key: "available"),
      lastError: wrongCandidate
    )
    #expect(provenUnreadable.reason == .databaseUnreadable)
    #expect(provenUnreadable.disposition == .terminal)

    let migrationFailure = AppDatabase.persistentOpenFailure(
      afterExhaustingCandidatesWith: .available(key: "available"),
      authoritativeKeyError: TestMigrationFailure(),
      lastError: wrongCandidate
    )
    #expect(migrationFailure.reason == .migration)
    #expect(migrationFailure.disposition == .terminal)
  }

  @Test("a nonpersistent database exposes its recorded open failure instead of claiming readiness")
  func exposesPersistentStoreAdmission() throws {
    let db = AppDatabase.empty()
    let failure = PersistentStoreOpenFailure(
      reason: .keychainLocked,
      disposition: .retryable,
      sqliteCode: nil,
      sqliteExtendedCode: nil
    )
    db.recordPersistentOpenFailure(failure)

    #expect(db.persistentStoreAdmission == .retryable(failure))
  }

  @Test("credential preparation fails closed when durable key authority is unavailable")
  func credentialPreparationRequiresDatabaseKey() throws {
    #expect(try AppDatabase.requiredDatabaseKey(for: .available(key: "stable")) == "stable")
    #expect(throws: DatabaseCredentialPreparationError.keychainLocked) {
      try AppDatabase.requiredDatabaseKey(for: .locked)
    }
    #expect(throws: DatabaseCredentialPreparationError.keyUnavailable) {
      try AppDatabase.requiredDatabaseKey(for: .notFound)
    }
    #expect(throws: DatabaseCredentialPreparationError.keychainFailure(-50)) {
      try AppDatabase.requiredDatabaseKey(for: .error(status: -50))
    }
  }

  @Test("waits for short-lived database contention")
  func configuresBusyTimeout() {
    let configuration = AppDatabase.makeConfiguration(passphrase: "123")
    guard case let .timeout(duration) = configuration.busyMode else {
      Issue.record("Expected a database busy timeout")
      return
    }
    #expect(duration == 5)
  }

  @Test("credential preparation is idempotent for the current writer and key")
  func tracksPreparedCredentialStorageKey() throws {
    let db = AppDatabase.empty()

    #expect(db.isCredentialStoragePrepared(for: "stable") == false)
    db.markCredentialStoragePrepared(for: "stable")
    #expect(db.isCredentialStoragePrepared(for: "stable"))
    #expect(db.isCredentialStoragePrepared(for: "replacement") == false)

    let replacement = try DatabaseQueue(
      configuration: AppDatabase.makeConfiguration(passphrase: "replacement")
    )
    db.swapWriter(replacement)
    #expect(db.isCredentialStoragePrepared(for: "stable") == false)
  }

  @Test("promotes in-memory DB to persistent once the persistent DB becomes openable")
  func promotesToPersistentIfPossible() async throws {
    let db = AppDatabase.empty()
    #expect(db.dbWriter is DatabaseQueue)

    let dirURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-dbpromo-\(UUID().uuidString)", isDirectory: true)
    let dbURL = dirURL.appendingPathComponent("db.sqlite")
    try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dirURL) }

    // 1) Create an encrypted DB file with a passphrase that we won't provide to the reopen closure.
    // This ensures promotion can't succeed until we rotate the file to a known passphrase.
    let badPassphrase = "badpass_" + UUID().uuidString
    do {
      let pool = try DatabasePool(
        path: dbURL.path,
        configuration: AppDatabase.makeConfiguration(passphrase: badPassphrase)
      )
      try await pool.barrierWriteWithoutTransaction { db in
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS db_promo_bootstrap(id INTEGER PRIMARY KEY)")
      }
      withExtendedLifetime(pool) {}
    }

    // 2) Simulate "credentials/key available later" by rotating the persistent file to a known
    // passphrase used by our reopen closure.
    do {
      let pool = try DatabasePool(
        path: dbURL.path,
        configuration: AppDatabase.makeConfiguration(passphrase: badPassphrase)
      )
      try await pool.barrierWriteWithoutTransaction { db in
        try db.changePassphrase("123")
      }
      withExtendedLifetime(pool) {}
    }

    // 3) Promote in-place from in-memory to persistent writer for this isolated DB instance.
    let didPromote = await AppDatabase.promoteToPersistentIfPossible(db) {
      do {
        return try DatabasePool(
          path: dbURL.path,
          configuration: AppDatabase.makeConfiguration(passphrase: "123")
        )
      } catch {
        return nil
      }
    }
    #expect(didPromote)
    #expect(db.dbWriter is DatabasePool)

    // 4) Write through the promoted writer and verify it actually hit the persistent file.
    try await db.dbWriter.write { sqlDb in
      try sqlDb.execute(sql: "CREATE TABLE IF NOT EXISTS db_promo_test(value TEXT NOT NULL)")
      try sqlDb.execute(sql: "INSERT INTO db_promo_test(value) VALUES (?)", arguments: ["ok"])
    }

    let verificationPool = try DatabasePool(
      path: dbURL.path,
      configuration: AppDatabase.makeConfiguration(passphrase: "123")
    )
    let count = try await verificationPool.read { sqlDb in
      try Int.fetchOne(sqlDb, sql: "SELECT COUNT(*) FROM db_promo_test") ?? 0
    }
    #expect(count == 1)

    // Idempotent: once persistent, subsequent promotions are no-ops.
    let didPromoteAgain = await AppDatabase.promoteToPersistentIfPossible(db) { nil }
    #expect(didPromoteAgain == false)
  }

  @Test("logout cleanup refuses to prove an in-memory fallback is the persistent store")
  func logoutCleanupRequiresPersistentStorage() async {
    let db = AppDatabase.empty()
    #expect(db.isPersistent == false)

    await #expect(throws: AppDatabase.LogoutCleanupError.self) {
      try await AppDatabase.requirePersistentStorageForLogout(db) { false }
    }
  }
}

private struct TestMigrationFailure: Error {}
