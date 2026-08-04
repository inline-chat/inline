import Combine
import Foundation
import GRDB
import InlineKit
import Logger
import SwiftUI

struct ExperimentalHomeListConfiguration: Equatable, Sendable {
  let spaceID: Int64?
  let includeSpaceChatsInHome: Bool
  let sort: ChatListSort
}

struct ExperimentalHomeListState: Equatable, Sendable {
  static let loading = Self(
    presentation: .empty,
    isLoading: true,
    errorDescription: nil,
    revision: 0
  )

  let presentation: ChatListPresentation
  let isLoading: Bool
  let errorDescription: String?
  let revision: Int
}

@MainActor
final class ExperimentalHomeListStore: ObservableObject {
  @Published private(set) var state: ExperimentalHomeListState = .loading

  private let database: AppDatabase
  private let workerQueue = DispatchQueue(
    label: "chat.inline.ios-home-list",
    qos: .userInitiated
  )
  private let log = Log.scoped("ExperimentalHomeListStore")
  private var observation: AnyCancellable?
  private var pipeline: ExperimentalHomeListPipeline?
  private var configuration: ExperimentalHomeListConfiguration?
  private var generation = 0

  init(database: AppDatabase) {
    self.database = database
  }

  func setConfiguration(_ newConfiguration: ExperimentalHomeListConfiguration) {
    guard configuration != newConfiguration else { return }

    let scopeChanged = configuration.map {
      $0.spaceID != newConfiguration.spaceID
        || $0.includeSpaceChatsInHome != newConfiguration.includeSpaceChatsInHome
    } ?? true
    configuration = newConfiguration
    if scopeChanged {
      state = ExperimentalHomeListState(
        presentation: .empty,
        isLoading: true,
        errorDescription: nil,
        revision: state.revision + 1
      )
    }
    startObservation(configuration: newConfiguration)
  }

  func refresh() {
    guard let configuration else { return }
    startObservation(configuration: configuration)
  }

  private func startObservation(configuration: ExperimentalHomeListConfiguration) {
    generation += 1
    let observationGeneration = generation
    observation?.cancel()
    pipeline?.cancel()

    let initialPresentation = state.presentation == .empty ? nil : state.presentation
    let pipeline = ExperimentalHomeListPipeline(
      queue: workerQueue,
      configuration: configuration,
      initialPresentation: initialPresentation,
      emit: Self.makePipelineHandler(store: self, generation: observationGeneration)
    )
    self.pipeline = pipeline

    #if DEBUG
    database.warnIfInMemoryDatabaseForObservation("ExperimentalHomeListStore")
    #endif

    observation = ValueObservation
      .tracking { db in
        let startedAt = Date()
        let scopeLabel = configuration.spaceID == nil ? "home" : "space"
        let span = PerformanceTrace.begin(
          "HomeListQuery",
          category: .home,
          "space=\(scopeLabel)"
        )
        let snapshots = try ChatListDatabaseQuery.fetchSnapshots(
          db,
          spaceID: configuration.spaceID,
          includeSpaceChatsInHome: configuration.includeSpaceChatsInHome
        )
        let durationMs = PerformanceTrace.elapsedMilliseconds(since: startedAt)
        span.end("rows=\(snapshots.count) duration_ms=\(durationMs)")
        PerformanceTrace.slowBreadcrumb(
          "iOS Home list query was slow",
          category: "ios.home.query",
          durationMs: durationMs,
          thresholdMs: 50,
          data: ["rows": snapshots.count, "scope": scopeLabel]
        )
        return snapshots
      }
      .publisher(in: database.reader, scheduling: .async(onQueue: workerQueue))
      .subscribe(on: workerQueue)
      .removeDuplicates()
      .sink(
        receiveCompletion: Self.makeCompletionHandler(
          store: self,
          generation: observationGeneration
        ),
        receiveValue: Self.makeValueHandler(pipeline: pipeline)
      )
  }

