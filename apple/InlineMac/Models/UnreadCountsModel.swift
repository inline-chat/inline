import Combine
import Foundation
import GRDB
import InlineKit
import Logger
import Observation

struct UnreadCountsSnapshot: Equatable, Sendable {
  static let empty = UnreadCountsSnapshot(
    unreadChatCount: 0,
    prominentUnreadChatCount: 0,
    scopedUnopenedProminentUnreadCount: 0,
    scopedUnopenedOtherUnreadCount: 0,
    prominentUnreadOutsideSelectedSpaceCount: 0
  )

  let unreadChatCount: Int
  let prominentUnreadChatCount: Int
  let scopedUnopenedProminentUnreadCount: Int
  let scopedUnopenedOtherUnreadCount: Int
  let prominentUnreadOutsideSelectedSpaceCount: Int
}

private struct UnreadCountsSidebarScope: Equatable, Sendable {
  var spaceId: Int64?
  var includeSpaceChatsInHome: Bool
}

@MainActor
@Observable
final class UnreadCountsModel {
  static let shared = UnreadCountsModel(database: .shared)

  private(set) var unreadChatCount = 0
  private(set) var prominentUnreadChatCount = 0
  private(set) var scopedUnopenedProminentUnreadCount = 0
  private(set) var scopedUnopenedOtherUnreadCount = 0
  private(set) var prominentUnreadOutsideSelectedSpaceCount = 0

  @ObservationIgnored private let database: AppDatabase
  @ObservationIgnored private let log = Log.scoped("UnreadCountsModel")
  @ObservationIgnored private let queue = DispatchQueue(
    label: "chat.inline.unread-counts",
    qos: .userInitiated
  )
  @ObservationIgnored private var cancellable: AnyCancellable?
  @ObservationIgnored private var pendingSnapshotTask: Task<Void, Never>?
  @ObservationIgnored private var immediateSnapshotGeneration: Int?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var sidebarScope = UnreadCountsSidebarScope(
    spaceId: nil,
    includeSpaceChatsInHome: true
  )

  private nonisolated static let snapshotDebounceNanoseconds: UInt64 = 250_000_000

  init(database: AppDatabase) {
    self.database = database
  }

  func start() {
    guard cancellable == nil else { return }

    #if DEBUG
    database.warnIfInMemoryDatabaseForObservation("UnreadCountsModel")
    #endif

    startObservation(applyFirstSnapshotImmediately: true)
  }

  func setSidebarScope(spaceId: Int64?, includeSpaceChatsInHome: Bool) {
    let scope = UnreadCountsSidebarScope(
      spaceId: spaceId,
      includeSpaceChatsInHome: includeSpaceChatsInHome
    )
    guard sidebarScope != scope else { return }

    sidebarScope = scope
    guard cancellable != nil else { return }
    startObservation(applyFirstSnapshotImmediately: true)
  }

  private func startObservation(applyFirstSnapshotImmediately: Bool) {
    generation += 1
    let observationGeneration = generation
    let scope = sidebarScope

    pendingSnapshotTask?.cancel()
    pendingSnapshotTask = nil
    immediateSnapshotGeneration = applyFirstSnapshotImmediately ? observationGeneration : nil
    cancellable?.cancel()

    cancellable = ValueObservation
      .tracking { database in
        try Self.fetchSnapshot(database, sidebarScope: scope)
      }
      .publisher(in: database.reader, scheduling: .async(onQueue: queue))
      .subscribe(on: queue)
      .sink(
        receiveCompletion: { [weak self] completion in
          guard case let .failure(error) = completion else { return }
          Task { @MainActor [weak self] in
            guard self?.generation == observationGeneration else { return }
            self?.log.error("Unread counts observation failed: \(error.localizedDescription)")
          }
        },
        receiveValue: { [weak self] snapshot in
          Task { @MainActor [weak self] in
            guard self?.generation == observationGeneration else { return }
            self?.applyOrDebounce(snapshot, generation: observationGeneration)
          }
        }
      )
  }

  func reset() {
    generation += 1
    pendingSnapshotTask?.cancel()
    pendingSnapshotTask = nil
    immediateSnapshotGeneration = nil
    cancellable?.cancel()
    cancellable = nil
    apply(.empty)
  }

  private func applyOrDebounce(_ snapshot: UnreadCountsSnapshot, generation observationGeneration: Int) {
    if immediateSnapshotGeneration == observationGeneration {
      immediateSnapshotGeneration = nil
      pendingSnapshotTask?.cancel()
      pendingSnapshotTask = nil
      apply(snapshot)
      return
    }

    scheduleApply(snapshot, generation: observationGeneration)
  }

  private func scheduleApply(_ snapshot: UnreadCountsSnapshot, generation observationGeneration: Int) {
    pendingSnapshotTask?.cancel()
    pendingSnapshotTask = Task { @MainActor [weak self] in
      // Server-side auto-open can arrive just after message delivery; debounce unread snapshots
      // so the All Chats badge does not briefly count a chat that is about to open in the sidebar.
      do {
        try await Task.sleep(nanoseconds: Self.snapshotDebounceNanoseconds)
        try Task.checkCancellation()
      } catch {
        return
      }

      guard let self, self.generation == observationGeneration else { return }
      pendingSnapshotTask = nil
      apply(snapshot)
    }
  }

