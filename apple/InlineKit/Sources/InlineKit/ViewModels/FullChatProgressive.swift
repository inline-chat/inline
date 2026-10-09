import Auth
import Combine
import Foundation
import GRDB
import Logger
import RealtimeV2

/// Immutable history-continuity evidence for one loaded transcript window.
/// Message rows are materialization only; every certified edge or adjacency is
/// derived from the persisted history-hole intervals.
public struct MessageHistoryCoverageProjection: Sendable, Equatable {
  public static let unknown = MessageHistoryCoverageProjection(
    messages: [],
    holes: [
      MessageHistoryHole(
        chatId: 0,
        lowerId: 1,
        upperId: MessageHistoryHole.positiveMessageIDMax
      ),
    ],
    olderCandidateMessageID: nil,
    newerCandidateMessageID: nil
  )

  /// The oldest row reaches its nearest local candidate, or absolute start,
  /// without crossing a persisted hole.
  public let hasCertifiedOlderEdge: Bool
  /// The newest row reaches its nearest local candidate, or absolute tail,
  /// without crossing a persisted hole.
  public let hasCertifiedNewerEdge: Bool
  /// No newer local candidate exists and coverage reaches the positive tail.
  public let isAtCertifiedLiveEnd: Bool

  private let unknownRanges: [ClosedRange<Int64>]

  init(
    messages: [FullMessage],
    holes: [MessageHistoryHole],
    olderCandidateMessageID: Int64?,
    newerCandidateMessageID: Int64?
  ) {
    let unknownRanges = Self.normalizedRanges(holes)
    self.unknownRanges = unknownRanges

    let positiveMessageIDs = messages.lazy.map(\.message.messageId).filter { $0 > 0 }
    let messageIDs = Array(Set(positiveMessageIDs)).sorted()
    guard let oldestMessageID = messageIDs.first, let newestMessageID = messageIDs.last else {
      hasCertifiedOlderEdge = unknownRanges.isEmpty && olderCandidateMessageID == nil
      hasCertifiedNewerEdge = unknownRanges.isEmpty && newerCandidateMessageID == nil
      isAtCertifiedLiveEnd = hasCertifiedNewerEdge
      return
    }

    let olderBoundaryID = olderCandidateMessageID ?? 1
    hasCertifiedOlderEdge = !Self.intersects(
      unknownRanges,
      lowerID: min(olderBoundaryID, oldestMessageID),
      upperID: max(olderBoundaryID, oldestMessageID)
    )

    let newerBoundaryID = newerCandidateMessageID ?? MessageHistoryHole.positiveMessageIDMax
    hasCertifiedNewerEdge = !Self.intersects(
      unknownRanges,
      lowerID: min(newestMessageID, newerBoundaryID),
      upperID: max(newestMessageID, newerBoundaryID)
    )
    isAtCertifiedLiveEnd = newerCandidateMessageID == nil && hasCertifiedNewerEdge
  }

  /// Returns whether two materialized rows belong to one certified history
  /// interval. Optimistic rows do not represent persisted history coordinates.
  public func isCertifiedContinuation(
    between firstMessageID: Int64,
    and secondMessageID: Int64
  ) -> Bool {
    guard firstMessageID > 0, secondMessageID > 0, firstMessageID != secondMessageID else { return true }
    return !Self.intersects(
      unknownRanges,
      lowerID: min(firstMessageID, secondMessageID),
      upperID: max(firstMessageID, secondMessageID)
    )
  }

  /// A cached resource or search row is not evidence that transcript history
  /// through its coordinate has been loaded.
  public func isCertifiedMessage(_ messageID: Int64) -> Bool {
    messageID > 0 && !Self.intersects(unknownRanges, lowerID: messageID, upperID: messageID)
  }

  /// Selects one continuous materialized component. Unknown intervals stay at
  /// its paging edges rather than being silently crossed by sparse cache rows.
  public func contiguousWindow(
    from messages: [FullMessage],
    around anchorID: Int64? = nil
  ) -> [FullMessage] {
    let ids = Array(Set(messages.lazy.map(\.message.messageId).filter { $0 > 0 })).sorted()
    guard let newestID = ids.last else { return messages }
    let coordinate = anchorID ?? newestID
    let anchorIndex = ids.firstIndex(where: { $0 >= coordinate }) ?? (ids.count - 1)
    var lower = anchorIndex
    var upper = anchorIndex
    while lower > 0, isCertifiedContinuation(between: ids[lower - 1], and: ids[lower]) {
      lower -= 1
    }
    while upper + 1 < ids.count, isCertifiedContinuation(between: ids[upper], and: ids[upper + 1]) {
      upper += 1
    }
    let includesLiveRows = upper == ids.count - 1 && anchorID == nil
    return messages.filter {
      let id = $0.message.messageId
      return id > 0 ? (ids[lower] ... ids[upper]).contains(id) : includesLiveRows
    }
  }

  /// Returns the highest concrete read marker that can advance from the
  /// authoritative dialog frontier without crossing unknown history.
  ///
  /// A hole beginning immediately after (or containing) the current frontier
  /// rejects the advance. A later hole caps it at the last certified ID before
  /// that hole. Optimistic IDs never become server read coordinates.
  public func certifiedReadMaxID(
    after currentReadMaxID: Int64,
    through highestVisibleIncomingID: Int64
  ) -> Int64? {
    let frontier = max(0, currentReadMaxID)
    guard highestVisibleIncomingID > frontier, highestVisibleIncomingID > 0 else { return nil }

    guard let firstUnknownRange = unknownRanges.first(where: {
      $0.upperBound > frontier && $0.lowerBound <= highestVisibleIncomingID
    }) else {
      return highestVisibleIncomingID
    }

    let cappedReadMaxID = firstUnknownRange.lowerBound - 1
    return cappedReadMaxID > frontier ? cappedReadMaxID : nil
  }

  private static func normalizedRanges(_ holes: [MessageHistoryHole]) -> [ClosedRange<Int64>] {
    var ranges: [ClosedRange<Int64>] = []
    for hole in holes.sorted(by: { $0.lowerId < $1.lowerId }) {
      let lower = max(1, hole.lowerId)
      let upper = min(MessageHistoryHole.positiveMessageIDMax, hole.upperId)
      guard lower <= upper else { continue }
      guard let previous = ranges.last else {
        ranges.append(lower ... upper)
        continue
      }

      let touchesPrevious = previous.upperBound == MessageHistoryHole.positiveMessageIDMax
        || lower <= previous.upperBound + 1
      if touchesPrevious {
        ranges[ranges.count - 1] = previous.lowerBound ... max(previous.upperBound, upper)
      } else {
        ranges.append(lower ... upper)
      }
    }
    return ranges
  }

  private static func intersects(
    _ ranges: [ClosedRange<Int64>],
    lowerID: Int64,
    upperID: Int64
  ) -> Bool {
    var lowerBound = 0
    var upperBound = ranges.count
    while lowerBound < upperBound {
      let middle = lowerBound + (upperBound - lowerBound) / 2
      if ranges[middle].upperBound < lowerID {
        lowerBound = middle + 1
      } else {
        upperBound = middle
      }
    }
    guard lowerBound < ranges.count else { return false }
    return ranges[lowerBound].lowerBound <= upperID
  }
}

// todos
// - listen to changes of count to first id - last id to detect new messages in between
// - do a refetch on update instead of manually checking things (90/10)
// -

@MainActor
public class MessagesProgressiveViewModel {
  // props
  public let peer: Peer
  public var reversed: Bool = false

  // state
  public var messagesByID: [Int64: FullMessage] = [:]
  public var messages: [FullMessage] = [] {
    didSet {
      messagesByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
    }
  }

  // Used to ignore range when reloading if at bottom
  private var atBottom: Bool = true
  private var historyAnchorID: Int64?
  private var hasNewerLocalMessages = false
  // note: using date is most reliable as our sorting is based on date
  private var minDate: Date = .init()
  private var maxDate: Date = .init()
  public private(set) var oldestLoadedMessageId: Int64?
  public private(set) var newestLoadedMessageId: Int64?
  public private(set) var canLoadOlderFromLocal: Bool = false
  public private(set) var canLoadNewerFromLocal: Bool = false
  public private(set) var historyCoverage: MessageHistoryCoverageProjection = .unknown
  public var needsNewerHistoryRepair: Bool {
    !canLoadNewerFromLocal && !historyCoverage.isAtCertifiedLiveEnd
  }

  public private(set) var threadAnchor: FullMessage?
  private(set) var threadAnchorFetchTask: Task<Void, Never>?
  private var didExhaustThreadAnchorFetch = false

  public struct InitialState: Sendable {
    public let messages: [FullMessage]
    public let threadAnchor: FullMessage?
    public let loadedWindowMetadata: LoadedWindowMetadata

    public var oldestLoadedMessageId: Int64? {
      loadedWindowMetadata.oldestLoadedMessageId
    }

    public var newestLoadedMessageId: Int64? {
      loadedWindowMetadata.newestLoadedMessageId
    }

    public var canLoadOlderFromLocal: Bool {
      loadedWindowMetadata.canLoadOlderFromLocal
    }

    public var canLoadNewerFromLocal: Bool {
      loadedWindowMetadata.canLoadNewerFromLocal
    }

    public var historyCoverage: MessageHistoryCoverageProjection {
      loadedWindowMetadata.historyCoverage
    }

    public init(
      messages: [FullMessage],
      threadAnchor: FullMessage? = nil,
      loadedWindowMetadata: LoadedWindowMetadata
    ) {
      self.messages = messages
      self.threadAnchor = threadAnchor
      self.loadedWindowMetadata = loadedWindowMetadata
    }
  }

  /// internals
  /// was 80
  public static func defaultInitialLimit() -> Int {
    if let height = ScreenMetrics.height {
      (Int(height.rounded()) / 24) + 30
    } else {
      60
    }
  }

