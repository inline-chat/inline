import Combine
import Foundation
import GRDB
import Logger

public enum UnreadDMCount {
  private static func fetch(_ db: Database) throws -> Int {
    let request = SQLRequest<Int>(
      sql: """
      SELECT COALESCE(SUM(COALESCE(unreadCount, 0)), 0)
      FROM dialog
      WHERE peerUserId IS NOT NULL
      AND (archived IS NULL OR archived = 0)
      """
    )
    return try request.fetchOne(db) ?? 0
  }

  /// Fetches the current unread DM count once.
  ///
  /// This is useful when re-enabling the badge setting so the current count shows immediately,
  /// without waiting for the observation pipeline to deliver its first value.
  public static func current(db: AppDatabase = .shared) -> Int {
    do {
      return try db.reader.read { database in
        try fetch(database)
      }
    } catch {
      let log = Log.scoped("UnreadDMCount", enableTracing: false)
      log.error("Failed to fetch unread DM count", error: error)
      return 0
    }
  }

  /// Total unread message count across all non-archived direct-message dialogs.
  ///
  /// Semantics:
  /// - DM dialogs are rows where `peerUserId IS NOT NULL` (see `Dialog` model).
  /// - Archived dialogs (`archived == true`) are excluded.
  /// - `unreadCount` NULL is treated as 0.
  public static func publisher(db: AppDatabase = .shared) -> AnyPublisher<Int, Never> {
    let log = Log.scoped("UnreadDMCount", enableTracing: false)
    db.warnIfInMemoryDatabaseForObservation("UnreadDMCount.publisher")

    return ValueObservation
      .tracking { database in
        try fetch(database)
      }
      .publisher(in: db.reader, scheduling: .immediate)
      .catch { error in
        log.error("Failed to observe unread DM count", error: error)
        return Just(0)
      }
      .removeDuplicates()
      .eraseToAnyPublisher()
  }
}
