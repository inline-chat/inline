import Auth
import Combine
import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public enum ChatResourceLoadState: Equatable, Sendable {
  case idle
  case loading
  case failed
  case complete
}

struct ChatResourceSnapshot<Row: Equatable & Sendable>: Equatable, Sendable {
  var rows: [Row]
  var holes: [MessageHistoryHole]
  var limit: Int
}

/// A resource tab projects the canonical cache and its own coverage in one read.
/// Viewport demand survives a page that produces no new renderable rows.
@MainActor
public class ChatResourceWindow<Row: Equatable & Sendable>: ObservableObject, @unchecked Sendable {
  @Published public private(set) var rows: [Row] = [] {
    didSet { rowsDidChange() }
  }

  @Published public private(set) var loadState: ChatResourceLoadState = .idle

  private let db: AppDatabase
  private let peer: Peer
  private let chatId: Int64
  private let scope: MessageHistoryScope
  private let fetchRows: @Sendable (Database, Int) throws -> [Row]
  private let messageID: @Sendable (Row) -> Int64
  private let fetchPage: @Sendable (Int64?) async throws -> Void
  private let pageSize: Int32 = 50
  private var observation: AnyCancellable?
  private var observationGeneration = 0
  private var holes: [MessageHistoryHole] = []
  private var hasMoreCachedRows = false
  private var wantedCount = 50
  private var needsLatest = true
  private var active = false
  private var activationGeneration = 0
  private var loadTask: (id: UUID, task: Task<Void, Never>)?
  private var loading = false

  public var isEmptyConfirmed: Bool {
    rows.isEmpty && loadState == .complete
  }

  public var hasMore: Bool {
    needsLatest || !holes.isEmpty || hasMoreCachedRows
  }

  public init(
    db: AppDatabase,
    chatId: Int64,
    peer: Peer,
    scope: MessageHistoryScope,
    fetchRows: @escaping @Sendable (Database, Int) throws -> [Row],
    messageID: @escaping @Sendable (Row) -> Int64,
    fetchPage: (@Sendable (Int64?) async throws -> Void)? = nil
  ) {
    self.db = db
    self.chatId = chatId
    self.peer = peer
    self.scope = scope
    self.fetchRows = fetchRows
    self.messageID = messageID
    let account = try? Auth.shared.handle.beginAccountMutation()
    self.fetchPage = fetchPage ?? { offset in
      guard let account else { throw ResourceWindowError.unsupportedResponse }
      let hasChat = try await db.reader.read { try Chat.getByPeerId(db: $0, peerId: peer) != nil }
      if !hasChat {
        _ = try await Api.realtime.send(.getChat(peer: peer), expectedAccount: account)
      }
      let result = try await Api.realtime.send(.searchMessages(
        peer: peer, queries: [], offsetID: offset, limit: 50, filter: scope.filter
      ), expectedAccount: account)
      guard case let .searchMessages(response) = result, response.hasSeq else {
        throw ResourceWindowError.unsupportedResponse
      }
    }
  }

  public func rowsDidChange() {}

  private func observe() {
    guard active else { return }
    observationGeneration += 1
    let generation = observationGeneration
    observation?.cancel()
    let chatId = chatId
    let scope = scope
    let count = wantedCount
    let fetchRows = fetchRows
    observation = ValueObservation.tracking { db in
      try ChatResourceSnapshot(
        rows: fetchRows(db, count + 1),
        holes: MessageHistoryCoverageStore.holes(db, chatId: chatId, scope: scope),
        limit: count
      )
    }
    // GRDB's immediate scheduler synchronously reads the writer during sink.
    // Async scheduling starts that read on the DB queue and publishes on main.
    .publisher(in: db.dbWriter, scheduling: .async(onQueue: .main))
    .sink(
      receiveCompletion: { [weak self] completion in
        guard let self, observationGeneration == generation else { return }
        if case let .failure(error) = completion {
          Log.shared.error("Failed to observe chat resources", error: error)
          // Async main scheduling delivers completion after sink assignment.
          observation = nil
          loadState = .failed
        }
      },
      receiveValue: { [weak self] snapshot in
        guard let self, observationGeneration == generation else { return }
        receive(snapshot)
      }
    )
  }

  private func receive(_ snapshot: ChatResourceSnapshot<Row>) {
    guard active, snapshot.limit == wantedCount else { return }
    rows = Array(snapshot.rows.prefix(snapshot.limit))
    holes = snapshot.holes
    hasMoreCachedRows = snapshot.rows.count > snapshot.limit
    if !loading, !needsLatest {
      if !hasMore {
        loadState = .complete
      } else if loadState == .complete {
        loadState = .idle
      }
      if loadState != .failed, requiresPage {
        Task { await requestDrain() }
      }
    }
  }