  private func apply(_ snapshot: UnreadCountsSnapshot) {
    unreadChatCount = snapshot.unreadChatCount
    prominentUnreadChatCount = snapshot.prominentUnreadChatCount
    scopedUnopenedProminentUnreadCount = snapshot.scopedUnopenedProminentUnreadCount
    scopedUnopenedOtherUnreadCount = snapshot.scopedUnopenedOtherUnreadCount
    prominentUnreadOutsideSelectedSpaceCount = snapshot.prominentUnreadOutsideSelectedSpaceCount
  }

  private nonisolated static func fetchSnapshot(
    _ db: Database,
    sidebarScope: UnreadCountsSidebarScope
  ) throws -> UnreadCountsSnapshot {
    let sidebarScopeFilter = sidebarScopeSQL(sidebarScope)
    let outsideSelectedSpaceFilter = prominentOutsideSelectedSpaceSQL(spaceId: sidebarScope.spaceId)
    var arguments = StatementArguments()
    arguments += StatementArguments(sidebarScopeFilter.arguments)
    arguments += StatementArguments(outsideSelectedSpaceFilter.arguments)

    let request = SQLRequest<Row>(
      sql: """
      WITH "unreadDialogs" AS (
        SELECT
          \(prominentUnreadSQL) AS "isProminent",
          \(openInSidebarSQL) AS "isOpenInSidebar",
          \(sidebarScopeFilter.sql) AS "isInSidebarScope",
          \(outsideSelectedSpaceFilter.sql) AS "isOutsideSelectedSpace"
        FROM "dialog"
        LEFT JOIN "chat" ON "chat"."id" = "dialog"."chatId"
        WHERE \(Dialog.chatListVisibilitySQL)
        AND ("dialog"."archived" IS NULL OR "dialog"."archived" = 0)
        AND (COALESCE("dialog"."unreadCount", 0) > 0 OR "dialog"."unreadMark" = 1)
      )
      SELECT
        COUNT(*) AS "unreadChatCount",
        COALESCE(SUM(CASE WHEN "isProminent" THEN 1 ELSE 0 END), 0)
          AS "prominentUnreadChatCount",
        COALESCE(SUM(CASE WHEN "isProminent" AND NOT "isOpenInSidebar" AND "isInSidebarScope"
          THEN 1 ELSE 0 END), 0) AS "scopedUnopenedProminentUnreadCount",
        COALESCE(SUM(CASE WHEN NOT "isProminent" AND NOT "isOpenInSidebar" AND "isInSidebarScope"
          THEN 1 ELSE 0 END), 0) AS "scopedUnopenedOtherUnreadCount",
        COALESCE(SUM(CASE WHEN "isProminent" AND "isOutsideSelectedSpace"
          THEN 1 ELSE 0 END), 0) AS "prominentUnreadOutsideSelectedSpaceCount"
      FROM "unreadDialogs"
      """,
      arguments: arguments
    )

    guard let row = try request.fetchOne(db) else {
      return .empty
    }

    let unreadChatCount: Int = row["unreadChatCount"]
    let prominentUnreadChatCount: Int = row["prominentUnreadChatCount"]
    let scopedUnopenedProminentUnreadCount: Int = row["scopedUnopenedProminentUnreadCount"]
    let scopedUnopenedOtherUnreadCount: Int = row["scopedUnopenedOtherUnreadCount"]
    let prominentUnreadOutsideSelectedSpaceCount: Int = row["prominentUnreadOutsideSelectedSpaceCount"]

    return UnreadCountsSnapshot(
      unreadChatCount: unreadChatCount,
      prominentUnreadChatCount: prominentUnreadChatCount,
      scopedUnopenedProminentUnreadCount: scopedUnopenedProminentUnreadCount,
      scopedUnopenedOtherUnreadCount: scopedUnopenedOtherUnreadCount,
      prominentUnreadOutsideSelectedSpaceCount: prominentUnreadOutsideSelectedSpaceCount
    )
  }

  private nonisolated static let prominentUnreadSQL = """
  (
    "dialog"."peerUserId" IS NOT NULL
    OR COALESCE("dialog"."followMode" = 'following', 0)
    OR COALESCE("chat"."type" = 'private', 0)
  )
  """

  private nonisolated static let openInSidebarSQL = """
  (
    COALESCE("dialog"."open", 0) = 1
    OR COALESCE("dialog"."pinned", 0) = 1
  )
  """

  private nonisolated static func sidebarScopeSQL(
    _ scope: UnreadCountsSidebarScope
  ) -> (sql: String, arguments: [Int64]) {
    if let spaceId = scope.spaceId {
      return (
        """
        (
          COALESCE(COALESCE("dialog"."spaceId", "chat"."spaceId") = ?, 0)
          OR COALESCE("dialog"."peerUserId" IN (
            SELECT "member"."userId"
            FROM "member"
            WHERE "member"."spaceId" = ?
          ), 0)
        )
        """,
        [spaceId, spaceId]
      )
    }

    if scope.includeSpaceChatsInHome {
      return ("1 = 1", [])
    }

    return (
      """
      COALESCE("dialog"."spaceId", "chat"."spaceId") IS NULL
      """,
      []
    )
  }

  private nonisolated static func prominentOutsideSelectedSpaceSQL(
    spaceId: Int64?
  ) -> (sql: String, arguments: [Int64]) {
    guard let spaceId else {
      return ("0 = 1", [])
    }

    return (
      """
      NOT (
        COALESCE(COALESCE("dialog"."spaceId", "chat"."spaceId") = ?, 0)
        OR COALESCE("dialog"."peerUserId" IN (
          SELECT "member"."userId"
          FROM "member"
          WHERE "member"."spaceId" = ?
        ), 0)
      )
      """,
      [spaceId, spaceId]
    )
  }
}
