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

  enum ManualResult {
    case cleaned(chats: Int, folders: Int)
    case unavailable
    case failed
  }

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

  func cleanNow(
    realtimeV2: RealtimeV2,
    completion: @escaping (ManualResult) -> Void
  ) {
    startRun(
      realtimeV2: realtimeV2,
      policy: .manual,
      completion: completion
    )
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
    guard let timeout = AppSettings.shared.sidebarCleanupInterval.timeout else { return }
    startRun(realtimeV2: realtimeV2, policy: .automatic(timeout: timeout))
  }

  private func startRun(
    realtimeV2: RealtimeV2,
    policy: OpenChatsCleanupPolicy,
    completion: ((ManualResult) -> Void)? = nil
  ) {
    guard runTask == nil else {
      completion?(.unavailable)
      return
    }

    let id = UUID()
    runID = id
    runTask = Task { [weak self] in
      let result = await self?.cleanup(realtimeV2: realtimeV2, policy: policy) ?? .unavailable
      self?.clearRunTask(id: id)
      completion?(result)
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

  private func cleanup(
    realtimeV2: RealtimeV2,
    policy: OpenChatsCleanupPolicy
  ) async -> ManualResult {
    guard AppSettings.shared.sidebarAsInbox,
          allowsCleanup,
          let currentUserId = Auth.shared.getCurrentUserId()
    else {
      return .unavailable
    }

    let now = Date()

    do {
      let candidates = try await OpenChatsCleanup.candidates(
        policy: policy,
        now: now,
        currentUserID: currentUserId
      )
      let activeCandidates = candidates
        .filter { MainWindowOpenCoordinator.shared.hasActivePeer($0.peer) == false }

      let closeReadyIDs = activeCandidates
        .filter { MainWindowOpenCoordinator.shared.hasActivePeer($0.peer) == false }
        .map(\.dialogID)
      guard allowsCleanup else { return .unavailable }

      let commit = try await OpenChatsCleanup.commit(
        policy: policy,
        now: now,
        currentUserID: currentUserId,
        dialogIDs: closeReadyIDs
      )
      let peers = commit.closedPeers
        .filter { MainWindowOpenCoordinator.shared.hasActivePeer($0) == false }
      let emptyFolderIDs: [Int64] = switch policy {
      case .manual:
        commit.emptyFolderIDs
      case .automatic:
        []
      }

      log.info(
        "Cleaning up \(peers.count) stale sidebar chats and \(emptyFolderIDs.count) empty folders"
      )
      await queueCloseRequests(peers, realtimeV2: realtimeV2)
      await queueFolderDeletions(emptyFolderIDs, realtimeV2: realtimeV2)
      return .cleaned(chats: peers.count, folders: emptyFolderIDs.count)
    } catch is CancellationError {
      return .unavailable
    } catch {
      log.error("Failed to clean up sidebar", error: error)
      return .failed
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

  private func queueFolderDeletions(_ folderIDs: [Int64], realtimeV2: RealtimeV2) async {
    await withTaskGroup(of: Void.self) { group in
      for folderID in folderIDs {
        group.addTask {
          _ = await realtimeV2.sendQueued(.deleteDialogFolder(
            folderId: folderID,
            disposition: .keepDialogs
          ))
        }
      }

      await group.waitForAll()
    }

    log.trace("Queued \(folderIDs.count) empty sidebar folder deletions")
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

}