  private var requiresPage: Bool {
    if needsLatest {
      return true
    }
    guard !holes.isEmpty else { return false }
    if rows.count < wantedCount {
      return true
    }
    // Sparse canonical cache rows do not skip an unknown interval inside the
    // visible window. Certify its whole prefix before advancing farther back.
    guard let oldest = rows.map(messageID).filter({ $0 > 0 }).min() else { return true }
    return holes.contains { $0.upperId >= oldest }
  }

  private func refreshSnapshot() async throws {
    let chatId = chatId
    let scope = scope
    let count = wantedCount
    let fetchRows = fetchRows
    let snapshot = try await db.reader.read { db in
      try ChatResourceSnapshot(
        rows: fetchRows(db, count + 1),
        holes: MessageHistoryCoverageStore.holes(db, chatId: chatId, scope: scope),
        limit: count
      )
    }
    receive(snapshot)
  }

  /// Start the cache projection only when this pane is visible.
  public func activate() {
    guard !active else { return }
    active = true
    activationGeneration += 1
    needsLatest = true
    observe()
  }

  public func loadInitial() async {
    guard !Task.isCancelled else { return }
    activate()
    await requestDrain()
  }

  public func deactivate() {
    active = false
    activationGeneration += 1
    observationGeneration += 1
    observation?.cancel()
    observation = nil
    loadTask?.task.cancel()
    loadState = .idle
  }

  public func loadMoreIfNeeded(currentMessageId: Int64) async {
    guard Self.shouldLoadMore(
      currentMessageId: currentMessageId,
      loadedMessageIds: rows.map(messageID),
      triggerWindow: 8
    ) else { return }
    await loadMore()
  }

  public func loadMore() async {
    guard active else { return }
    wantedCount = max(wantedCount, rows.count + Int(pageSize))
    observe()
    await requestDrain()
  }

  public func retry() async {
    guard active else { return }
    if observation == nil {
      observe()
    }
    await requestDrain()
  }

  nonisolated static func shouldLoadMore(
    currentMessageId: Int64,
    loadedMessageIds: [Int64],
    triggerWindow: Int
  ) -> Bool {
    guard triggerWindow > 0, !loadedMessageIds.isEmpty else { return false }
    return Set(loadedMessageIds).sorted().prefix(triggerWindow).contains(currentMessageId)
  }

  nonisolated static func nextOffset(holes: [MessageHistoryHole]) -> Int64? {
    guard let newest = holes.max(by: { $0.upperId < $1.upperId }),
          newest.upperId < MessageHistoryHole.positiveMessageIDMax
    else { return nil }
    return newest.upperId + 1
  }

  private func fetchPageWithFreshAdmission(_ offset: Int64?) async throws {
    // Sync can legitimately invalidate a token while reaching the page's
    // witness. Each send prepares a fresh token; failed admission never moves
    // this raw cursor or discards the retained viewport demand.
    for attempt in 0 ..< 3 {
      do { try await fetchPage(offset)
        return
      } catch TransactionExecutionError.staleHistory {
        if attempt == 2 {
          throw TransactionExecutionError.staleHistory
        }
        try Task.checkCancellation()
      }
    }
  }

  private func requestDrain() async {
    if let current = loadTask {
      await withTaskCancellationHandler { await current.task.value } onCancel: { current.task.cancel() }
    }
    guard active, !Task.isCancelled, loadTask == nil, chatId > 0 else { return }
    let id = UUID()
    let generation = activationGeneration
    let task = Task<Void, Never> { [weak self] in
      await self?.drainDemand(id: id, generation: generation)
    }
    loadTask = (id, task)
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }

  private func drainDemand(id: UUID, generation: Int) async {
    loading = true
    loadState = .loading
    defer {
      if loadTask?.id == id {
        loadTask = nil
      }
      loading = false
      if active, activationGeneration == generation, loadState == .loading {
        loadState = hasMore ? .idle : .complete
      }
    }

    do {
      try await refreshSnapshot()
      while active, activationGeneration == generation, requiresPage {
        try Task.checkCancellation()
        let wasLatest = needsLatest
        let previousHoles = holes
        let offset = wasLatest ? nil : Self.nextOffset(holes: holes)
        try await fetchPageWithFreshAdmission(offset)
        try Task.checkCancellation()
        guard active, activationGeneration == generation else { return }
        // send completes after transaction admission. Read committed rows and
        // coverage together rather than counting raw results as displayed cells.
        needsLatest = false
        try await refreshSnapshot()
        if !wasLatest, previousHoles == holes {
          throw ResourceWindowError.noProgress
        }
      }
    } catch is CancellationError {
      if active, activationGeneration == generation {
        loadState = .idle
      }
    } catch {
      if active, activationGeneration == generation {
        Log.shared.error("Failed to load chat resources", error: error)
        loadState = .failed
      }
    }
  }
}

private enum ResourceWindowError: Error {
  case unsupportedResponse
  case noProgress
}