  private lazy var initialLimit: Int = Self.defaultInitialLimit()

  private let log = Log.scoped("MessagesViewModel", level: .info)
  private let db: AppDatabase
  private let publisher: MessagesPublisher
  private let currentUserId: Int64?
  private let accountMutationToken: AuthAccountMutationToken?
  private var cancellable = Set<AnyCancellable>()
  private var callback: ((_ changeSet: MessagesChangeSet) -> Void)?
  private var loadedWindowMetadataGeneration: UInt64 = 0
  private var reloadGeneration: UInt64 = 0
  private var reloadTask: Task<Void, Never>?

  deinit {
    threadAnchorFetchTask?.cancel()
  }

  /// Note:
  /// limit, cursor, range, etc are internals to this module. the view layer should not care about this.
  public init(
    peer: Peer,
    reversed: Bool = false,
    initialState: InitialState? = nil,
    database: AppDatabase = .shared,
    publisher: MessagesPublisher = .shared,
    currentUserId: Int64? = Auth.shared.getCurrentUserId()
  ) {
    db = database
    self.publisher = publisher
    self.currentUserId = currentUserId
    accountMutationToken = try? Auth.shared.handle.beginAccountMutation()
    self.peer = peer
    self.reversed = reversed
    if let initialState {
      applyInitialState(initialState)
      if threadAnchor == nil {
        loadThreadAnchorFromLocalIfNeeded()
      }
    } else {
      loadThreadAnchorFromLocalIfNeeded()
      // get initial batch
      loadMessages(.limit(initialLimit))
    }

    // subscribe to changes
    publisher.publisher
      .sink { [weak self] update in
        guard let self else { return }
        Log.shared.trace("Received update \(update)")
        let hadPendingReload = reloadTask != nil
        if let changeset = applyChanges(update: update) {
          callback?(changeset)
        }
        // An incremental publication supersedes the snapshot being read, but
        // not the database changes that reload was asked to pick up.
        if hadPendingReload, reloadTask == nil {
          scheduleReload(animated: false)
        }
      }
      .store(in: &cancellable)
  }

  private func applyInitialState(_ state: InitialState, around anchorID: Int64? = nil) {
    let projected = state.loadedWindowMetadata.projecting(state.messages, around: anchorID)
    messages = reapplyingPendingAcknowledgements(to: Self.stableSortedMessages(projected.messages, reversed: reversed))
    threadAnchor = state.threadAnchor?.withoutAcknowledgements
    if messages.isEmpty {
      minDate = .init()
      maxDate = .init()
    } else {
      updateRange()
    }
    oldestLoadedMessageId = projected.metadata.oldestLoadedMessageId
    newestLoadedMessageId = projected.metadata.newestLoadedMessageId
    canLoadOlderFromLocal = projected.metadata.canLoadOlderFromLocal
    canLoadNewerFromLocal = projected.metadata.canLoadNewerFromLocal
    hasNewerLocalMessages = projected.metadata.hasNewerLocalMessages
    historyCoverage = projected.metadata.historyCoverage
    atBottom = projected.metadata.historyCoverage.isAtCertifiedLiveEnd
  }

  private func loadThreadAnchorFromLocalIfNeeded() {
    guard case let .thread(threadId) = peer else {
      threadAnchor = nil
      return
    }

    do {
      let anchor: FullMessage? = try db.reader.read { db -> FullMessage? in
        guard let chat = try Chat.fetchOne(db, id: threadId),
              let parentChatId = chat.parentChatId,
              let parentMessageId = chat.parentMessageId
        else {
          return nil
        }

        return try FullMessage.queryRequest()
          .filter(Column("chatId") == parentChatId)
          .filter(Column("messageId") == parentMessageId)
          .fetchOne(db)
      }
      threadAnchor = anchor?.withoutAcknowledgements
    } catch {
      log.error("Failed to load thread anchor message", error: error)
      threadAnchor = nil
    }
  }

  /// Set an observer to update the UI
  public func observe(_ callback: @escaping (MessagesChangeSet) -> Void) {
    if self.callback != nil {
      Log.shared.warning(
        "Callback already set, re-setting it to a new one will result in undefined behaviour"
      )
    }

    self.callback = callback
  }

  public enum MessagesLoadDirection: Sendable {
    case older
    case newer
  }

  public func loadBatch(at direction: MessagesLoadDirection, publish: Bool = true) {
    if direction == .newer, historyCoverage.isAtCertifiedLiveEnd {
      return
    }
    let request = buildAdditionalLoadRequest(direction: direction)
    log.trace(
      "Loading batch direction=\(request.direction.logLabel) limit=\(request.limit) prepend=\(request.prepend)"
    )
    loadAdditionalMessages(request: request, publish: publish)
  }

  @discardableResult
  public func loadBatchAsync(
    at direction: MessagesLoadDirection,
    publish: Bool = true,
    allowUnavailableLocal: Bool = false
  ) async -> Bool {
    if direction == .newer, historyCoverage.isAtCertifiedLiveEnd {
      return false
    }
    if !allowUnavailableLocal {
      if direction == .older, !canLoadOlderFromLocal {
        return false
      }
      if direction == .newer, !canLoadNewerFromLocal {
        return false
      }
    }

    let request = buildAdditionalLoadRequest(direction: direction)
    log.trace(
      "Loading batch async direction=\(request.direction.logLabel) limit=\(request.limit) prepend=\(request.prepend)"
    )
    return await loadAdditionalMessagesAsync(request: request, publish: publish)
  }

  public func setAtBottom(_ atBottom: Bool) {
    self.atBottom = atBottom && historyCoverage.isAtCertifiedLiveEnd
    if self.atBottom {
      historyAnchorID = nil
    }
  }

  /// Keep history reloads in the continuous component containing the visible coordinate.
  public func setHistoryAnchor(_ messageID: Int64) {
    guard messageID > 0 else { return }
    if historyAnchorID != messageID {
      invalidatePendingReload()
    }
    historyAnchorID = messageID
    atBottom = false
  }

  @discardableResult
  public func loadLatestWindowAsync() async throws -> Bool {
    invalidatePendingReload()
    let generation = reloadGeneration
    let snapshot = try await Self.publisherReloadSnapshot(
      database: db, peer: peer, currentUserId: currentUserId, reversed: reversed,
      existingMessages: messages, mode: .replaceLatest(limit: initialLimit)
    )
    try Task.checkCancellation()
    guard generation == reloadGeneration else { return false }
    loadedWindowMetadataGeneration &+= 1
    applyInitialState(.init(
      messages: snapshot.messages,
      threadAnchor: threadAnchor,
      loadedWindowMetadata: snapshot.metadata
    ))
    messages = reapplyingPendingAcknowledgements(to: messages)
    historyAnchorID = nil
    return true
  }

  @discardableResult
  public func reloadThreadAnchorFromLocal() -> Bool {
    let previousAnchor = threadAnchor
    loadThreadAnchorFromLocalIfNeeded()
    return previousAnchor != threadAnchor
  }

  /// Parent messages have their own chat sequence and admission token. Hydrate
  /// them with an exact parent query, independent of the reply transcript page.
  /// Call after attaching an observer; cells and row construction stay pure.
  public func ensureThreadAnchorCached() {
    let account = accountMutationToken
    ensureThreadAnchorCached { parentPeer, messageID in
      guard let account else { throw TransactionExecutionError.historyUnavailable }
      let hasParent = try await AppDatabase.shared.reader.read { db in
        try Chat.getByPeerId(db: db, peerId: parentPeer) != nil
      }
      if !hasParent {
        _ = try await Api.realtime.send(.getChat(peer: parentPeer), expectedAccount: account)
      }
      let result = try await Api.realtime.send(
        .getMessages(peer: parentPeer, messageIds: [messageID]),
        expectedAccount: account
      )
      guard case let .getMessages(response) = result else { throw TransactionExecutionError.invalid }
      return response.messages.contains { $0.id == messageID }
    }
  }

  func ensureThreadAnchorCached(
    using fetch: @escaping @Sendable (Peer, Int64) async throws -> Bool
  ) {
    guard case .thread = peer, threadAnchor == nil,
          threadAnchorFetchTask == nil, !didExhaustThreadAnchorFetch else { return }
    let database = db
    let threadPeer = peer
    let log = log
    threadAnchorFetchTask = Task { [weak self] in
      defer { self?.threadAnchorFetchTask = nil }
      for attempt in 1 ... 3 {
        guard !Task.isCancelled, self != nil, self?.threadAnchor == nil else { return }
        do {
          let local = try await database.reader.read { db in
            try Self.threadAnchorSnapshot(db, peer: threadPeer)
          }
          guard !Task.isCancelled else { return }
          // Chat metadata may arrive with the transcript's initial load. A
          // future ordinary publication can retry once the parent is known.
          guard let local else { return }
          if let anchor = local.anchor {
            self?.threadAnchor = anchor.withoutAcknowledgements
            self?.callback?(.reload(animated: false))
            return
          }
          let hasRemoteBody = try await fetch(local.parentPeer, local.messageID)
          guard !Task.isCancelled else { return }
          let refreshed = try await database.reader.read { db in
            try Self.threadAnchorSnapshot(db, peer: threadPeer)
          }
          guard !Task.isCancelled else { return }
          let previous = self?.threadAnchor
          self?.threadAnchor = refreshed?.anchor?.withoutAcknowledgements
          if previous != self?.threadAnchor {
            self?.callback?(.reload(animated: false))
          }
          // A successful exact lookup with no body is authoritative absence.
          // Retry only failures, never poll a deleted/unavailable parent.
          self?.didExhaustThreadAnchorFetch = !hasRemoteBody || self?.threadAnchor == nil
          return
        } catch is CancellationError {
          return
        } catch {
          log.error("Failed to hydrate reply thread anchor", error: error)
          if attempt == 3 {
            return
          }
          do { try await Task.sleep(for: .seconds(attempt)) }
          catch { return }
        }
      }
    }
  }

