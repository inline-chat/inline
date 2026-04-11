import Foundation
import GRDB
import Testing

@testable import InlineKit

@Suite("Database Promotion")
final class DatabasePromotionTests {
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
}
