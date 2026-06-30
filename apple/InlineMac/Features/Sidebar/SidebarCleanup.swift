import Foundation
import GRDB
import InlineKit
import Logger
import RealtimeV2

@MainActor
final class SidebarCleanup {
  static let shared = SidebarCleanup()

  private static let checkIntervalSeconds: Int64 = 15 * 60

  private let log = Log.scoped("SidebarCleanup")
  private var owners = Set<UUID>()
  private var loopTask: Task<Void, Never>?
  private var runTask: Task<Void, Never>?
  private var loopID: UUID?
  private var runID: UUID?

  private init() {}

  func activate(owner: UUID, realtimeV2: RealtimeV2) {
    owners.insert(owner)
    configure(realtimeV2: realtimeV2)
  }

  func deactivate(owner: UUID) {
    owners.remove(owner)
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
          AppSettings.shared.sidebarAsInbox
    else {
      return
    }

    let now = Date()
    let cutoff = now.addingTimeInterval(-timeout)

    do {
      try await Self.stampMissingOpenedDates(date: now)
      let peers = try await Self.staleOpenPeers(cutoff: cutoff)
      guard peers.isEmpty == false else { return }

      log.info("Closing \(peers.count) stale sidebar chats")
      for peer in peers {
        try Task.checkCancellation()
        guard MainWindowOpenCoordinator.shared.hasActivePeer(peer) == false else { continue }
        guard try await Self.isStillStale(peer: peer, cutoff: cutoff) else { continue }
        guard MainWindowOpenCoordinator.shared.hasActivePeer(peer) == false else { continue }

        do {
          _ = try await realtimeV2.send(.updateDialogOpen(peerId: peer, open: false))
        } catch {
          log.error("Failed to close stale sidebar chat", error: error)
        }
      }
    } catch is CancellationError {
      return
    } catch {
      log.error("Failed to clean up sidebar", error: error)
    }
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
      var dialogs = try cleanupDialogRequest(extraSQL: #""dialog"."openedDate" IS NULL"#)
        .fetchAll(db)

      for index in dialogs.indices {
        dialogs[index].openedDate = date
        try dialogs[index].save(db, onConflict: .replace)
      }
    }
  }

  nonisolated private static func staleOpenPeers(cutoff: Date) async throws -> [Peer] {
    try await AppDatabase.shared.reader.read { db in
      try cleanupDialogRequest(
        extraSQL: #""dialog"."openedDate" IS NOT NULL AND "dialog"."openedDate" <= ?"#,
        arguments: StatementArguments([cutoff])
      )
      .order(Column("openedDate").asc)
      .fetchAll(db)
      .map(\.peerId)
    }
  }

  nonisolated private static func isStillStale(peer: Peer, cutoff: Date) async throws -> Bool {
    try await AppDatabase.shared.reader.read { db in
      var arguments = StatementArguments([Dialog.getDialogId(peerId: peer)])
      arguments += StatementArguments([cutoff])

      let request = SQLRequest<Int>(
        sql: """
        SELECT COUNT(*)
        FROM "dialog"
        WHERE "dialog"."id" = ?
        AND \(cleanupBaseSQL)
        AND "dialog"."openedDate" IS NOT NULL
        AND "dialog"."openedDate" <= ?
        """,
        arguments: arguments
      )

      return (try request.fetchOne(db) ?? 0) > 0
    }
  }

  nonisolated private static func cleanupDialogRequest(
    extraSQL: String,
    arguments: StatementArguments = StatementArguments()
  ) -> QueryInterfaceRequest<Dialog> {
    Dialog
      .filter(sql: cleanupBaseSQL)
      .filter(sql: extraSQL, arguments: arguments)
  }

  nonisolated private static var cleanupBaseSQL: String {
    """
    \(Dialog.chatListVisibilitySQL)
    AND "dialog"."open" = 1
    AND ("dialog"."pinned" IS NULL OR "dialog"."pinned" = 0)
    """
  }
}