  public func cancelThreadAnchorHydration() {
    threadAnchorFetchTask?.cancel()
  }

  private struct ThreadAnchorSnapshot: Sendable {
    let parentPeer: Peer
    let messageID: Int64
    let anchor: FullMessage?
  }

  private nonisolated static func threadAnchorSnapshot(_ db: Database, peer: Peer) throws -> ThreadAnchorSnapshot? {
    guard case let .thread(threadID) = peer,
          let chat = try Chat.fetchOne(db, id: threadID),
          let parentID = chat.parentChatId,
          let messageID = chat.parentMessageId, messageID > 0 else { return nil }
    let parent = try Chat.fetchOne(db, id: parentID)
    let anchor = try FullMessage.queryRequest()
      .filter(Column("chatId") == parentID && Column("messageId") == messageID)
      .fetchOne(db)
    return ThreadAnchorSnapshot(
      parentPeer: parent?.peerId.toPeer() ?? .thread(id: parentID),
      messageID: messageID,
      anchor: anchor
    )
  }

  public enum MessagesChangeSet {
    // TODO: case prepend...
    case added([FullMessage], indexSet: [Int])
    case updated([FullMessage], indexSet: [Int], animated: Bool?)
    // Global IDs for list identity
    case deleted([Int64], indexSet: [Int])
    case reload(animated: Bool?)
  }

  private func applyChanges(update: MessagesPublisher.UpdateType) -> MessagesChangeSet? {
    let updateLabel = update.traceLabel
    let beforeCount = messages.count
    let startedAt = Date()
    let span = PerformanceTrace.begin(
      "MessagesApplyChanges",
      category: .messages,
      "type=\(updateLabel) before=\(beforeCount)"
    )
    defer {
      let durationMs = PerformanceTrace.elapsedMilliseconds(since: startedAt)
      span.end(
        "type=\(updateLabel) before=\(beforeCount) after=\(messages.count) duration_ms=\(durationMs)"
      )
      PerformanceTrace.slowBreadcrumb(
        "slow message change apply",
        category: "messages.reload",
        durationMs: durationMs,
        thresholdMs: 150,
        data: [
          "type": updateLabel,
          "before": beforeCount,
          "after": messages.count,
        ]
      )
    }

    //    log.trace("Applying changes: \(update)")
    switch update {
      case let .add(messageAdd):
        if messageAdd.peer == peer {
          invalidatePendingReload()
          // Check if we have it to not add it again
          let existingIds = Set(messages.map(\.id))
          let newMessages = reapplyingPendingAcknowledgements(
            to: messageAdd.messages.filter {
              guard !existingIds.contains($0.id) else { return false }
              // Scrolling up does not detach a window that already ends at
              // the newest message; only a window with newer rows below it
              // leaves new messages to paging.
              guard historyAnchorID != nil, !atBottom, hasNewerLocalMessages else { return true }
              return $0.message.messageId > 0
                && $0.message.messageId >= (oldestLoadedMessageId ?? 0)
                && $0.message.messageId <= (newestLoadedMessageId ?? 0)
            }
          )
          guard !newMessages.isEmpty else {
            if historyAnchorID != nil {
              refreshLoadedWindowMetadata()
            }
            return nil
          }

          // TODO: detect if we should add to the bottom or top
          let insertIndex = reversed ? 0 : messages.count
          if reversed {
            messages.insert(contentsOf: newMessages, at: 0)
          } else {
            messages.append(contentsOf: newMessages)
          }

          // NOTE: Sorting after incremental inserts can desync the collection/table data source.
          // We only sort for full reloads/batches to keep ordering stable.
          // sort()

          updateRange()
          refreshLoadedWindowMetadata()

          // Return changeset
          return MessagesChangeSet.added(
            newMessages,
            indexSet: Array(insertIndex ..< insertIndex + newMessages.count)
          )
        }

      // .messageId, then globalID out for lists
      case let .delete(messageDelete):
        if let threadAnchor,
           messageDelete.peer == threadAnchor.peerId,
           messageDelete.messageIds.contains(threadAnchor.message.messageId)
        {
          loadThreadAnchorFromLocalIfNeeded()
          return MessagesChangeSet.reload(animated: nil)
        }

        if messageDelete.peer == peer {
          invalidatePendingReload()
          let deletedIndices = messages.enumerated()
            .filter { messageDelete.messageIds.contains($0.element.message.messageId) }
            .map(\.offset)
          let deletedGlobalIds: [Int64] = deletedIndices.map { messages[$0].id }

          // Store indices in reverse order to safely remove items
          let sortedIndices = deletedIndices.sorted(by: >)

          // Remove messages
          sortedIndices.forEach { messages.remove(at: $0) }

          // Update ange
          updateRange()
          refreshLoadedWindowMetadata()

          // Return changeset
          return MessagesChangeSet.deleted(deletedGlobalIds, indexSet: sortedIndices)
        }

      case let .update(messageUpdate):
        if let threadAnchor, messageUpdate.message.id == threadAnchor.id {
          self.threadAnchor = messageUpdate.message.withoutAcknowledgements
          return MessagesChangeSet.updated(
            [messageUpdate.message.withoutAcknowledgements],
            indexSet: [],
            animated: messageUpdate.animated ?? true
          )
        }

        if messageUpdate.peer == peer {
          invalidatePendingReload()
          guard let index = messages.firstIndex(where: { $0.id == messageUpdate.message.id }) else {
            // Confirming an optimistic message outside an anchored window can
            // create its first positive newer candidate. Refresh the edge even
            // though that message does not belong in the visible projection.
            if historyAnchorID != nil {
              refreshLoadedWindowMetadata()
            }
            return nil
          }

          messages[index] = reapplyingPendingAcknowledgements(to: messageUpdate.message)
          updateRange() // ??
          refreshLoadedWindowMetadata()
          return MessagesChangeSet.updated([messageUpdate.message], indexSet: [index], animated: messageUpdate.animated)
        }

      case let .acknowledgements(change):
        guard change.peer == peer else { return nil }
        invalidatePendingReload()
        var nextMessages = messages
        var updated: [FullMessage] = []
        var indices: [Int] = []
        for index in nextMessages.indices {
          let previous = nextMessages[index]
          for projection in change.projections {
            nextMessages[index].applyAcknowledgement(projection, currentUserId: currentUserId)
          }
          let next = nextMessages[index]
          if previous.acknowledgements != next.acknowledgements
            || previous.acknowledgementAction(currentUserId: currentUserId)
            != next.acknowledgementAction(currentUserId: currentUserId)
          {
            updated.append(next)
            indices.append(index)
          }
        }
        messages = nextMessages
        guard !updated.isEmpty else { return nil }
        return .updated(updated, indexSet: indices, animated: change.animated)

      case let .reload(reloadPeer, animated):
        if let threadAnchor, reloadPeer == threadAnchor.peerId {
          loadThreadAnchorFromLocalIfNeeded()
          if let updatedAnchor = self.threadAnchor {
            return MessagesChangeSet.updated([updatedAnchor], indexSet: [], animated: animated ?? true)
          }
          return MessagesChangeSet.reload(animated: animated)
        }

        if reloadPeer == peer {
          scheduleReload(animated: animated)
          return nil
        }
    }

    return nil
  }

  private enum PublisherReloadMode: Sendable {
    case around(anchorID: Int64, limit: Int)
    case replaceLatest(limit: Int)
    case preserveRange(minDate: Date, maxDate: Date, limit: Int)
    case mergeLatest(limit: Int)
  }

  private struct PublisherReloadSnapshot: Sendable {
    let messages: [FullMessage]
    let metadata: LoadedWindowMetadata
  }

  /// Publisher-driven reloads originate on MainActor, but their GRDB snapshot
  /// must not. A generation fence prevents a delayed snapshot from overwriting
  /// a newer incremental publication, pagination result, or reload request.
  private func scheduleReload(animated: Bool?) {
    let mode: PublisherReloadMode = if let historyAnchorID, !atBottom {
      .around(anchorID: historyAnchorID, limit: max(initialLimit, messages.count))
    } else if atBottom {
      .replaceLatest(limit: initialLimit)
    } else if !historyCoverage.isAtCertifiedLiveEnd {
      .mergeLatest(limit: initialLimit)
    } else {
      .preserveRange(minDate: minDate, maxDate: maxDate, limit: messages.count)
    }

    reloadGeneration &+= 1
    let generation = reloadGeneration
    reloadTask?.cancel()
    let database = db
    let peer = peer
    let currentUserId = currentUserId
    let reversed = reversed
    let existingMessages = messages

    reloadTask = Task { [weak self] in
      do {
        let snapshot = try await Self.publisherReloadSnapshot(
          database: database,
          peer: peer,
          currentUserId: currentUserId,
          reversed: reversed,
          existingMessages: existingMessages,
          mode: mode
        )
        guard !Task.isCancelled, let self, reloadGeneration == generation else { return }

        messages = reapplyingPendingAcknowledgements(to: snapshot.messages)
        updateRange()
        let metadataRequest = beginLoadedWindowMetadataRequest()
        // Shown rows stay while the newest history is still unknown. Once the
        // tail is certified, rows on the far side of a gap give way to it.
        // A send that was already shown always stays.
        let retained = snapshot.metadata.historyCoverage.isAtCertifiedLiveEnd
          ? Set(existingMessages.lazy.filter { $0.message.messageId <= 0 }.map(\.id))
          : Set(existingMessages.map(\.id))
        _ = applyLoadedWindowMetadata(snapshot.metadata, for: metadataRequest, retainingMessageIDs: retained)
        reloadTask = nil
        callback?(.reload(animated: animated))
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled, let self, reloadGeneration == generation else { return }
        reloadTask = nil
        Log.shared.error("Failed to reload messages", error: error)
      }
    }
  }

