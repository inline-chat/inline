import Foundation
import GRDB
import InlineSQLiteTuning
import SQLCipher
import Testing

@testable import InlineKit

@Suite("SQLite connection setup")
struct SQLiteConnectionSetupTests {
  @Test("pool connections keyed with the raw key read what the passphrase wrote, across a rekey")
  func rawKeyMatchesPassphrase() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("db.sqlite").path
    let first = "raw-key-one-\(UUID().uuidString)"
    let second = "raw-key-two-\(UUID().uuidString)"

    do {
      let created = try AppDatabase(path: path, passphrase: first)
      try Self.insertSpace(1, into: created)
      // Readers opened on a file created by this pool.
      #expect(Self.concurrentSpaceCounts(created.dbWriter) == Array(repeating: 1, count: 5))
      #expect(created.poolConnectionKey == SQLCipherRawKey.literal(passphrase: first, databasePath: path))

      try created.changePassphrase(second)
      #expect(Self.concurrentSpaceCounts(created.dbWriter) == Array(repeating: 1, count: 5))
      #expect(created.poolConnectionKey == SQLCipherRawKey.literal(passphrase: second, databasePath: path))
      try Self.insertSpace(2, into: created)
      try created.closePersistentStorage()
    }

    let reopened = try AppDatabase(path: path, passphrase: second)
    #expect(Self.spaceCount(reopened.dbWriter) == 2)
    try reopened.closePersistentStorage()

