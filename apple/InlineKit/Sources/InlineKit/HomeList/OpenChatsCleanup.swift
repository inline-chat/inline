import Foundation
import GRDB

public enum OpenChatsCleanupPolicy: Equatable, Sendable {
  case manual
  case automatic(timeout: TimeInterval)

  public static let manualOpenedAge: TimeInterval = 6 * 60 * 60
  public static let manualActivityAge: TimeInterval = 3 * 60 * 60

  public func shouldClose(
    now: Date,
    openedAt: Date,
    lastActivityAt: Date?,
    latestOwnMessageAt: Date?,
    isEmptyUntitled: Bool
  ) -> Bool {
    if isEmptyUntitled {
      return true
    }

    switch self {
    case .manual:
      let openedCutoff = now.addingTimeInterval(-Self.manualOpenedAge)
      let activityCutoff = now.addingTimeInterval(-Self.manualActivityAge)
      return openedAt <= openedCutoff
        && (lastActivityAt ?? openedAt) <= activityCutoff

    case let .automatic(timeout):
      let cutoff = now.addingTimeInterval(-max(timeout, 0))
      return max(openedAt, latestOwnMessageAt ?? openedAt) <= cutoff
    }
  }
}

public struct OpenChatsCleanupCandidate: Equatable, Sendable {
  public let dialogID: Int64
  public let peer: Peer
}

public struct OpenChatsCleanupCommit: Equatable, Sendable {
  public let closedPeers: [Peer]
  public let emptyFolderIDs: [Int64]
}

/// Shared local selection and commit boundary for manual and automatic Open Chats cleanup.
/// Platform owners remain responsible for readiness checks and queuing the returned mutations.
public enum OpenChatsCleanup {
  public static func candidates(
    policy: OpenChatsCleanupPolicy,
    now: Date = Date(),
    currentUserID: Int64
  ) async throws -> [OpenChatsCleanupCandidate] {
    try await candidates(
      in: AppDatabase.shared,
      policy: policy,
      now: now,
      currentUserID: currentUserID
    )
  }

  public static func candidates(
    in database: AppDatabase,
    policy: OpenChatsCleanupPolicy,
    now: Date = Date(),
    currentUserID: Int64
  ) async throws -> [OpenChatsCleanupCandidate] {
    try await database.dbWriter.write { db in
      try stampMissingOpenedDates(db, date: now)
      return try staleOpenCandidates(
        db,
        policy: policy,
        now: now,
        currentUserID: currentUserID,
        dialogIDs: nil
      ).map(\.cleanupCandidate)
    }
  }

  /// Revalidates the selected dialogs, closes the surviving candidates locally as one write,
  /// then returns every folder with no remaining visible Open Chats member.
  public static func commit(
    policy: OpenChatsCleanupPolicy,
    now: Date,
    currentUserID: Int64,
    dialogIDs: [Int64]
  ) async throws -> OpenChatsCleanupCommit {
    try await commit(
      in: AppDatabase.shared,
      policy: policy,
      now: now,
      currentUserID: currentUserID,
      dialogIDs: dialogIDs
    )
  }

  public static func commit(
    in database: AppDatabase,
    policy: OpenChatsCleanupPolicy,
    now: Date,
    currentUserID: Int64,
    dialogIDs: [Int64]
  ) async throws -> OpenChatsCleanupCommit {
    try await database.dbWriter.write { db in
      let candidates = try staleOpenCandidates(
        db,
        policy: policy,
        now: now,
        currentUserID: currentUserID,
        dialogIDs: dialogIDs
      )
      let ids = candidates.map(\.dialogID)
      if ids.isEmpty == false {
        try db.execute(
          sql: """
          UPDATE "dialog"
          SET "open" = 0,
              "openedDate" = NULL,
              "order" = NULL
          WHERE "id" IN (\(placeholders(count: ids.count)))
          """,
          arguments: StatementArguments(ids)
        )
      }

      return OpenChatsCleanupCommit(
        closedPeers: candidates.map(\.peer),
        emptyFolderIDs: try emptyFolderIDs(db)
      )
    }
  }

  static func emptyFolderIDs(_ db: Database) throws -> [Int64] {
    try Int64.fetchAll(
      db,
      sql: """
      SELECT "dialogFolder"."id"
      FROM "dialogFolder"
      WHERE NOT EXISTS (
        SELECT 1
        FROM "dialog"
        WHERE "dialog"."folderId" = "dialogFolder"."id"
          AND "dialog"."open" = 1
          AND \(Dialog.chatListVisibilitySQL)
      )
      ORDER BY "dialogFolder"."id"
      """
    )
  }

  private static func stampMissingOpenedDates(_ db: Database, date: Date) throws {
    try db.execute(
      sql: """
      UPDATE "dialog"
      SET "openedDate" = ?
      WHERE \(cleanupBaseSQL)
        AND "dialog"."openedDate" IS NULL
      """,
      arguments: StatementArguments([date])
    )
  }