  private func invalidatePendingReload() {
    reloadGeneration &+= 1
    reloadTask?.cancel()
    reloadTask = nil
  }

  private nonisolated static func publisherReloadSnapshot(
    database: AppDatabase,
    peer: Peer,
    currentUserId: Int64?,
    reversed: Bool,
    existingMessages: [FullMessage],
    mode: PublisherReloadMode
  ) async throws -> PublisherReloadSnapshot {
    try await database.reader.read { db in
      let visibleIDs = Set(existingMessages.map(\.id))
      var query = baseQuery(for: peer, currentUserId: currentUserId)
        .filter(Column("messageId") > 0)
        .order(Column("messageId").desc)
      switch mode {
        case let .around(anchorID, limit):
          var rows = try localWindowAroundCoordinate(db, peer: peer, messageID: anchorID, limit: limit) ??
            baseQuery(for: peer, currentUserId: currentUserId)
              .filter(visibleIDs.contains(Column("globalId")))
              .fetchAll(db)
          // A send shown in this window has no history coordinate yet, or
          // gained one after it was shown. Keep it by identity.
          let loadedIDs = Set(rows.map(\.id))
          let shownPendingIDs = existingMessages.filter { $0.message.messageId <= 0 }.map(\.id)
          rows += try baseQuery(for: peer, currentUserId: currentUserId)
            .filter(shownPendingIDs.contains(Column("globalId")))
            .fetchAll(db)
            .filter { !loadedIDs.contains($0.id) }
          let normalized = stableSortedMessages(rows, reversed: reversed)
          return try PublisherReloadSnapshot(
            messages: normalized,
            metadata: loadedWindowMetadata(db, peer: peer, messages: normalized)
          )
        case let .replaceLatest(limit), let .mergeLatest(limit):
          query = query.limit(limit)
        case let .preserveRange(minDate, maxDate, limit):
          query = query
            .filter(Column("date") >= minDate)
            .filter(Column("date") <= maxDate)
            .limit(limit)
      }

      var fetched = try query.fetchAll(db)
      switch mode {
        case .replaceLatest, .mergeLatest:
          fetched += try baseQuery(for: peer, currentUserId: currentUserId)
            .filter(Column("messageId") <= 0)
            .order(Column("date").desc)
            .limit(60)
            .fetchAll(db)
        case .preserveRange:
          // Pending sends have no positive history coordinate. Retain the
          // pending rows already shown in this range, even after empty history
          // certifies the new chat's tail.
          fetched += try baseQuery(for: peer, currentUserId: currentUserId)
            .filter(Column("messageId") <= 0)
            .filter(visibleIDs.contains(Column("globalId")))
            .fetchAll(db)
        case .around: break
      }
      let normalized = stableSortedMessages(fetched, reversed: reversed)
      let messages = switch mode {
        case .replaceLatest, .preserveRange, .around:
          normalized
        case .mergeLatest:
          // Reloads also carry history clears and other database-only removals.
          // Refresh the displayed rows in this same snapshot before merging so
          // retaining a live window cannot resurrect deleted or stale rows.
          try mergingLatestMessages(
            existing: baseQuery(for: peer, currentUserId: currentUserId)
              .filter(visibleIDs.contains(Column("globalId")))
              .fetchAll(db),
            latest: normalized, reversed: reversed
          )
      }
      return try PublisherReloadSnapshot(
        messages: messages,
        metadata: loadedWindowMetadata(db, peer: peer, messages: messages)
      )
    }
  }

  private func reapplyingPendingAcknowledgements(to message: FullMessage) -> FullMessage {
    var message = message
    for projection in publisher.pendingAcknowledgementProjections(
      chatId: message.chatId,
      canonicalCurrent: message.currentUserAcknowledgement
    ) {
      message.applyAcknowledgement(projection, currentUserId: currentUserId)
    }
    return message
  }

  private func reapplyingPendingAcknowledgements(to messages: [FullMessage]) -> [FullMessage] {
    messages.map(reapplyingPendingAcknowledgements(to:))
  }

  private func sort() {
    messages = reapplyingPendingAcknowledgements(to: stableSorted(messages))
  }

  private func sort(batch: [FullMessage]) -> [FullMessage] {
    stableSorted(batch)
  }

  struct AdditionalLoadRequest: Sendable {
    let direction: MessagesLoadDirection
    let limit: Int
    let cursorMessageId: Int64
    let prepend: Bool
  }

  struct LoadedWindowBounds: Sendable {
    let oldestDate: Date
    let oldestMessageId: Int64
    let newestDate: Date
    let newestMessageId: Int64
  }

  /// Value metadata prepared alongside a transcript window. App preloaders can
  /// install it without making the first render query the database.
  public struct LoadedWindowMetadata: Sendable, Equatable {
    public let oldestLoadedMessageId: Int64?
    public let newestLoadedMessageId: Int64?
    public let canLoadOlderFromLocal: Bool
    public let canLoadNewerFromLocal: Bool
    public let historyCoverage: MessageHistoryCoverageProjection
    private let holes: [MessageHistoryHole]
    private let olderCandidateMessageID: Int64?
    private let newerCandidateMessageID: Int64?

    /// Derives all pagination authority from the same immutable set of rows,
    /// persisted holes, and nearest local candidates. Callers cannot inject
    /// booleans that disagree with the coverage projection.
    public init(
      messages: [FullMessage],
      holes: [MessageHistoryHole],
      olderCandidateMessageID: Int64? = nil,
      newerCandidateMessageID: Int64? = nil
    ) {
      self.holes = holes
      self.olderCandidateMessageID = olderCandidateMessageID
      self.newerCandidateMessageID = newerCandidateMessageID
      let positiveMessages = messages.filter { $0.message.messageId > 0 }
      let bounds = MessagesProgressiveViewModel.loadedWindowBounds(for: positiveMessages)
      let coverage = MessageHistoryCoverageProjection(
        messages: positiveMessages,
        holes: holes,
        olderCandidateMessageID: olderCandidateMessageID,
        newerCandidateMessageID: newerCandidateMessageID
      )

      oldestLoadedMessageId = bounds?.oldestMessageId
      newestLoadedMessageId = bounds?.newestMessageId
      canLoadOlderFromLocal = bounds != nil
        && olderCandidateMessageID != nil
        && coverage.hasCertifiedOlderEdge
      canLoadNewerFromLocal = bounds != nil
        && newerCandidateMessageID != nil
        && coverage.hasCertifiedNewerEdge
      historyCoverage = coverage
    }

    var hasNewerLocalMessages: Bool {
      newerCandidateMessageID != nil
    }

    fileprivate func projecting(
      _ messages: [FullMessage], around anchorID: Int64?, retainingMessageIDs: Set<Int64> = []
    ) -> (messages: [FullMessage], metadata: LoadedWindowMetadata) {
      if messages.allSatisfy({ retainingMessageIDs.contains($0.id) }) { return (messages, self) }
      let component = historyCoverage.contiguousWindow(from: messages, around: anchorID)
      let componentIDs = Set(component.map(\.id))
      // Coverage decides which cached rows to load, not whether a row already
      // rendered through a live publication still exists. Keep those rows and
      // expose the unknown adjacency without certifying it from materialization.
      let projected = messages.filter { componentIDs.contains($0.id) || retainingMessageIDs.contains($0.id) }
      guard projected.count != messages.count else { return (messages, self) }
      let positiveIDs = projected.lazy.map(\.message.messageId).filter { $0 > 0 }
      let lower = positiveIDs.min()
      let upper = positiveIDs.max()
      let droppedIDs = messages.lazy.map(\.message.messageId).filter { $0 > 0 }
      let older = lower.flatMap { bound in droppedIDs.filter { $0 < bound }.max() } ?? olderCandidateMessageID
      let newer = upper.flatMap { bound in droppedIDs.filter { $0 > bound }.min() } ?? newerCandidateMessageID
      return (projected, LoadedWindowMetadata(
        messages: projected, holes: holes,
        olderCandidateMessageID: older, newerCandidateMessageID: newer
      ))
    }
  }

  struct MessageSortKey: Hashable, Sendable {
    let date: Date
    let globalId: Int64
    let messageId: Int64
  }

  struct LoadedWindowMetadataRequest: Sendable {
    let generation: UInt64
    let fingerprint: [MessageSortKey]
  }

  nonisolated static func messageKey(for message: FullMessage) -> MessageSortKey {
    MessageSortKey(
      date: message.message.date,
      globalId: message.message.globalId ?? 0,
      messageId: Int64(message.message.messageId)
    )
  }

  nonisolated static func compareMessages(_ lhs: FullMessage, _ rhs: FullMessage) -> ComparisonResult {
    let lhsKey = messageKey(for: lhs)
    let rhsKey = messageKey(for: rhs)

    if lhsKey.date != rhsKey.date {
      return lhsKey.date < rhsKey.date ? .orderedAscending : .orderedDescending
    }

    // Local row IDs depend on fetch order. Positive server IDs order ties;
    // optimistic messages retain the local insertion-order fallback below.
    if lhsKey.messageId > 0, rhsKey.messageId > 0, lhsKey.messageId != rhsKey.messageId {
      return lhsKey.messageId < rhsKey.messageId ? .orderedAscending : .orderedDescending
    }

    if lhsKey.globalId != rhsKey.globalId {
      return lhsKey.globalId < rhsKey.globalId ? .orderedAscending : .orderedDescending
    }

    if lhsKey.messageId != rhsKey.messageId {
      return lhsKey.messageId < rhsKey.messageId ? .orderedAscending : .orderedDescending
    }

    return .orderedSame
  }

