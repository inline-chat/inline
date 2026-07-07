import Auth
import Foundation
import GRDB
import InlineKit
import Logger
import RealtimeV2

@MainActor
final class SidebarCleanup {
  // TODO: Add proper transaction batching; this class only batches the local clear so rows disappear together.
  static let shared = SidebarCleanup()

  private static let checkIntervalSeconds: Int64 = 15 * 60

  private let log = Log.scoped("SidebarCleanup")
  private var owners = Set<UUID>()
  private var preconditionsByOwner: [UUID: Preconditions] = [:]
  private var loopTask: Task<Void, Never>?
  private var runTask: Task<Void, Never>?
  private var loopID: UUID?
  private var runID: UUID?

  private init() {}

  struct Preconditions {
    let hasFetchedServerState: Bool
    let isFetchingServerState: Bool
    let realtimeConnectionState: RealtimeConnectionState

    var allowsCleanup: Bool {
      guard hasFetchedServerState, isFetchingServerState == false else {
        return false
      }

      switch realtimeConnectionState {
      case .connected:
        return true
      case .connecting, .updating:
        return false
      }
    }
  }

  func activate(owner: UUID, realtimeV2: RealtimeV2, preconditions: Preconditions) {
    owners.insert(owner)
    preconditionsByOwner[owner] = preconditions
    configure(realtimeV2: realtimeV2)
  }

  func deactivate(owner: UUID) {
    owners.remove(owner)
    preconditionsByOwner.removeValue(forKey: owner)
    if owners.isEmpty {
      stop()
    }
  }

  func markOpened(_ peer: Peer, date: Date = Date()) {
    Task(priority: .utility) {
      do {
        try await Self.markOpened(peer, date: date)
      } catch {
        Log.shared.error("Failed to mark sidebar chat opened", error: error)
      }
    }
  }

  private func configure(realtimeV2: RealtimeV2) {
    guard owners.isEmpty == false,
          AppSettings.shared.sidebarAsInbox,
          AppSettings.shared.sidebarCleanupInterval.timeout != nil
    else {
      stop()
      return
    }

    startLoop(realtimeV2: realtimeV2)
    runNow(realtimeV2: realtimeV2)
  }

