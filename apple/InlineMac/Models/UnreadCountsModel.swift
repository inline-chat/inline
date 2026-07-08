import Combine
import Foundation
import GRDB
import InlineKit
import Logger
import Observation

enum UnreadCountsTimeFrame: Equatable, Sendable {
  case today
  case lastDays(Int)
  case all

  func dateInterval(containing date: Date, calendar: Calendar) -> DateInterval? {
    switch self {
    case .all:
      return nil
    case .today:
      return dayInterval(containing: date, calendar: calendar)
    case let .lastDays(days):
      let clampedDays = max(days, 1)
      let todayStart = calendar.startOfDay(for: date)
      let start = calendar.date(byAdding: .day, value: 1 - clampedDays, to: todayStart)
        ?? todayStart.addingTimeInterval(TimeInterval(1 - clampedDays) * 86_400)
      let end = calendar.date(byAdding: .day, value: 1, to: todayStart)
        ?? todayStart.addingTimeInterval(86_400)
      return DateInterval(start: start, end: end)
    }
  }

  func nextRefreshDate(after date: Date, calendar: Calendar) -> Date? {
    switch self {
    case .all:
      return nil
    case .today, .lastDays:
      let start = calendar.startOfDay(for: date)
      return calendar.date(byAdding: .day, value: 1, to: start)
        ?? start.addingTimeInterval(86_400)
    }
  }

  private func dayInterval(containing date: Date, calendar: Calendar) -> DateInterval {
    let start = calendar.startOfDay(for: date)
    let end = calendar.date(byAdding: .day, value: 1, to: start)
      ?? start.addingTimeInterval(86_400)
    return DateInterval(start: start, end: end)
  }
}

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
  var nonProminentUnreadTimeFrame: UnreadCountsTimeFrame
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
  @ObservationIgnored private var timeFrameBoundaryTask: Task<Void, Never>?
  @ObservationIgnored private var immediateSnapshotGeneration: Int?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var sidebarScope = UnreadCountsSidebarScope(
    spaceId: nil,
    includeSpaceChatsInHome: true,
    nonProminentUnreadTimeFrame: .today
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

  func setSidebarScope(
    spaceId: Int64?,
    includeSpaceChatsInHome: Bool,
    nonProminentUnreadTimeFrame: UnreadCountsTimeFrame = .today
  ) {
    let scope = UnreadCountsSidebarScope(
      spaceId: spaceId,
      includeSpaceChatsInHome: includeSpaceChatsInHome,
      nonProminentUnreadTimeFrame: nonProminentUnreadTimeFrame
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
    scheduleTimeFrameBoundaryRefresh(for: scope, generation: observationGeneration)

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
    timeFrameBoundaryTask?.cancel()
    timeFrameBoundaryTask = nil
    immediateSnapshotGeneration = nil
    cancellable?.cancel()
    cancellable = nil
    apply(.empty)
  }

  private func scheduleTimeFrameBoundaryRefresh(
    for scope: UnreadCountsSidebarScope,
    generation observationGeneration: Int
  ) {
    timeFrameBoundaryTask?.cancel()

    guard let refreshDate = scope.nonProminentUnreadTimeFrame.nextRefreshDate(
      after: Date(),
      calendar: .autoupdatingCurrent
    ) else {
      timeFrameBoundaryTask = nil
      return
    }

    timeFrameBoundaryTask = Task { @MainActor [weak self] in
      let delay = max(0, refreshDate.timeIntervalSinceNow + 1)
      do {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        try Task.checkCancellation()
      } catch {
        return
      }

      guard let self else { return }
      guard self.generation == observationGeneration else { return }
      guard self.sidebarScope == scope else { return }
      guard self.cancellable != nil else { return }
      self.startObservation(applyFirstSnapshotImmediately: true)
    }
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
    let previous = UnreadCountsSnapshot(
      unreadChatCount: unreadChatCount,
      prominentUnreadChatCount: prominentUnreadChatCount,
      scopedUnopenedProminentUnreadCount: scopedUnopenedProminentUnreadCount,
      scopedUnopenedOtherUnreadCount: scopedUnopenedOtherUnreadCount,
      prominentUnreadOutsideSelectedSpaceCount: prominentUnreadOutsideSelectedSpaceCount
    )
    let prominentChanged = previous.prominentUnreadChatCount != snapshot.prominentUnreadChatCount
    let scopedProminentChanged = previous.scopedUnopenedProminentUnreadCount !=
      snapshot.scopedUnopenedProminentUnreadCount
    if prominentChanged || scopedProminentChanged {
      log.info(
        "[UnreadDiag] unread_counts prominent=\(previous.prominentUnreadChatCount)->\(snapshot.prominentUnreadChatCount) unreadChats=\(previous.unreadChatCount)->\(snapshot.unreadChatCount) scopedProminent=\(previous.scopedUnopenedProminentUnreadCount)->\(snapshot.scopedUnopenedProminentUnreadCount)"
      )
    }

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
    let nonProminentTimeFrameFilter = nonProminentUnreadTimeFrameSQL(
      sidebarScope.nonProminentUnreadTimeFrame
    )
    var arguments = StatementArguments()
    arguments += StatementArguments(sidebarScopeFilter.arguments)
    arguments += StatementArguments(outsideSelectedSpaceFilter.arguments)
    arguments += nonProminentTimeFrameFilter.arguments

    let request = SQLRequest<Row>(
      sql: """
      WITH "unreadDialogs" AS (
        SELECT
          \(Dialog.prominentUnreadSQL) AS "isProminent",
          \(openInSidebarSQL) AS "isOpenInSidebar",
          \(sidebarScopeFilter.sql) AS "isInSidebarScope",
          \(outsideSelectedSpaceFilter.sql) AS "isOutsideSelectedSpace",
          \(nonProminentTimeFrameFilter.sql) AS "isInNonProminentTimeFrame"
        FROM "dialog"
        LEFT JOIN "chat" ON "chat"."id" = "dialog"."chatId"
        LEFT JOIN "message" AS "lastMessage"
          ON "lastMessage"."chatId" = "chat"."id"
          AND "lastMessage"."messageId" = "chat"."lastMsgId"
        WHERE \(Dialog.chatListVisibilitySQL)
        AND ("dialog"."archived" IS NULL OR "dialog"."archived" = 0)
        AND \(Dialog.unreadSQL)
      )
      SELECT
        COUNT(*) AS "unreadChatCount",
        COALESCE(SUM(CASE WHEN "isProminent" THEN 1 ELSE 0 END), 0)
          AS "prominentUnreadChatCount",
        COALESCE(SUM(CASE WHEN "isProminent" AND NOT "isOpenInSidebar" AND "isInSidebarScope"
          THEN 1 ELSE 0 END), 0) AS "scopedUnopenedProminentUnreadCount",
        COALESCE(SUM(CASE WHEN NOT "isProminent" AND NOT "isOpenInSidebar" AND "isInSidebarScope"
          AND "isInNonProminentTimeFrame"
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

  private nonisolated static func nonProminentUnreadTimeFrameSQL(
    _ timeFrame: UnreadCountsTimeFrame
  ) -> (sql: String, arguments: StatementArguments) {
    guard let interval = timeFrame.dateInterval(
      containing: Date(),
      calendar: .autoupdatingCurrent
    ) else {
      return ("1 = 1", StatementArguments())
    }

    return (
      """
      (
        COALESCE("lastMessage"."date", "chat"."date") >= ?
        AND COALESCE("lastMessage"."date", "chat"."date") < ?
      )
      """,
      StatementArguments([interval.start, interval.end])
    )
  }
}