  /// Sorts a chat timeline without letting local insertion order override persisted server order.
  public nonisolated static func stableSortedMessages(
    _ batch: [FullMessage],
    reversed: Bool
  ) -> [FullMessage] {
    guard batch.count > 1 else { return batch }

    return batch
      .enumerated()
      .sorted { lhs, rhs in
        let comparison = compareMessages(lhs.element, rhs.element)
        if comparison == .orderedSame {
          return lhs.offset < rhs.offset
        }
        return reversed ? comparison == .orderedDescending : comparison == .orderedAscending
      }
      .map(\.element)
  }

  nonisolated static func isNewerMessage(_ lhs: FullMessage, than rhs: FullMessage) -> Bool {
    compareMessages(lhs, rhs) == .orderedDescending
  }

  private func stableSorted(_ batch: [FullMessage]) -> [FullMessage] {
    Self.stableSortedMessages(batch, reversed: reversed)
  }

  static func batchDedupedAtCursor(
    _ batch: [FullMessage],
    existingMessages: [FullMessage],
    cursor: Date
  ) -> [FullMessage] {
    let existingMessagesAtCursor = Set(
      existingMessages.filter { $0.message.date == cursor }.map(\.id)
    )
    return batch.filter { !existingMessagesAtCursor.contains($0.id) }
  }

  static func batchDeduped(
    _ batch: [FullMessage],
    existingByID: [Int64: FullMessage]
  ) -> [FullMessage] {
    batch.filter { existingByID[$0.id] == nil }
  }

  nonisolated static func mergingLatestMessages(
    existing: [FullMessage],
    latest: [FullMessage],
    reversed: Bool
  ) -> [FullMessage] {
    guard !latest.isEmpty else { return existing }

    var merged = existing
    var indicesByID = Dictionary(uniqueKeysWithValues: existing.enumerated().map { ($0.element.id, $0.offset) })
    for message in latest {
      if let index = indicesByID[message.id] {
        merged[index] = message
      } else {
        indicesByID[message.id] = merged.count
        merged.append(message)
      }
    }
    return stableSortedMessages(merged, reversed: reversed)
  }

  nonisolated static func loadedWindowBounds(for messages: [FullMessage]) -> LoadedWindowBounds? {
    guard let first = messages.first else { return nil }

    var oldest = first
    var newest = first

    for message in messages.dropFirst() {
      if message.message.messageId < oldest.message.messageId {
        oldest = message
      }
      if message.message.messageId > newest.message.messageId {
        newest = message
      }
    }

    return LoadedWindowBounds(
      oldestDate: oldest.message.date,
      oldestMessageId: oldest.message.messageId,
      newestDate: newest.message.date,
      newestMessageId: newest.message.messageId
    )
  }

  static func mergedMessages(
    existing: [FullMessage],
    additionalBatch: [FullMessage],
    prepend: Bool
  ) -> [FullMessage] {
    guard !additionalBatch.isEmpty else { return existing }
    return prepend ? (additionalBatch + existing) : (existing + additionalBatch)
  }

  static func dateRange(for messages: [FullMessage]) -> (minDate: Date, maxDate: Date) {
    var lowestDate = Date.distantFuture
    var highestDate = Date.distantPast

    for message in messages {
      let date = message.message.date
      if date < lowestDate {
        lowestDate = date
      }
      if date > highestDate {
        highestDate = date
      }
    }

    return (minDate: lowestDate, maxDate: highestDate)
  }

  // TODO: make it O(1) instead of O(n)
  private func updateRange() {
    let range = Self.dateRange(for: messages)
    minDate = range.minDate
    maxDate = range.maxDate
  }

  /// Live publications change rows the view already shows. They refresh the
  /// paging edges for those rows and never decide which rows stay loaded.
  private func refreshLoadedWindowMetadata() {
    let metadata: LoadedWindowMetadata
    do {
      metadata = try db.reader.read { db in
        try Self.loadedWindowMetadata(db, peer: peer, messages: messages)
      }
    } catch {
      Log.shared.error("Failed to update loaded window metadata", error: error)
      metadata = Self.unknownLoadedWindowMetadata(for: messages)
    }
    loadedWindowMetadataGeneration &+= 1
    oldestLoadedMessageId = metadata.oldestLoadedMessageId
    newestLoadedMessageId = metadata.newestLoadedMessageId
    canLoadOlderFromLocal = metadata.canLoadOlderFromLocal
    canLoadNewerFromLocal = metadata.canLoadNewerFromLocal
    hasNewerLocalMessages = metadata.hasNewerLocalMessages
    historyCoverage = metadata.historyCoverage
  }

  /// Loads, pages and jumps admit cached rows through coverage. Rows named in
  /// `retainingMessageIDs` were already shown and stay.
  private func updateLoadedWindowMetadata(retainingMessageIDs: Set<Int64>) {
    let request = beginLoadedWindowMetadataRequest()
    do {
      let metadata = try db.reader.read { db in
        try Self.loadedWindowMetadata(db, peer: peer, messages: messages)
      }
      _ = applyLoadedWindowMetadata(metadata, for: request, retainingMessageIDs: retainingMessageIDs)
    } catch {
      guard isCurrentLoadedWindowMetadataRequest(request) else { return }
      Log.shared.error("Failed to update loaded window metadata", error: error)
      _ = applyLoadedWindowMetadata(
        Self.unknownLoadedWindowMetadata(for: messages), for: request, retainingMessageIDs: retainingMessageIDs
      )
    }
  }

  private func updateLoadedWindowMetadataAsync(retainingMessageIDs: Set<Int64>? = nil) async {
    let request = beginLoadedWindowMetadataRequest()
    let messages = messages
    let retainedIDs = retainingMessageIDs ?? Set(messages.map(\.id))

    do {
      let metadata = try await Self.loadedWindowMetadata(
        db: db,
        peer: peer,
        messages: messages
      )
      guard !Task.isCancelled else { return }
      _ = applyLoadedWindowMetadata(metadata, for: request, retainingMessageIDs: retainedIDs)
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled, isCurrentLoadedWindowMetadataRequest(request) else { return }
      Log.shared.error("Failed to update loaded window metadata", error: error)
      _ = applyLoadedWindowMetadata(
        Self.unknownLoadedWindowMetadata(for: messages), for: request, retainingMessageIDs: retainedIDs
      )
    }
  }

  func beginLoadedWindowMetadataRequest() -> LoadedWindowMetadataRequest {
    loadedWindowMetadataGeneration &+= 1
    return LoadedWindowMetadataRequest(
      generation: loadedWindowMetadataGeneration,
      fingerprint: Self.loadedWindowFingerprint(messages)
    )
  }

  func isCurrentLoadedWindowMetadataRequest(_ request: LoadedWindowMetadataRequest) -> Bool {
    request.generation == loadedWindowMetadataGeneration
      && request.fingerprint == Self.loadedWindowFingerprint(messages)
  }

  @discardableResult
  func applyLoadedWindowMetadata(
    _ metadata: LoadedWindowMetadata,
    for request: LoadedWindowMetadataRequest,
    retainingMessageIDs: Set<Int64> = []
  ) -> Bool {
    guard isCurrentLoadedWindowMetadataRequest(request) else { return false }
    let projection = metadata.projecting(messages, around: historyAnchorID, retainingMessageIDs: retainingMessageIDs)
    // Coverage filters the existing order. Re-sorting here would move an
    // optimistic insertion after the view has received its incremental index.
    messages = projection.messages
    updateRange()
    oldestLoadedMessageId = projection.metadata.oldestLoadedMessageId
    newestLoadedMessageId = projection.metadata.newestLoadedMessageId
    canLoadOlderFromLocal = projection.metadata.canLoadOlderFromLocal
    canLoadNewerFromLocal = projection.metadata.canLoadNewerFromLocal
    hasNewerLocalMessages = projection.metadata.hasNewerLocalMessages
    historyCoverage = projection.metadata.historyCoverage
    return true
  }

  nonisolated static func loadedWindowFingerprint(_ messages: [FullMessage]) -> [MessageSortKey] {
    messages.map { messageKey(for: $0) }
  }

  nonisolated static func unknownLoadedWindowMetadata(
    for messages: [FullMessage]
  ) -> LoadedWindowMetadata {
    LoadedWindowMetadata(
      messages: messages,
      holes: [
        MessageHistoryHole(
          chatId: 0,
          lowerId: 1,
          upperId: MessageHistoryHole.positiveMessageIDMax
        ),
      ]
    )
  }

  /// Returns a local window centered on a numeric server coordinate. If the
  /// exact row was deleted, nearest neighbors are accepted only when persisted
  /// coverage proves the interval through that coordinate.
  public nonisolated static func localWindowAroundCoordinate(
    _ db: Database,
    peer: Peer,
    messageID: Int64,
    limit: Int
  ) throws -> [FullMessage]? {
    guard 1 ... MessageHistoryHole.positiveMessageIDMax ~= messageID else { return nil }

    let query = baseQuery(for: peer)
    let totalWindow = max(60, limit)
    let beforeLimit = max(20, totalWindow / 2)
    let exact = try query
      .filter(Column("messageId") == messageID)
      .fetchOne(db)
    let afterLimit = max(20, totalWindow - beforeLimit - (exact == nil ? 0 : 1))

    let older = try query
      .filter(Column("messageId") > 0 && Column("messageId") < messageID)
      .order(Column("messageId").desc)
      .limit(beforeLimit)
      .fetchAll(db)
    let newer = try query
      .filter(Column("messageId") > messageID)
      .order(Column("messageId").asc)
      .limit(afterLimit)
      .fetchAll(db)

    if exact == nil {
      guard let chatID = try historyChatID(for: peer, db: db) else { return nil }
      let lowerID = older.first?.message.messageId ?? messageID
      let upperID = newer.first?.message.messageId ?? MessageHistoryHole.positiveMessageIDMax
      let crossesUnknownHistory = try MessageHistoryCoverageStore.intersects(
        db,
        chatId: chatID,
        lowerId: min(lowerID, messageID),
        upperId: max(upperID, messageID)
      )
      guard !crossesUnknownHistory else { return nil }
    }

    var window = Array(older.reversed())
    if let exact {
      window.append(exact)
    }
    window.append(contentsOf: newer)
    return stableSortedMessages(window, reversed: false)
  }