    // What an older build sees: the passphrase on every connection, derived by SQLCipher.
    #expect(Self.passphraseOnlySpaceCount(path: path, passphrase: second) == 2)
    #expect(Self.passphraseOnlySpaceCount(path: path, passphrase: first) == nil)
    let withOldPassphrase = (try? AppDatabase(path: path, passphrase: first)).flatMap { Self.spaceCount($0.dbWriter) }
    #expect(withOldPassphrase == nil)
  }

  @Test("a file keyed by passphrase alone opens with the raw key derived from its salt")
  func opensFileCreatedWithPassphrase() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("db.sqlite").path
    let passphrase = "older-build-\(UUID().uuidString)"

    do {
      let queue = try DatabaseQueue(path: path, configuration: AppDatabase.makeConfiguration(passphrase: passphrase))
      try queue.write { db in
        try db.execute(sql: "CREATE TABLE older_build_fixture (value TEXT NOT NULL)")
        try db.execute(sql: "INSERT INTO older_build_fixture VALUES ('kept')")
      }
      try queue.close()
    }

    let salt = try #require(SQLCipherRawKey.salt(forDatabaseAt: path))
    #expect(salt.count == SQLCipherRawKey.saltLength)
    let database = try AppDatabase(path: path, passphrase: passphrase)
    #expect(database.poolConnectionKey == SQLCipherRawKey.literal(passphrase: passphrase, salt: salt))
    let values = Self.concurrentReads(database.dbWriter) { db in
      try String.fetchOne(db, sql: "SELECT value FROM older_build_fixture")
    }
    #expect(values == Array(repeating: "kept", count: 5))
    try database.closePersistentStorage()
  }

  @Test("no raw key without an encrypted file's salt or a passphrase")
  func rawKeyNeedsSaltAndPassphrase() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let missing = directory.appendingPathComponent("missing.sqlite").path
    #expect(SQLCipherRawKey.salt(forDatabaseAt: missing) == nil)

    let empty = directory.appendingPathComponent("empty.sqlite").path
    FileManager.default.createFile(atPath: empty, contents: Data())
    #expect(SQLCipherRawKey.salt(forDatabaseAt: empty) == nil)

    let plaintext = directory.appendingPathComponent("plain.sqlite").path
    let queue = try DatabaseQueue(path: plaintext)
    try queue.write { try $0.execute(sql: "CREATE TABLE t (x)") }
    try queue.close()
    #expect(SQLCipherRawKey.salt(forDatabaseAt: plaintext) == nil)

    // An empty key means no encryption to SQLCipher.
    #expect(SQLCipherRawKey.derivedKey(passphrase: "", salt: Data(count: SQLCipherRawKey.saltLength)) == nil)
    #expect(SQLCipherRawKey.derivedKey(passphrase: "key", salt: Data(count: 3)) == nil)
  }

  @Test("connections keep readers, size their page cache and keep cached plans")
  func connectionOptions() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("db.sqlite").path
    let database = try AppDatabase(path: path, passphrase: "options-\(UUID().uuidString)")
    defer { try? database.closePersistentStorage() }
    let pool = try #require(database.dbWriter as? DatabasePool)

    #expect(pool.configuration.persistentReadOnlyConnections)
    #expect(try pool.write { try Int.fetchOne($0, sql: "PRAGMA cache_size") } == -16384)
    #expect(try pool.read { try Int.fetchOne($0, sql: "PRAGMA cache_size") } == -4096)

    try pool.write { db in try Self.seedSkewedProbe(db) }
    // With STAT4 statistics, a plan that probed a bound value is recompiled when the binding changes.
    // The planner stability guarantee keeps the cached plan.
    #expect(try pool.write { db in try Self.repreparesOverChangingBindings(db) } == 0)

    // Control: the same statement on a connection without the guarantee is recompiled, so the check
    // above is not vacuous.
    let control = try DatabaseQueue(path: directory.appendingPathComponent("control.sqlite").path)
    let controlReprepares = try control.write { db in
      try Self.seedSkewedProbe(db)
      return try Self.repreparesOverChangingBindings(db)
    }
    #expect(controlReprepares > 0)
    try control.close()
  }

  // MARK: - Helpers

  private static func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-setup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private static func insertSpace(_ id: Int64, into database: AppDatabase) throws {
    try database.dbWriter.write { db in
      try db.execute(
        sql: "INSERT INTO space (id, name, date) VALUES (?, 'fixture', CURRENT_TIMESTAMP)",
        arguments: [id]
      )
    }
  }

  private static func spaceCount(_ reader: any DatabaseReader) -> Int? {
    try? reader.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM space") }
  }

  private static func passphraseOnlySpaceCount(path: String, passphrase: String) -> Int? {
    guard let queue = try? DatabaseQueue(path: path, configuration: AppDatabase.makeConfiguration(passphrase: passphrase))
    else { return nil }
    defer { try? queue.close() }
    return spaceCount(queue)
  }

  private static func concurrentSpaceCounts(_ reader: any DatabaseReader) -> [Int?] {
    concurrentReads(reader) { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM space") }
  }

  /// Runs the same read on five threads at once, so the pool opens several reader connections.
  private static func concurrentReads<T: Sendable>(
    _ reader: any DatabaseReader,
    _ read: @escaping @Sendable (Database) throws -> T?
  ) -> [T?] {
    let results = OSAllocatedUnfairLockBox<[T?]>([])
    DispatchQueue.concurrentPerform(iterations: 5) { _ in
      let value = try? reader.read(read)
      results.append(value ?? nil)
    }
    return results.value
  }

  /// One very common key and many rare ones, analyzed, so the planner consults STAT4 samples.
  private static func seedSkewedProbe(_ db: Database) throws {
    try db.execute(sql: """
    CREATE TABLE probe (id INTEGER PRIMARY KEY, k INTEGER NOT NULL, v INTEGER NOT NULL);
    CREATE INDEX probe_k_idx ON probe(k);
    CREATE INDEX probe_v_idx ON probe(v);
    """)
    let insert = try db.makeStatement(sql: "INSERT INTO probe (k, v) VALUES (?, ?)")
    for i in 0 ..< 2000 {
      try insert.execute(arguments: [i < 1500 ? 1 : i, i % 7])
    }
    try db.execute(sql: "ANALYZE")
  }

  private static func repreparesOverChangingBindings(_ db: Database) throws -> Int32 {
    let statement = try db.cachedStatement(sql: "SELECT count(*) FROM probe WHERE k = ? AND v > 0")
    _ = sqlite3_stmt_status(statement.sqliteStatement, SQLITE_STMTSTATUS_REPREPARE, 1)
    for k in [1, 1600, 1, 1700, 1800, 1, 1900, 1501, 1, 1999] {
      _ = try Int.fetchOne(statement, arguments: [k])
    }
    return sqlite3_stmt_status(statement.sqliteStatement, SQLITE_STMTSTATUS_REPREPARE, 0)
  }
}

private final class OSAllocatedUnfairLockBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Value

  init(_ value: Value) { storage = value }

  var value: Value { lock.withLock { storage } }

  func append<Element>(_ element: Element) where Value == [Element] {
    lock.withLock { storage.append(element) }
  }
}