  /// Construct worker callbacks outside the main-actor context. Swift otherwise
  /// inherits a main-executor precondition even though GRDB delivers on `workerQueue`.
  private nonisolated static func makeValueHandler(
    pipeline: ExperimentalHomeListPipeline
  ) -> @Sendable ([ChatListItemSnapshot]) -> Void {
    { snapshots in
      pipeline.submit(snapshots)
    }
  }

  private nonisolated static func makePipelineHandler(
    store: ExperimentalHomeListStore,
    generation: Int
  ) -> @Sendable (ExperimentalHomeListPreparedUpdate) -> Void {
    { [weak store] update in
      Task { @MainActor [weak store] in
        store?.apply(update, generation: generation)
      }
    }
  }

  private nonisolated static func makeCompletionHandler(
    store: ExperimentalHomeListStore,
    generation: Int
  ) -> @Sendable (Subscribers.Completion<any Error>) -> Void {
    { [weak store] completion in
      guard case let .failure(error) = completion else { return }
      Task { @MainActor [weak store] in
        store?.apply(error, generation: generation)
      }
    }
  }

  private func apply(
    _ update: ExperimentalHomeListPreparedUpdate,
    generation observationGeneration: Int
  ) {
    guard generation == observationGeneration else { return }

    let startedAt = Date()
    let span = PerformanceTrace.begin(
      "HomeListCommit",
      category: .home,
      "inbox=\(update.presentation.inbox.count) all=\(update.presentation.allChatCount) changes=\(update.structuralChangeCount)"
    )
    let nextState = ExperimentalHomeListState(
      presentation: update.presentation,
      isLoading: false,
      errorDescription: nil,
      revision: state.revision + 1
    )
    if update.shouldAnimate {
      withAnimation(.snappy(duration: 0.25, extraBounce: 0)) {
        state = nextState
      }
    } else {
      var transaction = Transaction(animation: nil)
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        state = nextState
      }
    }
    let durationMs = PerformanceTrace.elapsedMilliseconds(since: startedAt)
    span.end("duration_ms=\(durationMs)")
    PerformanceTrace.slowBreadcrumb(
      "iOS Home main-thread commit exceeded one frame",
      category: "ios.home.commit",
      durationMs: durationMs,
      thresholdMs: 17,
      data: [
        "inbox": update.presentation.inbox.count,
        "all_chats": update.presentation.allChatCount,
        "structural_changes": update.structuralChangeCount,
      ]
    )
  }

  private func apply(_ error: any Error, generation observationGeneration: Int) {
    guard generation == observationGeneration else { return }
    log.error("Home-list database observation failed", error: error)
    state = ExperimentalHomeListState(
      presentation: state.presentation,
      isLoading: false,
      errorDescription: String(describing: error),
      revision: state.revision + 1
    )
  }
}

private struct ExperimentalHomeListPreparedUpdate: Sendable {
  let presentation: ChatListPresentation
  let structuralChangeCount: Int
  let shouldAnimate: Bool
}

/// Keeps the first local snapshot and small structural moves immediate while
/// collapsing content-only and bulk sync bursts. Projection and list comparison
/// both stay on the dedicated worker queue.
private final class ExperimentalHomeListPipeline: @unchecked Sendable {
  typealias Emit = @Sendable (ExperimentalHomeListPreparedUpdate) -> Void

  private let queue: DispatchQueue
  private let configuration: ExperimentalHomeListConfiguration
  private let emit: Emit
  private let lock = NSLock()
  private var lastApplied: ChatListPresentation?
  private var pending: ChatListPresentation?
  private var pendingWorkItem: DispatchWorkItem?
  private var pendingGeneration = 0
  private var isCancelled = false

  init(
    queue: DispatchQueue,
    configuration: ExperimentalHomeListConfiguration,
    initialPresentation: ChatListPresentation?,
    emit: @escaping Emit
  ) {
    self.queue = queue
    self.configuration = configuration
    self.lastApplied = initialPresentation
    self.emit = emit
  }