  @discardableResult
  public func loadLocalWindowAroundMessage(messageId: Int64, publish: Bool = true) -> Bool {
    guard messageId > 0 else { return false }

    do {
      let aroundBatch = try db.reader.read { db in
        try Self.localWindowAroundCoordinate(
          db,
          peer: peer,
          messageID: messageId,
          limit: initialLimit
        )
      }

      guard var aroundBatch else {
        return false
      }

      aroundBatch = sort(batch: aroundBatch)
      // A deferred history reload must preserve this window until scrolling
      // establishes that the user has returned to the live end of the chat.
      atBottom = false
      historyAnchorID = messageId
      messages = reapplyingPendingAcknowledgements(to: aroundBatch)
      updateRange()
      updateLoadedWindowMetadata(retainingMessageIDs: [])

      return !messages.isEmpty
    } catch {
      Log.shared.error("Failed to load local around-target window", error: error)
      return false
    }
  }

  private enum LoadMode {
    case limit(Int)
  }

  private func buildAdditionalLoadRequest(direction: MessagesLoadDirection) -> AdditionalLoadRequest {
    if !atBottom, historyAnchorID == nil {
      historyAnchorID = newestLoadedMessageId
    }
    let cursorMessageId = direction == .older ? (oldestLoadedMessageId ?? 0) : (newestLoadedMessageId ?? 0)
    let limit = messages.count > 200 ? 200 : 100
    let prepend = direction == (reversed ? .newer : .older)
    return AdditionalLoadRequest(
      direction: direction,
      limit: limit,
      cursorMessageId: cursorMessageId,
      prepend: prepend
    )
  }

  private func buildBaseOrderedQuery() -> QueryInterfaceRequest<FullMessage> {
    baseQuery()
      .filter(Column("messageId") > 0)
      .order(Column("messageId").desc)
  }

  private nonisolated static func buildBaseOrderedQuery(for peer: Peer) -> QueryInterfaceRequest<FullMessage> {
    baseQuery(for: peer)
      .filter(Column("messageId") > 0)
      .order(Column("messageId").desc)
  }

  private func buildQueryForLoad(loadMode: LoadMode, previousCount: Int) -> QueryInterfaceRequest<FullMessage> {
    var query = buildBaseOrderedQuery()

    switch loadMode {
      case let .limit(limit):
        query = query.limit(limit)
    }

    return query
  }

  private func fetchMessages(loadMode: LoadMode, previousCount: Int) throws -> [FullMessage] {
    let label = loadModeLogLabel(loadMode)
    let startedAt = Date()
    let span = PerformanceTrace.begin(
      "MessagesFetch",
      category: .messages,
      "mode=\(label) previous=\(previousCount)"
    )
    var fetchedCount = 0
    defer {
      let durationMs = PerformanceTrace.elapsedMilliseconds(since: startedAt)
      span.end(
        "mode=\(label) previous=\(previousCount) fetched=\(fetchedCount) duration_ms=\(durationMs)"
      )
      PerformanceTrace.slowBreadcrumb(
        "slow message fetch",
        category: "messages.db",
        durationMs: durationMs,
        thresholdMs: 200,
        data: [
          "mode": label,
          "previous": previousCount,
          "fetched": fetchedCount,
        ]
      )
    }

    let result = try db.reader.read { db in
      let confirmed = try buildQueryForLoad(loadMode: loadMode, previousCount: previousCount).fetchAll(db)
      let optimistic = try baseQuery()
        .filter(Column("messageId") <= 0)
        .order(Column("date").desc)
        .limit(initialLimit)
        .fetchAll(db)
      return confirmed + optimistic
    }
    fetchedCount = result.count
    return result
  }

  private func normalizedMessagesForDisplay(_ batch: [FullMessage]) -> [FullMessage] {
    Self.stableSortedMessages(batch, reversed: reversed)
  }

  private func fetchAdditionalMessages(request: AdditionalLoadRequest) throws -> [FullMessage] {
    let startedAt = Date()
    let span = PerformanceTrace.begin(
      "MessagesFetchAdditional",
      category: .messages,
      "direction=\(request.direction.logLabel) limit=\(request.limit)"
    )
    var fetchedCount = 0
    defer {
      let durationMs = PerformanceTrace.elapsedMilliseconds(since: startedAt)
      span.end(
        "direction=\(request.direction.logLabel) limit=\(request.limit) fetched=\(fetchedCount) duration_ms=\(durationMs)"
      )
      PerformanceTrace.slowBreadcrumb(
        "slow additional message fetch",
        category: "messages.db",
        durationMs: durationMs,
        thresholdMs: 200,
        data: [
          "direction": request.direction.logLabel,
          "limit": request.limit,
          "fetched": fetchedCount,
        ]
      )
    }

    let result = try db.reader.read { db in
      try Self.buildAdditionalMessagesQuery(peer: peer, request: request, currentUserId: currentUserId).fetchAll(db)
    }
    fetchedCount = result.count
    return result
  }

  private nonisolated static func fetchAdditionalMessages(
    db appDatabase: AppDatabase,
    peer: Peer,
    request: AdditionalLoadRequest,
    currentUserId: Int64?
  ) async throws -> [FullMessage] {
    let startedAt = Date()
    let span = PerformanceTrace.begin(
      "MessagesFetchAdditionalAsync",
      category: .messages,
      "direction=\(request.direction.logLabel) limit=\(request.limit)"
    )
    var fetchedCount = 0
    defer {
      span.end(
        "direction=\(request.direction.logLabel) limit=\(request.limit) fetched=\(fetchedCount) duration_ms=\(PerformanceTrace.elapsedMilliseconds(since: startedAt))"
      )
    }

    let result = try await appDatabase.reader.read { db in
      try buildAdditionalMessagesQuery(peer: peer, request: request, currentUserId: currentUserId).fetchAll(db)
    }
    fetchedCount = result.count
    return result
  }

  private nonisolated static func buildAdditionalMessagesQuery(
    peer: Peer,
    request: AdditionalLoadRequest,
    currentUserId: Int64?
  ) -> QueryInterfaceRequest<FullMessage> {
    let query = baseQuery(for: peer, currentUserId: currentUserId)

    switch request.direction {
      case .older:
        return query
          .filter(Column("messageId") > 0 && Column("messageId") < request.cursorMessageId)
          .order(Column("messageId").desc)
          .limit(request.limit)

      case .newer:
        return query
          .filter(Column("messageId") > request.cursorMessageId)
          .order(Column("messageId").asc)
          .limit(request.limit)
    }
  }

  private nonisolated static func loadedWindowMetadata(
    db appDatabase: AppDatabase,
    peer: Peer,
    messages: [FullMessage]
  ) async throws -> LoadedWindowMetadata {
    try await appDatabase.reader.read { db in
      try loadedWindowMetadata(db, peer: peer, messages: messages)
    }
  }

  /// Reads local candidates and persisted holes inside the caller's database
  /// snapshot, then derives the complete window metadata value.
  public nonisolated static func loadedWindowMetadata(
    _ db: Database,
    peer: Peer,
    messages: [FullMessage]
  ) throws -> LoadedWindowMetadata {
    let positiveMessages = messages.filter { $0.message.messageId > 0 }
    let bounds = loadedWindowBounds(for: positiveMessages)
    guard let chatID = try historyChatID(for: peer, db: db) else {
      return unknownLoadedWindowMetadata(for: messages)
    }

    let holes = try MessageHistoryCoverageStore.holes(db, chatId: chatID)
    guard let bounds else {
      let localCandidate = try baseQuery(for: peer)
        .filter(Column("messageId") > 0)
        .limit(1)
        .fetchOne(db)?
        .message.messageId
      return LoadedWindowMetadata(
        messages: messages,
        holes: holes,
        olderCandidateMessageID: localCandidate,
        newerCandidateMessageID: localCandidate
      )
    }

    let olderCandidate = try baseQuery(for: peer)
      .filter(Column("messageId") > 0)
      .filter(Column("messageId") < bounds.oldestMessageId)
      .order(Column("messageId").desc)
      .limit(1)
      .fetchOne(db)
    let newerCandidate = try baseQuery(for: peer)
      .filter(Column("messageId") > 0)
      .filter(Column("messageId") > bounds.newestMessageId)
      .order(Column("messageId").asc)
      .limit(1)
      .fetchOne(db)

    return LoadedWindowMetadata(
      messages: messages,
      holes: holes,
      olderCandidateMessageID: olderCandidate?.message.messageId,
      newerCandidateMessageID: newerCandidate?.message.messageId
    )
  }

  private nonisolated static func historyChatID(for peer: Peer, db: Database) throws -> Int64? {
    switch peer {
      case let .thread(chatID): chatID
      case let .user(userID):
        try Chat
          .filter(Chat.Columns.peerUserId == userID)
          .fetchOne(db)?
          .id
    }
  }

  private func loadModeLogLabel(_ loadMode: LoadMode) -> String {
    switch loadMode {
      case let .limit(limit):
        "limit(\(limit))"
    }
  }

