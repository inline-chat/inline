import GRDB
@testable import InlineKit

extension EncodableRecord where Self: TableRecord {
  /// Inserts the record into a database migrated only part of the way, writing just the columns
  /// that table has so far. Columns added by later migrations would otherwise fail the insert.
  func insertIntoPartialSchema(_ db: Database) throws {
    let existing = try Set(db.columns(in: Self.databaseTableName).map(\.name))
    let values = try databaseDictionary.filter { existing.contains($0.key) }
    let columns = values.keys.sorted()
    let sql = """
    INSERT INTO \(Self.databaseTableName.quotedDatabaseIdentifier) \
    (\(columns.map(\.quotedDatabaseIdentifier).joined(separator: ", "))) \
    VALUES (\(databaseQuestionMarks(count: columns.count)))
    """
    try db.execute(sql: sql, arguments: StatementArguments(columns.map { values[$0]! }))
  }
}