  func submit(_ snapshots: [ChatListItemSnapshot]) {
    let startedAt = Date()
    let span = PerformanceTrace.begin(
      "HomeListPrepare",
      category: .home,
      "rows=\(snapshots.count)"
    )
    let presentation = ChatListPresentation.make(
      from: snapshots,
      sort: configuration.sort
    )
    let durationMs = PerformanceTrace.elapsedMilliseconds(since: startedAt)
    span.end("duration_ms=\(durationMs)")
    PerformanceTrace.slowBreadcrumb(
      "iOS Home list preparation was slow",
      category: "ios.home.prepare",
      durationMs: durationMs,
      thresholdMs: 25,
      data: ["rows": snapshots.count]
    )

    var immediate: ExperimentalHomeListPreparedUpdate?
    var scheduled: (DispatchWorkItem, DispatchTime)?

    lock.lock()
    guard !isCancelled else {
      lock.unlock()
      return
    }

    if let previous = lastApplied {
      guard previous != presentation else {
        lock.unlock()
        return
      }

      let update = makeUpdate(previous: previous, current: presentation)
      if update.shouldAnimate {
        pendingGeneration += 1
        pending = nil
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        lastApplied = presentation
        immediate = update
      } else {
        pending = presentation
        pendingGeneration += 1
        let generation = pendingGeneration
        pendingWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
          self?.flush(generation: generation)
        }
        pendingWorkItem = workItem
        scheduled = (workItem, .now() + .milliseconds(100))
      }
    } else {
      lastApplied = presentation
      immediate = makeUpdate(previous: nil, current: presentation)
    }
    lock.unlock()

    if let immediate {
      emit(immediate)
    }
    if let (workItem, deadline) = scheduled {
      queue.asyncAfter(deadline: deadline, execute: workItem)
    }
  }

  func cancel() {
    lock.lock()
    isCancelled = true
    pendingGeneration += 1
    pending = nil
    pendingWorkItem?.cancel()
    pendingWorkItem = nil
    lock.unlock()
  }

  private func flush(generation: Int) {
    let update: ExperimentalHomeListPreparedUpdate?

    lock.lock()
    guard !isCancelled,
          generation == pendingGeneration,
          let current = pending
    else {
      lock.unlock()
      return
    }
    pending = nil
    pendingWorkItem = nil
    let previous = lastApplied
    lastApplied = current
    update = previous == current ? nil : makeUpdate(previous: previous, current: current)
    lock.unlock()

    if let update {
      emit(update)
    }
  }

  private func makeUpdate(
    previous: ChatListPresentation?,
    current: ChatListPresentation
  ) -> ExperimentalHomeListPreparedUpdate {
    let startedAt = Date()
    let span = PerformanceTrace.begin(
      "HomeListDiff",
      category: .home,
      "all=\(current.allChatCount) inbox=\(current.inbox.count)"
    )
    let structuralChangeCount = previous.map {
      current.structuralLocationChangeCount(from: $0)
    } ?? current.allChatCount + current.inbox.count
    let durationMs = PerformanceTrace.elapsedMilliseconds(since: startedAt)
    span.end("changes=\(structuralChangeCount) duration_ms=\(durationMs)")
    PerformanceTrace.slowBreadcrumb(
      "iOS Home list diff was slow",
      category: "ios.home.diff",
      durationMs: durationMs,
      thresholdMs: 25,
      data: [
        "all_chats": current.allChatCount,
        "inbox": current.inbox.count,
        "structural_changes": structuralChangeCount,
      ]
    )

    return ExperimentalHomeListPreparedUpdate(
      presentation: current,
      structuralChangeCount: structuralChangeCount,
      shouldAnimate: previous != nil && structuralChangeCount > 0 && structuralChangeCount <= 8
    )
  }
}