  private func loadMessages(_ loadMode: LoadMode) {
    let prevCount = messages.count
    let label = loadModeLogLabel(loadMode)
    let startedAt = Date()
    let span = PerformanceTrace.begin(
      "MessagesLoad",
      category: .messages,
      "mode=\(label) previous=\(prevCount)"
    )
    defer {
      let durationMs = PerformanceTrace.elapsedMilliseconds(since: startedAt)
      span.end(
        "mode=\(label) previous=\(prevCount) after=\(messages.count) duration_ms=\(durationMs)"
      )
      PerformanceTrace.slowBreadcrumb(
        "slow message load",
        category: "messages.reload",
        durationMs: durationMs,
        thresholdMs: 250,
        data: [
          "mode": label,
          "previous": prevCount,
          "after": messages.count,
        ]
      )
    }
    log.trace("Loading messages mode=\(loadModeLogLabel(loadMode)) previousCount=\(prevCount)")

    do {
      let messagesBatch = try fetchMessages(loadMode: loadMode, previousCount: prevCount)

      //      log.trace("loaded messages: \(messagesBatch.count)")
      messages = reapplyingPendingAcknowledgements(
        to: normalizedMessagesForDisplay(messagesBatch)
      )

      // Uncomment if we want to sort in SQL based on anything other than date
      // sort()

      updateRange()
      updateLoadedWindowMetadata(retainingMessageIDs: [])

    } catch {
      Log.shared.error("Failed to get messages \(error)")
    }
  }

  private func loadAdditionalMessages(request: AdditionalLoadRequest, publish: Bool) {
    let peer = peer
    let retainedIDs = Set(messages.map(\.id))

    log
      .debug(
        "Loading additional messages for \(peer)"
      )

    do {
      var messagesBatch = try fetchAdditionalMessages(request: request)
      let rawCount = messagesBatch.count

      log.trace("loaded additional messages: \(rawCount)")

      messagesBatch = sort(batch: messagesBatch)
      messagesBatch = Self.batchDeduped(messagesBatch, existingByID: messagesByID)
      log.trace(
        "Batch dedupe direction=\(request.direction.logLabel) raw=\(rawCount) deduped=\(messagesBatch.count)"
      )

      // Only proceed if we have new messages to add
      if !messagesBatch.isEmpty {
        messages = reapplyingPendingAcknowledgements(
          to: Self.stableSortedMessages(
            Self.mergedMessages(existing: messages, additionalBatch: messagesBatch, prepend: request.prepend),
            reversed: reversed
          )
        )

        updateRange()
      }
      updateLoadedWindowMetadata(retainingMessageIDs: retainedIDs)
    } catch {
      Log.shared.error("Failed to get messages \(error)")
    }
  }

  private func loadAdditionalMessagesAsync(request: AdditionalLoadRequest, publish: Bool) async -> Bool {
    let peer = peer
    let generation = reloadGeneration
    let previousIDs = messages.map(\.id)

    log
      .debug(
        "Loading additional messages for \(peer)"
      )

    do {
      var messagesBatch = try await Self.fetchAdditionalMessages(
        db: db, peer: peer, request: request, currentUserId: currentUserId
      )
      let rawCount = messagesBatch.count
      guard !Task.isCancelled, generation == reloadGeneration else { return false }

      log.trace("loaded additional messages async: \(rawCount)")

      messagesBatch = sort(batch: messagesBatch)
      messagesBatch = Self.batchDeduped(messagesBatch, existingByID: messagesByID)
      log.trace(
        "Batch dedupe direction=\(request.direction.logLabel) raw=\(rawCount) deduped=\(messagesBatch.count)"
      )

      guard !messagesBatch.isEmpty else {
        await updateLoadedWindowMetadataAsync()
        return previousIDs != messages.map(\.id)
      }

      messages = reapplyingPendingAcknowledgements(
        to: Self.stableSortedMessages(
          Self.mergedMessages(existing: messages, additionalBatch: messagesBatch, prepend: request.prepend),
          reversed: reversed
        )
      )

      updateRange()
      await updateLoadedWindowMetadataAsync(retainingMessageIDs: Set(previousIDs))
      guard !Task.isCancelled else { return false }
      return previousIDs != messages.map(\.id)
    } catch {
      Log.shared.error("Failed to get messages \(error)")
      return false
    }
  }

  private func baseQuery() -> QueryInterfaceRequest<FullMessage> {
    Self.baseQuery(for: peer, currentUserId: currentUserId)
  }

  private nonisolated static func baseQuery(
    for peer: Peer,
    currentUserId: Int64? = Auth.shared.getCurrentUserId()
  ) -> QueryInterfaceRequest<FullMessage> {
    var query = FullMessage.queryRequest(currentUserId: currentUserId)

    switch peer {
      case let .thread(id):
        query =
          query
            .filter(Column("peerThreadId") == id)
      case let .user(id):
        query =
          query
            .filter(Column("peerUserId") == id)
    }
    return query
  }
}

private extension MessagesProgressiveViewModel.MessagesLoadDirection {
  var logLabel: String {
    switch self {
      case .older:
        "older"
      case .newer:
        "newer"
    }
  }
}

@MainActor
public final class MessagesPublisher {
  public static let shared = MessagesPublisher(database: .shared)

  private struct OptimisticAcknowledgementKey: Hashable {
    let chatId: Int64
    let userId: Int64
  }

  private struct PendingAcknowledgement {
    let requestId: UUID
    var projection: FullAcknowledgement
  }

  #if os(iOS)
  public struct ActiveChatToken: Sendable {
    fileprivate let id: UUID
    public let peer: Peer
  }
  #endif

  public struct MessageUpdate {
    public let message: FullMessage
    public let animated: Bool?
    let peer: Peer
  }

  public struct AcknowledgementChange {
    public let projections: [AcknowledgementProjection]
    public let animated: Bool?
    let peer: Peer
  }

  public struct MessageAdd {
    public let messages: [FullMessage]
    let peer: Peer
  }

  public struct MessageDelete {
    // messageID not globalID or stable
    public let messageIds: [Int64]
    let peer: Peer
  }

  public enum UpdateType {
    case add(MessageAdd)
    case update(MessageUpdate)
    case acknowledgements(AcknowledgementChange)
    case delete(MessageDelete)
    case reload(peer: Peer, animated: Bool?)
  }

  private let db: AppDatabase
  let publisher = PassthroughSubject<UpdateType, Never>()
  private var acceptsUpdates = true
  private var activeDatabaseReads = 0
  private var databaseReadDrainWaiters: [CheckedContinuation<Void, Never>] = []
  private var nextAcknowledgementProjectionToken: Int64 = 1
  private var pendingAcknowledgements: [OptimisticAcknowledgementKey: PendingAcknowledgement] = [:]

  init(database: AppDatabase) {
    db = database
  }

  /// Process teardown closes admission synchronously before the shared SQLCipher owner drains.
  public func closeAdmissionForTermination() {
    acceptsUpdates = false
  }

  public func waitForAdmittedDatabaseReadsForTermination() async {
    guard activeDatabaseReads > 0 else { return }
    await withCheckedContinuation { continuation in
      databaseReadDrainWaiters.append(continuation)
    }
  }

  private func beginDatabaseRead(peer: Peer) -> Bool {
    guard shouldPublish(peer: peer) else { return false }
    activeDatabaseReads += 1
    return true
  }

