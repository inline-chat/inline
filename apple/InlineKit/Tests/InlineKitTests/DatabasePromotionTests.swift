import Auth
import Foundation
import GRDB
import InlineConfig
import Testing
import Darwin

@testable import InlineKit

private let _dbPromotionTestUserProfile: String = {
  if let existing = ProjectConfig.userProfile, existing.isEmpty == false {
    return existing
  }

  let profile = "dbpromo_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
  // Tests can't modify `CommandLine.arguments` in Swift 6 language mode, so we use an env var
  // override supported by `ProjectConfig.userProfile`.
  setenv("INLINE_USER_PROFILE", profile, 1)
  return profile
}()

private func databaseURLForTestProfile(_ profile: String) throws -> URL {
  let fileManager = FileManager.default
  let appSupportURL = try fileManager.url(
    for: .applicationSupportDirectory,
    in: .userDomainMask,
    appropriateFor: nil,
    create: false
  )

  let directoryURL = appSupportURL.appendingPathComponent("Database_\(profile)", isDirectory: true)
  try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

  return directoryURL.appendingPathComponent("db.sqlite")
}

@Suite("Database Promotion")
final class DatabasePromotionTests {
  @Test("promotes shared DB from in-memory to persistent once the persistent DB becomes openable")
  func promotesSharedToPersistentIfPossible() async throws {
    // Ensure we do not touch any real user database/keychain items.
    let profile = _dbPromotionTestUserProfile
    #expect(ProjectConfig.userProfile == profile)

    let dbURL = try databaseURLForTestProfile(profile)
    let dirURL = dbURL.deletingLastPathComponent()

    // Start from a clean directory for this profile.
    do {
      if FileManager.default.fileExists(atPath: dirURL.path) {
        try FileManager.default.removeItem(at: dirURL)
      }
    } catch {
      // Best-effort cleanup; never fail the test for not being able to delete a previous run.
    }
    try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

    // 1) Create an encrypted DB file with a passphrase that we won't provide to `makeShared()`.
    // This forces `AppDatabase.shared` to fall back to an in-memory DB.
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

    #expect(AppDatabase.shared.dbWriter is DatabaseQueue)

    // 2) Simulate "credentials/key available later" by rotating the persistent file to a known
    // candidate passphrase. `makeShared()` will then be able to open it.
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

    // 3) Promote in-place: `shared` swaps from in-memory to persistent writer.
    let didPromote = await AppDatabase.promoteSharedToPersistentIfPossible()
    #expect(didPromote)
    #expect(AppDatabase.shared.dbWriter is DatabasePool)

    // 4) Write something through `shared` and verify it actually hit the persistent file.
    try await AppDatabase.shared.dbWriter.write { db in
      try db.execute(sql: "CREATE TABLE IF NOT EXISTS db_promo_test(value TEXT NOT NULL)")
      try db.execute(sql: "INSERT INTO db_promo_test(value) VALUES (?)", arguments: ["ok"])
    }

    var candidatePassphrases: [String] = []
    switch DatabaseKeyStore.load() {
    case .available(let key):
      candidatePassphrases.append(key)
    case .locked, .notFound, .error:
      break
    }
    if let token = Auth.shared.getToken(), !candidatePassphrases.contains(token) {
      candidatePassphrases.append(token)
    }
    candidatePassphrases.append("123")

    var openedPool: DatabasePool?
    for passphrase in candidatePassphrases {
      do {
        let pool = try DatabasePool(
          path: dbURL.path,
          configuration: AppDatabase.makeConfiguration(passphrase: passphrase)
        )
        let count = try await pool.read { db in
          try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM db_promo_test") ?? 0
        }
        if count == 1 {
          openedPool = pool
          break
        }
      } catch {
        continue
      }
    }

    #expect(openedPool != nil)

    // Idempotent: once persistent, subsequent promotions are no-ops.
    let didPromoteAgain = await AppDatabase.promoteSharedToPersistentIfPossible()
    #expect(didPromoteAgain == false)

    // Best-effort cleanup: swap back to in-memory to release the file handle, then delete.
    openedPool = nil
    do {
      let inMemory = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
      AppDatabase.shared.swapWriter(inMemory)
    } catch {
      // ignore
    }
    do {
      try FileManager.default.removeItem(at: dirURL)
    } catch {
      // ignore
    }

    // Best-effort cleanup of keychain items under this test profile.
    DatabaseKeyStore.delete()
    await Auth.shared.logOut()
  }
}
