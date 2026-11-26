import Foundation
import GRDB
import os

/// What one commit changed, as cache IDs.
struct ObjectChanges: Sendable, Equatable {
  /// Records whose rows were written.
  var ids: Set<ObjectID> = []
  /// Kinds with a change that can't be traced to its records (a deleted profile photo).
  var kinds: Set<ObjectKind> = []
  /// Written `message` rowids. The cache maps them to the keys it holds them under, which a delete or an
  /// id rewrite (a sent message getting its server id) no longer names in the database.
  var messageRowIDs: Set<Int64> = []
  /// Ids of written `file` rows. The cache maps them to the users it holds them for, which a photo that
  /// moved to another user no longer names.
  var fileIDs: Set<String> = []
  /// Kinds whose tables the commit wrote: reads of them in flight may have read the old rows.
  var writtenKinds: Set<ObjectKind> = []

  var isEmpty: Bool { writtenKinds.isEmpty && ids.isEmpty && kinds.isEmpty }
}

/// Collects the rowids each commit writes in the tables cache records are read from, and maps them to
/// cache IDs after the commit, on the writer, reading only the written rows by key.
///
/// Whole-table observations told the cache only that "users changed", so every presence update re-read
/// up to 512 cached users, and every `file` write (a media download) did too.
final class ObjectChangeTracker: TransactionObserver, @unchecked Sendable {
  static let tables = Set(ObjectKind.allCases.flatMap(\.tables))
  /// Past this many rows of one table in a commit (a large sync, a clear), the kind is noted as a whole
  /// instead of row by row.
  static let rowLimit = 2_000

  // Writer-queue state, touched only from TransactionObserver callbacks.
  private var pending: [String: Set<Int64>] = [:]
  private var deletedTables: Set<String> = []
  private let onChange: @Sendable (ObjectChanges) -> Void

  init(onChange: @escaping @Sendable (ObjectChanges) -> Void) {
    self.onChange = onChange
  }

  func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
    Self.tables.contains(eventKind.tableName)
  }

  func databaseDidChange(with event: DatabaseEvent) {
    // Statements on these tables also report the message search index's own tables; skip them.
    guard Self.tables.contains(event.tableName) else { return }
    pending[event.tableName, default: []].insert(event.rowID)
    if event.kind == .delete {
      deletedTables.insert(event.tableName)
    }
  }

  func databaseDidRollback(_: Database) {
    pending.removeAll()
    deletedTables.removeAll()
  }

  func databaseDidCommit(_ db: Database) {
    guard !pending.isEmpty else { return }
    let tables = pending
    let deletes = deletedTables
    pending.removeAll()
    deletedTables.removeAll()
    var changes: ObjectChanges
    do {
      changes = try Self.resolve(db, tables: tables, deletes: deletes)
    } catch {
      changes = ObjectChanges(kinds: Set(ObjectKind.allCases))
    }
    if !changes.isEmpty {
      onChange(changes)
    }
  }

  static func resolve(_ db: Database, tables: [String: Set<Int64>], deletes: Set<String>) throws -> ObjectChanges {
    var changes = ObjectChanges()
    var tables = tables
    for (table, rowIDs) in tables {
      guard let kind = ObjectKind.allCases.first(where: { $0.tables.contains(table) }) else { continue }
      changes.writtenKinds.insert(kind)
      if rowIDs.count > rowLimit {
        changes.kinds.insert(kind)
        tables[table] = nil
      }
    }
    // Users, focus rows (keyed by user), chats and spaces are keyed by their rowid.
    for table in [User.databaseTableName, UserFocus.databaseTableName] {
      for id in tables[table] ?? [] { changes.ids.insert(.user(id)) }
    }
    for id in tables[Chat.databaseTableName] ?? [] { changes.ids.insert(.chat(id)) }
    for id in tables[Space.databaseTableName] ?? [] { changes.ids.insert(.space(id)) }

    if let rowIDs = tables[File.databaseTableName] {
      // Only profile photos feed a record (a user's photos). The cache also maps the ids to the users it
      // holds them for; a deleted file can't be traced at all.
      for row in try Row.fetchAll(
        db.cachedStatement(sql: "SELECT id, profileForUserId FROM file WHERE rowid IN (SELECT value FROM json_each(?))"),
        arguments: [jsonArray(rowIDs)]
      ) {
        if let fileID: String = row[0] { changes.fileIDs.insert(fileID) }
        if let userID: Int64 = row[1] { changes.ids.insert(.user(userID)) }
      }
      if deletes.contains(File.databaseTableName) { changes.kinds.insert(.user) }
    }
    if let rowIDs = tables[Message.databaseTableName] {
      changes.messageRowIDs = rowIDs
      for row in try Row.fetchAll(
        db.cachedStatement(sql: "SELECT chatId, messageId FROM message WHERE globalId IN (SELECT value FROM json_each(?))"),
        arguments: [jsonArray(rowIDs)]
      ) {
        changes.ids.insert(.message(chatId: row[0], messageId: row[1]))
      }
    }
    return changes
  }

  private static func jsonArray(_ values: Set<Int64>) -> String {
    "[" + values.map(String.init).joined(separator: ",") + "]"
  }
}