  private static func staleOpenCandidates(
    _ db: Database,
    policy: OpenChatsCleanupPolicy,
    now: Date,
    currentUserID: Int64,
    dialogIDs: [Int64]?
  ) throws -> [DatabaseCandidate] {
    if let dialogIDs, dialogIDs.isEmpty {
      return []
    }

    let dialogFilter = dialogIDs.map { ids in
      #"AND "dialog"."id" IN (\#(placeholders(count: ids.count)))"#
    } ?? ""

    var arguments = StatementArguments([currentUserID])
    arguments += StatementArguments([MessageSendingStatus.sent.rawValue])
    if let dialogIDs {
      arguments += StatementArguments(dialogIDs)
    }

    let request = SQLRequest<DatabaseCandidate>(
      sql: """
      WITH "latestOwnMessage" AS (
        SELECT "message"."chatId", MAX("message"."date") AS "latestOwnMessageDate"
        FROM "message"
        WHERE "message"."fromId" = ?
          AND ("message"."status" IS NULL OR "message"."status" = ?)
        GROUP BY "message"."chatId"
      )
      SELECT
        "dialog"."id" AS "dialogID",
        "dialog"."peerUserId" AS "peerUserID",
        "dialog"."peerThreadId" AS "peerThreadID",
        "dialog"."openedDate" AS "openedAt",
        "lastMessage"."date" AS "lastActivityAt",
        "latestOwnMessage"."latestOwnMessageDate",
        CASE WHEN
          "dialog"."peerThreadId" IS NOT NULL
          AND (
            COALESCE("chat"."isUntitled" = 1, 0)
            OR TRIM(COALESCE("chat"."title", '')) = ''
          )
          AND "chat"."lastMsgId" IS NULL
        THEN 1 ELSE 0 END AS "isEmptyUntitled"
      FROM "dialog"
      LEFT JOIN "chat" ON "chat"."id" = "dialog"."chatId"
      LEFT JOIN "latestOwnMessage" ON "latestOwnMessage"."chatId" = "dialog"."chatId"
      LEFT JOIN "message" AS "lastMessage"
        ON "lastMessage"."chatId" = "chat"."id"
        AND "lastMessage"."messageId" = "chat"."lastMsgId"
      LEFT JOIN "draft2" ON "draft2"."peerKey" = CASE
        WHEN "dialog"."peerUserId" IS NOT NULL
          THEN 'user_' || CAST("dialog"."peerUserId" AS TEXT)
        ELSE 'thread_' || CAST("dialog"."peerThreadId" AS TEXT)
      END
      WHERE \(cleanupBaseSQL)
        AND "dialog"."openedDate" IS NOT NULL
        AND ("chat"."lastMsgId" IS NULL OR "lastMessage"."date" IS NOT NULL)
        AND NOT (\(Dialog.unreadSQL))
        AND (
          "draft2"."peerKey" IS NULL
          OR (TRIM("draft2"."text") = '' AND "draft2"."attachments" IS NULL)
        )
        AND "dialog"."draftMessage" IS NULL
        \(dialogFilter)
      ORDER BY "dialog"."openedDate" ASC
      """,
      arguments: arguments
    )

    return try request.fetchAll(db).filter { candidate in
      policy.shouldClose(
        now: now,
        openedAt: candidate.openedAt,
        lastActivityAt: candidate.lastActivityAt,
        latestOwnMessageAt: candidate.latestOwnMessageDate,
        isEmptyUntitled: candidate.isEmptyUntitled
      )
    }
  }

  private static func placeholders(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
  }

  private static var cleanupBaseSQL: String {
    """
    \(Dialog.chatListVisibilitySQL)
    AND "dialog"."open" = 1
    AND ("dialog"."pinned" IS NULL OR "dialog"."pinned" = 0)
    AND NOT EXISTS (
      SELECT 1
      FROM "dialogFolder"
      WHERE "dialogFolder"."id" = "dialog"."folderId"
        AND "dialogFolder"."pinnedOrder" IS NOT NULL
    )
    """
  }
}

private struct DatabaseCandidate: FetchableRecord, Decodable, Sendable {
  let dialogID: Int64
  let peerUserID: Int64?
  let peerThreadID: Int64?
  let openedAt: Date
  let lastActivityAt: Date?
  let latestOwnMessageDate: Date?
  let isEmptyUntitled: Bool

  var peer: Peer {
    if let peerUserID {
      return .user(id: peerUserID)
    }
    if let peerThreadID {
      return .thread(id: peerThreadID)
    }
    return .thread(id: dialogID)
  }

  var cleanupCandidate: OpenChatsCleanupCandidate {
    OpenChatsCleanupCandidate(dialogID: dialogID, peer: peer)
  }
}
