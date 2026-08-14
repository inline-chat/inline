import Foundation
import GRDB
import InlineKit
import InlineSearch
import Logger
import os.signpost

actor CommandBarCatalogService {
  struct ProjectionRequest: Sendable {
    let query: String
    let usage: [Peer: InlineSearchUsageSignal]
    let currentPeer: Peer?
    let currentUserID: Int64?
    let contextSpaceId: Int64?
    let scope: InlineSearchScope
    let suggestionLimit: Int
    let chatLimit: Int
    let includeSpaces: Bool
  }

  struct Projection: Sendable {
    let chats: InlineSearchChatProjection
    let spaces: [Space]
  }

  private struct Refresh {
    let id: UUID
    let generation: UInt64
    let targetRevision: UInt64
    let signpostID: OSSignpostID
    let task: Task<FetchResult, Never>
  }

  private enum FetchResult: Sendable {
    case success(CommandBarCatalogSnapshot)
    case failure(String)
  }

  private let database: AppDatabase
  private let catalog = InlineSearchChatCatalog()
  private let log = Log.scoped("CommandBarCatalogService")
  private let performanceLog = OSLog(subsystem: "InlineMac", category: "PointsOfInterest")

  private var observation: AnyDatabaseCancellable?
  private var invalidationContinuations: [UUID: AsyncStream<UInt64>.Continuation] = [:]
  private var refresh: Refresh?
  private var generation: UInt64 = 0
  private var dirtyRevision: UInt64 = 1
  private var loadedRevision: UInt64 = 0
  private var spaces: [Space] = []

  init(database: AppDatabase) {
    self.database = database
  }

  func start() async -> UInt64 {
    installObservationIfNeeded()
    return await refreshIfNeeded()
  }

  private func refreshIfNeeded() async -> UInt64 {
    let requestGeneration = generation
    while loadedRevision != dirtyRevision {
      guard Task.isCancelled == false, generation == requestGeneration else { return loadedRevision }
      let currentRefresh: Refresh
      if let refresh {
        currentRefresh = refresh
      } else {
        let id = UUID()
        let generation = generation
        let targetRevision = dirtyRevision
        let signpostID = OSSignpostID(log: performanceLog)
        let database = database
        let task = Task.detached(priority: .utility) {
          do {
            let snapshot = try await database.fetchCommandBarCatalogSnapshot()
            guard Task.isCancelled == false else { return FetchResult.failure("cancelled") }
            return .success(snapshot)
          } catch is CancellationError {
            return .failure("cancelled")
          } catch {
            return .failure(error.localizedDescription)
          }
        }
        currentRefresh = Refresh(
          id: id,
          generation: generation,
          targetRevision: targetRevision,
          signpostID: signpostID,
          task: task
        )
        refresh = currentRefresh
        os_signpost(
          .begin,
          log: performanceLog,
          name: "CommandBarCatalogRefresh",
          signpostID: signpostID,
          "revision=%{public}llu",
          targetRevision
        )
      }

      let result = await currentRefresh.task.value
      if Task.isCancelled {
        if refresh?.id == currentRefresh.id, invalidationContinuations.isEmpty {
          refresh = nil
          os_signpost(
            .end,
            log: performanceLog,
            name: "CommandBarCatalogRefresh",
            signpostID: currentRefresh.signpostID,
            "revision=%{public}llu cancelled=1",
            currentRefresh.targetRevision
          )
        }
        return loadedRevision
      }
      guard generation == requestGeneration else { return loadedRevision }
      guard refresh?.id == currentRefresh.id else { continue }
      refresh = nil
      guard generation == currentRefresh.generation else { return loadedRevision }

      switch result {
      case let .success(snapshot):
        await catalog.replace(snapshot.chats, knownUsers: snapshot.knownUsers)
        spaces = snapshot.spaces
        loadedRevision = currentRefresh.targetRevision
        os_signpost(
          .end,
          log: performanceLog,
          name: "CommandBarCatalogRefresh",
          signpostID: currentRefresh.signpostID,
          "revision=%{public}llu entries=%{public}ld",
          loadedRevision,
          snapshot.chats.count + snapshot.knownUsers.count
        )

      case let .failure(description):
        os_signpost(
          .end,
          log: performanceLog,
          name: "CommandBarCatalogRefresh",
          signpostID: currentRefresh.signpostID,
          "revision=%{public}llu failed=1",
          currentRefresh.targetRevision
        )
        if description == "cancelled", invalidationContinuations.isEmpty == false {
          continue
        }
        if description != "cancelled" {
          log.error("Failed to refresh command-bar catalog: \(description)")
        }
        return loadedRevision
      }
    }

    return loadedRevision
  }

  func invalidations() -> AsyncStream<UInt64> {
    let id = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      invalidationContinuations[id] = continuation
      continuation.yield(dirtyRevision)
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeInvalidationContinuation(id: id) }
      }
    }
  }

  func project(_ request: ProjectionRequest) async -> Projection {
    let chats = await catalog.project(
      query: request.query,
      usage: request.usage,
      currentPeer: request.currentPeer,
      currentUserID: request.currentUserID,
      contextSpaceId: request.contextSpaceId,
      scope: request.scope,
      suggestionLimit: request.suggestionLimit,
      chatLimit: request.chatLimit
    )
    return Projection(
      chats: chats,
      spaces: request.includeSpaces ? projectSpaces(query: request.query, limit: 10) : []
    )
  }

  func reset() async {
    generation &+= 1
    observation?.cancel()
    observation = nil
    if let refresh {
      refresh.task.cancel()
      os_signpost(
        .end,
        log: performanceLog,
        name: "CommandBarCatalogRefresh",
        signpostID: refresh.signpostID,
        "revision=%{public}llu reset=1",
        refresh.targetRevision
      )
    }
    refresh = nil
    dirtyRevision = 1
    loadedRevision = 0
    for continuation in invalidationContinuations.values {
      continuation.finish()
    }
    invalidationContinuations.removeAll(keepingCapacity: false)
    await catalog.replace([])
    spaces = []
  }

  private func projectSpaces(query: String, limit: Int) -> [Space] {
    guard let preparedQuery = InlineSearchMatcher.prepare(query) else { return [] }
    return spaces
      .compactMap { space -> RankedSpace? in
        guard let match = InlineSearchMatcher.match(
          query: preparedQuery,
          fields: [
            InlineSearchField(space.displayName, priority: 500),
            InlineSearchField(space.name, priority: 400),
          ]
        ) else { return nil }
        return RankedSpace(space: space, match: match)
      }
      .sorted { lhs, rhs in
        if lhs.match != rhs.match {
          return InlineSearchMatch.isBetter(lhs.match, than: rhs.match)
        }
        let order = lhs.space.displayName.localizedCaseInsensitiveCompare(rhs.space.displayName)
        if order != .orderedSame {
          return order == .orderedAscending
        }
        return lhs.space.id < rhs.space.id
      }
      .prefix(max(0, limit))
      .map(\.space)
  }

  private func installObservationIfNeeded() {
    guard observation == nil else { return }
    database.warnIfInMemoryDatabaseForObservation("CommandBarCatalogService.invalidation")

    let region = DatabaseRegionObservation(tracking: [
      Table("dialog"),
      Table("chat"),
      Table("user"),
      Table("space"),
      Table("message"),
    ])
    observation = region.start(
      in: database.dbWriter,
      onError: { [weak self] error in
        let description = error.localizedDescription
        Task { await self?.recordObservationError(description) }
      },
      onChange: { [weak self] _ in
        Task { await self?.markDirty() }
      }
    )
  }

  private func markDirty() {
    dirtyRevision &+= 1
    for continuation in invalidationContinuations.values {
      continuation.yield(dirtyRevision)
    }
  }

  private func removeInvalidationContinuation(id: UUID) {
    invalidationContinuations.removeValue(forKey: id)
    if invalidationContinuations.isEmpty {
      refresh?.task.cancel()
    }
  }

  private func recordObservationError(_ description: String) {
    log.error("Command-bar catalog invalidation observation failed: \(description)")
    observation = nil
  }

  private struct RankedSpace {
    let space: Space
    let match: InlineSearchMatch
  }
}
