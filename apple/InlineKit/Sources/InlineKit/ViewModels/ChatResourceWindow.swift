import Auth
import Combine
import Foundation
import GRDB
import InlineCompat
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
  private let account: AuthAccountMutationToken?
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
    self.account = account
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

  /// How many messages of this scope the chat holds, counted by the server, leaving out history
  /// the viewer cleared. Unlike `rows`, it covers history that hasn't loaded. Servers before
  /// media counts reject the request; callers treat a failure as unknown.
  public func countRemote() async throws -> Int {
    guard let filter = scope.filter, scope != .links, let account else {
      throw ResourceWindowError.unsupportedResponse
    }
    let peer = peer
    let result = try await Api.realtime.callRpcDirect(
      method: .searchMessages,
      input: .searchMessages(.with {
        $0.peerID = peer.toInputPeer()
        $0.filter = filter
        $0.countOnly = true
      }),
      timeout: .seconds(30),
      accountToken: account
    )
    guard case let .searchMessages(response) = result, response.hasTotalCount else {
      throw ResourceWindowError.unsupportedResponse
    }
    return Int(response.totalCount)
  }

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
    // The observation re-reads on every commit that touches its tables, mostly with an
    // unchanged result. Publishing only real changes keeps tabs from regrouping and
    // re-rendering for unrelated writes.
    let visibleRows = Array(snapshot.rows.prefix(snapshot.limit))
    if visibleRows != rows {
      rows = visibleRows
    }
    holes = snapshot.holes
    hasMoreCachedRows = snapshot.rows.count > snapshot.limit
    if !loading, !needsLatest {
      if !hasMore {
        setLoadState(.complete)
      } else if loadState == .complete {
        setLoadState(.idle)
      }
      if loadState != .failed, requiresPage {
        Task { await requestDrain() }
      }
    }
  }

  /// `@Published` notifies on every assignment, equal or not.
  private func setLoadState(_ state: ChatResourceLoadState) {
    if loadState != state {
      loadState = state
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
    guard triggerWindow > 0, loadedMessageIds.contains(currentMessageId) else { return false }
    // Among the `triggerWindow` smallest distinct ids. Cells call this as they appear,
    // so it counts in one pass instead of sorting every loaded id.
    var older = Set<Int64>()
    for id in loadedMessageIds where id < currentMessageId {
      older.insert(id)
      if older.count >= triggerWindow { return false }
    }
    return true
  }

  /// Rows grouped by local day, newest day first; inside a day newest first, with the
  /// message id breaking ties. One calendar lookup per day boundary rather than one
  /// `Calendar.current` fetch and `startOfDay` per row.
  nonisolated static func dayGroups(
    _ rows: [Row],
    date: (Row) -> Date,
    messageID: (Row) -> Int64
  ) -> [(date: Date, rows: [Row])] {
    guard !rows.isEmpty else { return [] }
    let calendar = Calendar.current
    var buckets: [Date: [Row]] = [:]
    var day: DateInterval?
    for row in rows {
      let rowDate = date(row)
      if let current = day, rowDate >= current.start, rowDate < current.end {
        buckets[current.start, default: []].append(row)
        continue
      }
      let interval = calendar.dateInterval(of: .day, for: rowDate)
        ?? DateInterval(start: calendar.startOfDay(for: rowDate), duration: 0)
      day = interval
      buckets[interval.start, default: []].append(row)
    }
    return buckets
      .map { start, rows in
        (date: start, rows: rows.sorted { lhs, rhs in
          let lhsDate = date(lhs), rhsDate = date(rhs)
          if lhsDate != rhsDate { return lhsDate > rhsDate }
          return messageID(lhs) > messageID(rhs)
        })
      }
      .sorted { $0.date > $1.date }
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
