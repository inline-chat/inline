import Auth
import Foundation
import GRDB
import InlineProtocol
import RealtimeV2

public enum InviteDirectory {
  public static func spaces(database: AppDatabase = .shared) async throws -> [Space] {
    try await database.dbWriter.read { db in
      try Space
        .order(Space.Columns.name.collating(.localizedCaseInsensitiveCompare))
        .fetchAll(db)
    }
  }

  public static func spaceName(spaceID: Int64, database: AppDatabase = .shared) async throws -> String? {
    try await database.dbWriter.read { db in
      try Space.fetchOne(db, key: spaceID)?.name
    }
  }

  public static func localUsers(
    query: String,
    database: AppDatabase = .shared,
    limit: Int = 20
  ) async throws -> [UserInfo] {
    let needle = normalizedQuery(query)
    guard needle.count >= 2 else { return [] }
    let currentUserID = Auth.shared.getCurrentUserId()
    let escapedNeedle = needle
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
    let pattern = "%\(escapedNeedle)%"

    return try await database.dbWriter.read { db in
      try User.userInfoQuery()
        .filter(User.Columns.id != currentUserID)
        .filter(User.Columns.pendingSetup == false)
        .filter(User.Columns.bot == false)
        .filter(
          sql: """
          LOWER(COALESCE(firstName, '')) LIKE ? ESCAPE '\\'
          OR LOWER(COALESCE(lastName, '')) LIKE ? ESCAPE '\\'
          OR LOWER(TRIM(COALESCE(firstName, '') || ' ' || COALESCE(lastName, ''))) LIKE ? ESCAPE '\\'
          OR LOWER(COALESCE(username, '')) LIKE ? ESCAPE '\\'
          """,
          arguments: [pattern, pattern, pattern, pattern]
        )
        .limit(limit)
        .fetchAll(db)
    }
  }

  public static func remoteUsers(
    query: String,
    realtime: RealtimeV2,
    database: AppDatabase = .shared,
    limit: Int32 = 20
  ) async throws -> [UserInfo] {
    let needle = normalizedQuery(query)
    guard needle.count >= 2, !needle.contains("@"), !looksLikePhone(needle) else { return [] }
    let result = try await realtime.send(.searchUsers(query: needle, limit: limit))
    guard case let .searchUsers(response) = result else { return [] }

    return try await database.dbWriter.write { db in
      for protocolUser in response.users {
        _ = try User.save(db, user: protocolUser)
      }
      let ids = response.users.map(\.id)
      guard !ids.isEmpty else { return [] }
      let fetched = try User.userInfoQuery()
        .filter(ids.contains(User.Columns.id))
        .fetchAll(db)
      let byID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
      return ids.compactMap { byID[$0] }
    }
  }

  private static func normalizedQuery(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingPrefix("@")
      .lowercased()
  }

  private static func looksLikePhone(_ value: String) -> Bool {
    value.range(of: #"^\+?[0-9\s().-]+$"#, options: .regularExpression) != nil
  }
}
