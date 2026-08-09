import Foundation
import GRDB
import Testing

@testable import InlineKit

@Suite("Database passphrase source")
struct DatabasePassphraseSourceTests {
  @Test("rekey prepares replacement readers with the new per-pool passphrase")
  func rekeyPreparesReplacementReadersWithNewPassphrase() async throws {
    let artifactDirectory = try makeArtifactDirectory()
    print("SQLCipher focused rekey artifacts: \(artifactDirectory.path)")

    let oldPassphrase = "synthetic-old-key"
    let newPassphrase = "synthetic-new-key"

    // Control: an immutable opening configuration keeps preparing readers with the old key.
    let immutableURL = artifactDirectory.appending(path: "immutable-control.sqlite")
    let immutablePool = try DatabasePool(
      path: immutableURL.path,
      configuration: AppDatabase.makeConfiguration(passphrase: oldPassphrase)
    )
    defer { try? immutablePool.close() }
    try await seedAndWarmReader(immutablePool)
    try await immutablePool.barrierWriteWithoutTransaction { db in
      try db.changePassphrase(newPassphrase)
      immutablePool.invalidateReadOnlyConnections()
    }

    var immutableConfigurationRejected = false
    do {
      _ = try await rowCount(in: immutablePool)
    } catch let error as DatabaseError {
      immutableConfigurationRejected = true
      #expect(error.resultCode == .SQLITE_NOTADB)
    }
    #expect(immutableConfigurationRejected)
    try immutablePool.close()

    // Closing and reopening with an immutable new-key configuration is a safe fallback.
    let reopenedControl = try DatabasePool(
      path: immutableURL.path,
      configuration: AppDatabase.makeConfiguration(passphrase: newPassphrase)
    )
    defer { try? reopenedControl.close() }
    #expect(try await rowCount(in: reopenedControl) == 1)
    try reopenedControl.close()

    // Experiment: update the pool-scoped key before rekeying and invalidating its readers.
    let mutableURL = artifactDirectory.appending(path: "mutable-source.sqlite")
    let passphraseSource = DatabasePassphraseSource(oldPassphrase)
    let mutablePool = try DatabasePool(
      path: mutableURL.path,
      configuration: AppDatabase.makeConfiguration(passphraseSource: passphraseSource)
    )
    defer { try? mutablePool.close() }
    try await seedAndWarmReader(mutablePool)
    try await mutablePool.barrierWriteWithoutTransaction { db in
      let previousPassphrase = passphraseSource.replace(with: newPassphrase)
      do {
        try db.changePassphrase(newPassphrase)
      } catch {
        passphraseSource.replace(with: previousPassphrase)
        throw error
      }
      mutablePool.invalidateReadOnlyConnections()
    }

    #expect(try await rowCount(in: mutablePool) == 1)
    try mutablePool.close()

    // The file itself must remain reopenable with the new key after the live-pool check.
    let reopenedMutable = try DatabasePool(
      path: mutableURL.path,
      configuration: AppDatabase.makeConfiguration(passphrase: newPassphrase)
    )
    defer { try? reopenedMutable.close() }
    #expect(try await rowCount(in: reopenedMutable) == 1)
  }

  private func seedAndWarmReader(_ pool: DatabasePool) async throws {
    try await pool.write { db in
      try db.execute(sql: "CREATE TABLE rekeyProbe (id INTEGER PRIMARY KEY, value TEXT NOT NULL)")
      try db.execute(sql: "INSERT INTO rekeyProbe (id, value) VALUES (1, 'synthetic')")
    }
    #expect(try await rowCount(in: pool) == 1)
  }

  private func rowCount(in pool: DatabasePool) async throws -> Int {
    try await pool.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rekeyProbe") ?? 0
    }
  }

  private func makeArtifactDirectory() throws -> URL {
    let sourceFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot = sourceFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let directory = repositoryRoot
      .appending(path: ".tmp/overnight-sqlcipher/focused-passphrase-source", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