  private func finishDatabaseRead() {
    precondition(activeDatabaseReads > 0)
    activeDatabaseReads -= 1
    guard !acceptsUpdates, activeDatabaseReads == 0 else { return }
    let waiters = databaseReadDrainWaiters
    databaseReadDrainWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  #if os(iOS)
  private var activeChatTokens: [UUID: Peer] = [:]
  private var activePeerCounts: [Peer: Int] = [:]

  public func activateChat(peer: Peer) -> ActiveChatToken {
    let wasInactive = activePeerCounts[peer] == nil
    let token = ActiveChatToken(id: UUID(), peer: peer)

    activeChatTokens[token.id] = peer
    activePeerCounts[peer, default: 0] += 1

    if wasInactive {
      publisher.send(.reload(peer: peer, animated: false))
    }

    return token
  }

  public func deactivateChat(_ token: ActiveChatToken) {
    guard let peer = activeChatTokens.removeValue(forKey: token.id) else { return }

    let count = (activePeerCounts[peer] ?? 1) - 1
    if count > 0 {
      activePeerCounts[peer] = count
    } else {
      activePeerCounts.removeValue(forKey: peer)
    }
  }

  public func isChatActive(peer: Peer) -> Bool {
    activePeerCounts[peer] != nil
  }

  private func shouldPublish(peer: Peer) -> Bool {
    acceptsUpdates && isChatActive(peer: peer)
  }
  #else
  private func shouldPublish(peer _: Peer) -> Bool {
    acceptsUpdates
  }
  #endif

  /// Static methods to publish update
  func messageAdded(message: Message, peer: Peer) async {
//    Log.shared.debug("Message added: \(message)")
    guard beginDatabaseRead(peer: peer) else { return }
    defer { finishDatabaseRead() }

    let startedAt = Date()
    let span = PerformanceTrace.begin(
      "MessagesPublisherFetchMessage",
      category: .messages,
      "event=add"
    )
    defer {
      let durationMs = PerformanceTrace.elapsedMilliseconds(since: startedAt)
      span.end("event=add duration_ms=\(durationMs)")
      PerformanceTrace.slowBreadcrumb(
        "slow publisher message fetch",
        category: "messages.publisher",
        durationMs: durationMs,
        thresholdMs: 150,
        data: [
          "event": "add",
        ]
      )
    }

    do {
      let fullMessage = try await db.reader.read { db in
        try FullMessage.queryRequest()
          .filter(Column("messageId") == message.messageId)
          .filter(Column("chatId") == message.chatId)
          .fetchOne(db)
      }
      guard let fullMessage else {
        Log.shared.error("Failed to get full message")
        return
      }

      guard acceptsUpdates else { return }
      publisher.send(.add(MessageAdd(messages: [fullMessage], peer: peer)))
    } catch {
      Log.shared.error("Failed to get full message", error: error)
    }
  }

  /// Static methods to publish update
  func messageAddedSync(fullMessage: FullMessage, peer: Peer) {
    guard shouldPublish(peer: peer) else { return }

    publisher.send(.add(MessageAdd(messages: [fullMessage], peer: peer)))
  }

  /// Message IDs not Global IDs
  public func messagesDeleted(messageIds: [Int64], peer: Peer) {
    guard shouldPublish(peer: peer) else { return }

    publisher.send(.delete(MessageDelete(messageIds: messageIds, peer: peer)))
  }

  public func messageUpdated(message: Message, peer: Peer, animated: Bool?) async {
    //    Log.shared.debug("Message updated: \(message)")
    //    Log.shared.debug("Message updated: \(message.messageId)")
    guard beginDatabaseRead(peer: peer) else { return }
    defer { finishDatabaseRead() }

    let startedAt = Date()
    let span = PerformanceTrace.begin(
      "MessagesPublisherFetchMessage",
      category: .messages,
      "event=update"
    )
    defer {
      let durationMs = PerformanceTrace.elapsedMilliseconds(since: startedAt)
      span.end("event=update duration_ms=\(durationMs)")
      PerformanceTrace.slowBreadcrumb(
        "slow publisher message fetch",
        category: "messages.publisher",
        durationMs: durationMs,
        thresholdMs: 150,
        data: [
          "event": "update",
        ]
      )
    }

    let fullMessage = try? await db.reader.read { db in
      let query = FullMessage.queryRequest()
      let base =
        if let messageGlobalId = message.globalId {
          query
            .filter(id: messageGlobalId)
        } else {
          query
            .filter(Column("messageId") == message.messageId)
            .filter(Column("chatId") == message.chatId)
        }

      return try base.fetchOne(db)
    }

    guard let fullMessage else {
      Log.shared.error("Failed to get full message")
      return
    }
    guard acceptsUpdates else { return }
    publisher.send(.update(MessageUpdate(message: fullMessage, animated: animated, peer: peer)))
  }

  /// Cursor publication only updates already-loaded rows. No message query or anchor routing.
  public func acknowledgementsChanged(_ cursors: [FullAcknowledgement], peer: Peer, animated: Bool?) {
    guard !cursors.isEmpty else { return }
    for cursor in cursors where !cursor.acknowledgement.isOptimisticProjection {
      pendingAcknowledgements.removeValue(forKey: OptimisticAcknowledgementKey(
        chatId: cursor.acknowledgement.chatId,
        userId: cursor.acknowledgement.userId
      ))
    }
    guard shouldPublish(peer: peer) else { return }
    publisher.send(.acknowledgements(AcknowledgementChange(
      projections: cursors.map(AcknowledgementProjection.replace),
      animated: animated,
      peer: peer
    )))
  }

  /// Atomically admits one local ACK intent per actor/chat and assigns its
  /// monotonic, process-local row token before any asynchronous work begins.
  @discardableResult
  func beginOptimisticAcknowledgement(
    requestId: UUID,
    chatId: Int64,
    userId: Int64,
    maxId: Int64,
    cleared: Bool,
    peer: Peer,
    animated: Bool?
  ) -> Bool {
    guard chatId > 0, userId > 0, maxId > 0 else { return false }
    let key = OptimisticAcknowledgementKey(chatId: chatId, userId: userId)
    guard pendingAcknowledgements[key] == nil else { return false }

    let token = nextAcknowledgementProjectionToken
    nextAcknowledgementProjectionToken = token == Int64.max ? 1 : token + 1
    let projection = FullAcknowledgement(acknowledgement: Acknowledgement(
      chatId: chatId,
      userId: userId,
      maxId: maxId,
      revision: -token,
      cleared: cleared
    ))
    pendingAcknowledgements[key] = PendingAcknowledgement(
      requestId: requestId,
      projection: projection
    )

    if shouldPublish(peer: peer) {
      publisher.send(.acknowledgements(AcknowledgementChange(
        projections: [.replace(projection)],
        animated: animated,
        peer: peer
      )))
    }
    return true
  }

  func enrichOptimisticAcknowledgement(
    requestId: UUID,
    chatId: Int64,
    userId: Int64,
    userInfo: UserInfo?,
    peer: Peer,
    animated: Bool?
  ) {
    guard let userInfo else { return }
    let key = OptimisticAcknowledgementKey(chatId: chatId, userId: userId)
    guard var pending = pendingAcknowledgements[key], pending.requestId == requestId else { return }
    pending.projection.userInfo = userInfo
    pendingAcknowledgements[key] = pending
    guard shouldPublish(peer: peer) else { return }
    publisher.send(.acknowledgements(AcknowledgementChange(
      projections: [.replace(pending.projection)],
      animated: animated,
      peer: peer
    )))
  }

  func hasOptimisticAcknowledgement(requestId: UUID, chatId: Int64, userId: Int64) -> Bool {
    pendingAcknowledgements[OptimisticAcknowledgementKey(chatId: chatId, userId: userId)]?.requestId
      == requestId
  }

  func pendingAcknowledgementProjections(
    chatId: Int64,
    canonicalCurrent: Acknowledgement?
  ) -> [AcknowledgementProjection] {
    var resolvedKeys: [OptimisticAcknowledgementKey] = []
    var projections: [AcknowledgementProjection] = []
    for (key, pending) in pendingAcknowledgements where key.chatId == chatId {
      let desired = pending.projection.acknowledgement
      if let canonicalCurrent,
         !canonicalCurrent.isOptimisticProjection,
         canonicalCurrent.userId == key.userId,
         canonicalCurrent.maxId == desired.maxId,
         canonicalCurrent.cleared == desired.cleared
      {
        resolvedKeys.append(key)
      } else {
        projections.append(.replace(pending.projection))
      }
    }
    for key in resolvedKeys {
      pendingAcknowledgements.removeValue(forKey: key)
    }
    return projections
  }

  /// Reverts one still-current optimistic projection without touching a newer
  /// authoritative cursor or querying message rows.
  func restoreOptimisticAcknowledgement(
    requestId: UUID,
    chatId: Int64,
    userId: Int64,
    previous: FullAcknowledgement?,
    peer: Peer,
    animated: Bool?
  ) {
    let key = OptimisticAcknowledgementKey(chatId: chatId, userId: userId)
    guard let pending = pendingAcknowledgements[key], pending.requestId == requestId else { return }
    pendingAcknowledgements.removeValue(forKey: key)
    guard shouldPublish(peer: peer) else { return }
    publisher.send(.acknowledgements(AcknowledgementChange(
      projections: [.restore(
        chatId: chatId,
        userId: userId,
        replacingRevision: pending.projection.acknowledgement.revision,
        previous: previous
      )],
      animated: animated,
      peer: peer
    )))
  }

  public func messageUpdatedSync(message: Message, peer: Peer, animated: Bool?) {
    guard shouldPublish(peer: peer) else { return }

    Log.shared.trace("Message updated: \(message)")
    //    Log.shared.debug("Message updated: \(message.messageId)")

    let startedAt = Date()
    let span = PerformanceTrace.begin(
      "MessagesPublisherFetchMessageSync",
      category: .messages,
      "event=update"
    )
    defer {
      let durationMs = PerformanceTrace.elapsedMilliseconds(since: startedAt)
      span.end("event=update duration_ms=\(durationMs)")
      PerformanceTrace.slowBreadcrumb(
        "slow sync publisher message fetch",
        category: "messages.publisher",
        durationMs: durationMs,
        thresholdMs: 100,
        data: [
          "event": "update",
        ]
      )
    }

    let fullMessage = try? db.reader.read { db in
      let query = FullMessage.queryRequest()
      let base =
        if let messageGlobalId = message.globalId {
          query
            .filter(id: messageGlobalId)
        } else {
          query
            .filter(Column("messageId") == message.messageId)
            .filter(Column("chatId") == message.chatId)
        }

      return try base.fetchOne(db)
    }

    guard let fullMessage else {
      Log.shared.error("Failed to get full message")
      return
    }
    publisher.send(.update(MessageUpdate(message: fullMessage, animated: animated, peer: peer)))
  }

  public func messagesReload(peer: Peer, animated: Bool?) {
    guard shouldPublish(peer: peer) else { return }

    PerformanceTrace.event(
      "MessagesPublisherReload",
      category: .messages,
      "animated=\(animated ?? false)"
    )
    publisher.send(.reload(peer: peer, animated: animated))
  }

  public func messageUpdatedWithId(messageId: Int64, chatId: Int64, peer: Peer, animated: Bool?) {
    guard shouldPublish(peer: peer) else { return }

    let startedAt = Date()
    let span = PerformanceTrace.begin(
      "MessagesPublisherFetchMessageSync",
      category: .messages,
      "event=updateById"
    )
    defer {
      let durationMs = PerformanceTrace.elapsedMilliseconds(since: startedAt)
      span.end("event=updateById duration_ms=\(durationMs)")
      PerformanceTrace.slowBreadcrumb(
        "slow sync publisher message fetch",
        category: "messages.publisher",
        durationMs: durationMs,
        thresholdMs: 100,
        data: [
          "event": "updateById",
        ]
      )
    }

    let fullMessage = try? db.reader.read { db in
      let query = FullMessage.queryRequest()
      return try query
        .filter(Column("messageId") == messageId)
        .filter(Column("chatId") == chatId)
        .fetchOne(db)
    }

    guard let fullMessage else {
      Log.shared.error("Failed to get full message by messageId: \(messageId)")
      return
    }
    publisher.send(.update(MessageUpdate(message: fullMessage, animated: animated, peer: peer)))
  }
}

public extension MessagesProgressiveViewModel {
  func dispose() {
    threadAnchorFetchTask?.cancel()
    callback = nil
    cancellable.removeAll()
  }
}

private extension MessagesPublisher.UpdateType {
  var traceLabel: String {
    switch self {
      case .add:
        "add"
      case .update, .acknowledgements:
        "update"
      case .delete:
        "delete"
      case .reload:
        "reload"
    }
  }
}
