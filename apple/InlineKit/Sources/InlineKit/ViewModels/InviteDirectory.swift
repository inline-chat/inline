import Auth
import Foundation
import GRDB
import InlineProtocol
import RealtimeV2

public enum InviteDirectory {
  public static func spaces(database: AppDatabase = .shared) async throws -> [Space] {
    try await database.dbWriter.read { db in
      try Space
        .catalogActive()
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
    guard !needle.isEmpty else { return [] }
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
        .filter(
          sql: """
          COALESCE(bot, 0) = 0
          OR "user".id IN (
            SELECT peerUserId FROM chat
            WHERE peerUserId IS NOT NULL
          )
          """
        )
        .filter(
          sql: """
          LOWER(COALESCE(firstName, '')) LIKE ? ESCAPE '\\'
          OR LOWER(COALESCE(lastName, '')) LIKE ? ESCAPE '\\'
          OR LOWER(TRIM(COALESCE(firstName, '') || ' ' || COALESCE(lastName, ''))) LIKE ? ESCAPE '\\'
          OR LOWER(COALESCE(username, '')) LIKE ? ESCAPE '\\'
          """,
          arguments: [pattern, pattern, pattern, pattern]
        )
        .order(
          sql: """
          CASE WHEN "user".id IN (
            SELECT peerUserId FROM chat
            WHERE peerUserId IS NOT NULL
          ) THEN 0 ELSE 1 END,
          "user".id
          """
        )
        .limit(limit)
        .fetchAll(db)
    }
  }

  public static func remoteSearchIsEligible(query: String) -> Bool {
    let needle = normalizedQuery(query)
    return needle.count >= 2 && !needle.contains("@") && !looksLikePhone(needle)
  }

  public static func localUserMatches(
    _ userInfo: UserInfo,
    query: String,
    includeEmail: Bool = false
  ) -> Bool {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query != "@" else { return false }
    guard !query.isEmpty else { return true }
    let name = "\(userInfo.user.firstName ?? "") \(userInfo.user.lastName ?? "")"
      .trimmingCharacters(in: .whitespaces)
    let usernameQuery = query.trimmingPrefix("@")
    return name.localizedCaseInsensitiveContains(query) ||
      (userInfo.user.username?.localizedCaseInsensitiveContains(usernameQuery) == true) ||
      (includeEmail && userInfo.user.email?.localizedCaseInsensitiveContains(query) == true)
  }

  public static func mergedUsers(
    local: [UserInfo],
    remote: [UserInfo],
    excluding excludedUserIDs: Set<Int64> = [],
    limit: Int? = nil
  ) -> [UserInfo] {
    if let limit, limit <= 0 { return [] }
    var seen = excludedUserIDs
    var merged: [UserInfo] = []
    merged.reserveCapacity(min(local.count + remote.count, limit ?? .max))

    for userInfo in local + remote where seen.insert(userInfo.id).inserted {
      merged.append(userInfo)
      if let limit, merged.count >= limit { break }
    }
    return merged
  }

  public static func remoteUsers(
    query: String,
    realtime: RealtimeV2,
    database: AppDatabase = .shared,
    limit: Int32 = 20
  ) async throws -> [UserInfo] {
    let needle = normalizedQuery(query)
    guard remoteSearchIsEligible(query: query) else { return [] }
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