  private func startLoop(realtimeV2: RealtimeV2) {
    guard loopTask == nil else { return }

    let id = UUID()
    loopID = id
    loopTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(Self.checkIntervalSeconds))
        } catch {
          break
        }

        self?.runNow(realtimeV2: realtimeV2)
      }

      self?.clearLoopTask(id: id)
    }
  }

  private func runNow(realtimeV2: RealtimeV2) {
    guard runTask == nil else { return }

    let id = UUID()
    runID = id
    runTask = Task { [weak self] in
      await self?.cleanup(realtimeV2: realtimeV2)
      self?.clearRunTask(id: id)
    }
  }

  private func stop() {
    loopTask?.cancel()
    loopTask = nil
    loopID = nil
    runTask?.cancel()
    runTask = nil
    runID = nil
  }

  private func clearLoopTask(id: UUID) {
    guard loopID == id else { return }
    loopTask = nil
    loopID = nil
  }

  private func clearRunTask(id: UUID) {
    guard runID == id else { return }
    runTask = nil
    runID = nil
  }

  private func cleanup(realtimeV2: RealtimeV2) async {
    guard let timeout = AppSettings.shared.sidebarCleanupInterval.timeout,
          AppSettings.shared.sidebarAsInbox,
          allowsCleanup,
          let currentUserId = Auth.shared.getCurrentUserId()
    else {
      return
    }

    let now = Date()
    let cutoff = now.addingTimeInterval(-timeout)

    do {
      try await Self.stampMissingOpenedDates(date: now)
      let candidates = try await Self.staleOpenCandidates(cutoff: cutoff, currentUserId: currentUserId)
      let activeCandidates = candidates
        .filter { MainWindowOpenCoordinator.shared.hasActivePeer($0.peerId) == false }
      guard activeCandidates.isEmpty == false else { return }

      let closeReadyIDs = activeCandidates
        .filter { MainWindowOpenCoordinator.shared.hasActivePeer($0.peerId) == false }
        .map(\.id)
      guard closeReadyIDs.isEmpty == false else { return }

      let confirmedCandidates = try await Self.staleOpenCandidates(
        cutoff: cutoff,
        currentUserId: currentUserId,
        dialogIDs: closeReadyIDs
      )
      let stillCloseReadyIDs = confirmedCandidates
        .filter { MainWindowOpenCoordinator.shared.hasActivePeer($0.peerId) == false }
        .map(\.id)
      guard stillCloseReadyIDs.isEmpty == false else { return }
      guard allowsCleanup else { return }

      let closedCandidates = try await Self.closeStaleCandidates(
        cutoff: cutoff,
        currentUserId: currentUserId,
        dialogIDs: stillCloseReadyIDs
      )
      let peers = closedCandidates
        .filter { MainWindowOpenCoordinator.shared.hasActivePeer($0.peerId) == false }
        .map(\.peerId)
      guard peers.isEmpty == false else { return }

      log.info("Closing \(peers.count) stale sidebar chats")
      await queueCloseRequests(peers, realtimeV2: realtimeV2)
    } catch is CancellationError {
      return
    } catch {
      log.error("Failed to clean up sidebar", error: error)
    }
  }

  private var allowsCleanup: Bool {
    guard owners.isEmpty == false else { return false }
    guard preconditionsByOwner.isEmpty == false else { return false }
    return preconditionsByOwner.values.allSatisfy(\.allowsCleanup)
  }

  private func queueCloseRequests(_ peers: [Peer], realtimeV2: RealtimeV2) async {
    await withTaskGroup(of: Void.self) { group in
      for peer in peers {
        group.addTask {
          _ = await realtimeV2.sendQueued(.updateDialogOpen(peerId: peer, open: false))
        }
      }

      await group.waitForAll()
    }

    log.trace("Queued \(peers.count) stale sidebar close transactions")
  }

  nonisolated private static func markOpened(_ peer: Peer, date: Date) async throws {
    try await AppDatabase.shared.dbWriter.write { db in
      var arguments = StatementArguments([date])
      arguments += StatementArguments([Dialog.getDialogId(peerId: peer)])

      try db.execute(
        sql: """
        UPDATE "dialog"
        SET "openedDate" = ?
        WHERE "id" = ?
        """,
        arguments: arguments
      )
    }
  }

  nonisolated private static func stampMissingOpenedDates(date: Date) async throws {
    try await AppDatabase.shared.dbWriter.write { db in
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
  }

  nonisolated private static func staleOpenCandidates(
    cutoff: Date,
    currentUserId: Int64
  ) async throws -> [SidebarCleanupCandidate] {
    try await AppDatabase.shared.reader.read { db in
      try staleOpenCandidates(db, cutoff: cutoff, currentUserId: currentUserId, dialogIDs: nil)
    }
  }

  nonisolated private static func staleOpenCandidates(
    cutoff: Date,
    currentUserId: Int64,
    dialogIDs: [Int64]
  ) async throws -> [SidebarCleanupCandidate] {
    guard dialogIDs.isEmpty == false else { return [] }

    return try await AppDatabase.shared.reader.read { db in
      try staleOpenCandidates(db, cutoff: cutoff, currentUserId: currentUserId, dialogIDs: dialogIDs)
    }
  }

  nonisolated private static func closeStaleCandidates(
    cutoff: Date,
    currentUserId: Int64,
    dialogIDs: [Int64]
  ) async throws -> [SidebarCleanupCandidate] {
    guard dialogIDs.isEmpty == false else { return [] }

    return try await AppDatabase.shared.dbWriter.write { db in
      let candidates = try staleOpenCandidates(db, cutoff: cutoff, currentUserId: currentUserId, dialogIDs: dialogIDs)
      let ids = candidates.map(\.id)
      guard ids.isEmpty == false else { return [] }

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

      return candidates
    }
  }

  nonisolated private static func staleOpenCandidates(
    _ db: Database,
    cutoff: Date,
    currentUserId: Int64,
    dialogIDs: [Int64]?
  ) throws -> [SidebarCleanupCandidate] {
    if let dialogIDs, dialogIDs.isEmpty {
      return []
    }

    let dialogFilter = dialogIDs.map { ids in
      #"AND "dialog"."id" IN (\#(placeholders(count: ids.count)))"#
    } ?? ""

    var arguments = StatementArguments([currentUserId])
    arguments += StatementArguments([MessageSendingStatus.sent.rawValue])
    arguments += StatementArguments([cutoff])
    if let dialogIDs {
      arguments += StatementArguments(dialogIDs)
    }

    let request = SQLRequest<SidebarCleanupCandidate>(
      sql: """
      WITH "latestOwnMessage" AS (
        SELECT "message"."chatId", MAX("message"."date") AS "latestOwnMessageDate"
        FROM "message"
        WHERE "message"."fromId" = ?
        AND ("message"."status" IS NULL OR "message"."status" = ?)
        GROUP BY "message"."chatId"
      )
      SELECT
        "dialog"."id",
        "dialog"."peerUserId",
        "dialog"."peerThreadId"
      FROM "dialog"
      LEFT JOIN "chat" ON "chat"."id" = "dialog"."chatId"
      LEFT JOIN "latestOwnMessage" ON "latestOwnMessage"."chatId" = "dialog"."chatId"
      WHERE \(cleanupBaseSQL)
      AND "dialog"."openedDate" IS NOT NULL
      AND \(effectiveActivityDateSQL) <= ?
      AND NOT (\(Dialog.prominentUnreadSQL) AND \(Dialog.unreadSQL))
      \(dialogFilter)
      ORDER BY \(effectiveActivityDateSQL) ASC
      """,
      arguments: arguments
    )

    return try request.fetchAll(db)
  }

  nonisolated private static func placeholders(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
  }

  nonisolated private static var cleanupBaseSQL: String {
    """
    \(Dialog.chatListVisibilitySQL)
    AND "dialog"."open" = 1
    AND ("dialog"."pinned" IS NULL OR "dialog"."pinned" = 0)
    """
  }

  nonisolated private static var effectiveActivityDateSQL: String {
    """
    (
      CASE
        WHEN "latestOwnMessage"."latestOwnMessageDate" IS NULL THEN "dialog"."openedDate"
        WHEN "latestOwnMessage"."latestOwnMessageDate" > "dialog"."openedDate"
          THEN "latestOwnMessage"."latestOwnMessageDate"
        ELSE "dialog"."openedDate"
      END
    )
    """
  }
}

private struct SidebarCleanupCandidate: FetchableRecord, Decodable, Sendable {
  let id: Int64
  let peerUserId: Int64?
  let peerThreadId: Int64?

  var peerId: Peer {
    if let peerUserId {
      return .user(id: peerUserId)
    }
    if let peerThreadId {
      return .thread(id: peerThreadId)
    }
    return .thread(id: id)
  }
}
