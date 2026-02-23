import Combine
import Foundation
import GRDB
import Logger

/// todos
/// - listen to changes of count to first id - last id to detect new messages in between
/// - do a refetch on update instead of manually checking things (90/10)
/// -

@MainActor
public class MessagesProgressiveViewModel {
  // props
  public var peer: Peer
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
  // note: using date is most reliable as our sorting is based on date
  private var minDate: Date = .init()
  private var maxDate: Date = .init()
  public private(set) var oldestLoadedMessageId: Int64?
  public private(set) var newestLoadedMessageId: Int64?
  public private(set) var canLoadOlderFromLocal: Bool = false
  public private(set) var canLoadNewerFromLocal: Bool = false

  struct MessageGapRange: Equatable {
    let startMessageId: Int64
    let endMessageId: Int64

    init(startMessageId: Int64, endMessageId: Int64) {
      self.startMessageId = min(startMessageId, endMessageId)
      self.endMessageId = max(startMessageId, endMessageId)
    }
  }

  private(set) var gapRanges: [MessageGapRange] = []

  // internals
  // was 80
  private lazy var initialLimit: Int = // divide window height by 25
    if let height = ScreenMetrics.height {
      (Int(height.rounded()) / 24) + 30
    } else {
      60
    }

  private let log = Log.scoped("MessagesViewModel", enableTracing: false)
  private let db = AppDatabase.shared
  private var cancellable = Set<AnyCancellable>()
  private var callback: ((_ changeSet: MessagesChangeSet) -> Void)?

  // Note:
  // limit, cursor, range, etc are internals to this module. the view layer should not care about this.
  public init(peer: Peer, reversed: Bool = false) {
    self.peer = peer
    self.reversed = reversed
    // get initial batch
    loadMessages(.limit(initialLimit))

    // subscribe to changes
    MessagesPublisher.shared.publisher
      .sink { [weak self] update in
        guard let self else { return }
        Log.shared.trace("Received update \(update)")
        if let changeset = applyChanges(update: update) {
          callback?(changeset)
        }
      }
      .store(in: &cancellable)
  }

  // Set an observer to update the UI
  public func observe(_ callback: @escaping (MessagesChangeSet) -> Void) {
    if self.callback != nil {
      Log.shared.warning(
        "Callback already set, re-setting it to a new one will result in undefined behaviour"
      )
    }

    self.callback = callback
  }

  public enum MessagesLoadDirection {
    case older
    case newer
  }

  public func loadBatch(at direction: MessagesLoadDirection, publish: Bool = true) {
    let request = buildAdditionalLoadRequest(direction: direction)
    log.trace(
      "Loading batch direction=\(request.direction.logLabel) limit=\(request.limit) prepend=\(request.prepend)"
    )
    loadAdditionalMessages(request: request, publish: publish)
  }

  public func setAtBottom(_ atBottom: Bool) {
    self.atBottom = atBottom
  }

  func setGapRanges(_ ranges: [MessageGapRange]) {
    gapRanges = Self.mergedGapRanges(ranges)
  }

  func addGapRange(startMessageId: Int64, endMessageId: Int64) {
    let range = MessageGapRange(startMessageId: startMessageId, endMessageId: endMessageId)
    gapRanges = Self.mergedGapRanges(gapRanges + [range])
  }

  func clearGapRanges() {
    gapRanges.removeAll(keepingCapacity: true)
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
    //    log.trace("Applying changes: \(update)")
    switch update {
      case let .add(messageAdd):
        if messageAdd.peer == peer {
          // Check if we have it to not add it again
          let existingIds = Set(messages.map(\.id))
          let newMessages = messageAdd.messages.filter { !existingIds.contains($0.id) }

          // TODO: detect if we should add to the bottom or top
          if reversed {
            messages.insert(contentsOf: newMessages, at: 0)
          } else {
            messages.append(contentsOf: newMessages)
          }

          // NOTE: Sorting after incremental inserts can desync the collection/table data source.
          // We only sort for full reloads/batches to keep ordering stable.
          // sort()

          updateRange()
          updateLoadedWindowMetadata()

          // Return changeset
          return MessagesChangeSet.added(newMessages, indexSet: [messages.count - 1])
        }

      // .messageId, then globalID out for lists
      case let .delete(messageDelete):
        if messageDelete.peer == peer {
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
          updateLoadedWindowMetadata()

          // Return changeset
          return MessagesChangeSet.deleted(deletedGlobalIds, indexSet: sortedIndices)
        }

      case let .update(messageUpdate):
        if messageUpdate.peer == peer {
          guard let index = messages.firstIndex(where: { $0.id == messageUpdate.message.id }) else {
            // not in our range
            return nil
          }

          messages[index] = messageUpdate.message
          updateRange() // ??
          updateLoadedWindowMetadata()
          return MessagesChangeSet.updated([messageUpdate.message], indexSet: [index], animated: messageUpdate.animated)
        }

      case let .reload(peer, animated):
        if peer == self.peer {
          if atBottom {
            log.trace("Reloading messages at bottom")
            // Since user is still at bottom and haven't moved this means we need to ignore the range and show them the
            // latest messages
            loadMessages(.limit(initialLimit))
            // TODO: if new messages were added, we should animate adding them
          } else {
            // 90/10 solution TODO: quick way to optimize is to check if updated messages are in the current range
            // check if actually anything changed then post update
            refetchCurrentRange()
          }

          return MessagesChangeSet.reload(animated: animated)
        }
    }

    return nil
  }

  private func sort() {
    messages = stableSorted(messages)
  }

  private func sort(batch: [FullMessage]) -> [FullMessage] {
    stableSorted(batch)
  }

  struct AdditionalLoadRequest {
    let direction: MessagesLoadDirection
    let limit: Int
    let cursor: Date
    let prepend: Bool
  }

  struct MessageSortKey: Hashable {
    let date: Date
    let globalId: Int64
    let messageId: Int64
  }

  static func messageKey(for message: FullMessage) -> MessageSortKey {
    MessageSortKey(
      date: message.message.date,
      globalId: message.message.globalId ?? 0,
      messageId: Int64(message.message.messageId)
    )
  }

  static func stableSortedMessages(_ batch: [FullMessage], reversed: Bool) -> [FullMessage] {
    guard batch.count > 1 else { return batch }

    return batch
      .enumerated()
      .sorted { lhs, rhs in
        let lhsKey = messageKey(for: lhs.element)
        let rhsKey = messageKey(for: rhs.element)

        if lhsKey.date != rhsKey.date {
          return reversed ? lhsKey.date > rhsKey.date : lhsKey.date < rhsKey.date
        }

        if lhsKey.globalId != rhsKey.globalId {
          return reversed ? lhsKey.globalId > rhsKey.globalId : lhsKey.globalId < rhsKey.globalId
        }

        if lhsKey.messageId != rhsKey.messageId {
          return reversed ? lhsKey.messageId > rhsKey.messageId : lhsKey.messageId < rhsKey.messageId
        }

        return lhs.offset < rhs.offset
      }
      .map(\.element)
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

  static func mergedGapRanges(_ ranges: [MessageGapRange]) -> [MessageGapRange] {
    guard !ranges.isEmpty else { return [] }

    let sorted = ranges.sorted { lhs, rhs in
      if lhs.startMessageId != rhs.startMessageId {
        return lhs.startMessageId < rhs.startMessageId
      }
      return lhs.endMessageId < rhs.endMessageId
    }

    var merged: [MessageGapRange] = []
    merged.reserveCapacity(sorted.count)

    for range in sorted {
      guard let last = merged.last else {
        merged.append(range)
        continue
      }

      let touchesOrOverlaps = last.endMessageId == .max || range.startMessageId <= (last.endMessageId + 1)
      if touchesOrOverlaps {
        merged[merged.count - 1] = MessageGapRange(
          startMessageId: last.startMessageId,
          endMessageId: max(last.endMessageId, range.endMessageId)
        )
      } else {
        merged.append(range)
      }
    }

    return merged
  }

  // TODO: make it O(1) instead of O(n)
  private func updateRange() {
    let range = Self.dateRange(for: messages)
    minDate = range.minDate
    maxDate = range.maxDate
  }

  private func updateLoadedWindowMetadata() {
    let messageIds = messages.map(\.message.messageId)
    guard let oldest = messageIds.min(), let newest = messageIds.max() else {
      oldestLoadedMessageId = nil
      newestLoadedMessageId = nil
      canLoadOlderFromLocal = false
      canLoadNewerFromLocal = false
      return
    }

    oldestLoadedMessageId = oldest
    newestLoadedMessageId = newest

    do {
      let availability = try db.reader.read { db -> (Bool, Bool) in
        let olderExists = try baseQuery()
          .filter(Column("messageId") < oldest)
          .limit(1)
          .fetchCount(db) > 0
        let newerExists = try baseQuery()
          .filter(Column("messageId") > newest)
          .limit(1)
          .fetchCount(db) > 0
        return (olderExists, newerExists)
      }

      canLoadOlderFromLocal = availability.0
      canLoadNewerFromLocal = availability.1
    } catch {
      Log.shared.error("Failed to update loaded window metadata", error: error)
      canLoadOlderFromLocal = false
      canLoadNewerFromLocal = false
    }
  }

  @discardableResult
  public func loadLocalWindowAroundMessage(messageId: Int64, publish: Bool = true) -> Bool {
    guard messageId > 0 else { return false }

    let totalWindow = max(60, initialLimit)
    let beforeLimit = max(20, totalWindow / 2)
    let afterLimit = max(20, totalWindow - beforeLimit - 1)

    do {
      let aroundBatch = try db.reader.read { db -> [FullMessage]? in
        guard let target = try baseQuery()
          .filter(Column("messageId") == messageId)
          .fetchOne(db)
        else {
          return nil
        }

        let targetDate = target.message.date
        let targetMessageId = target.message.messageId

        let olderOrTarget = try baseQuery()
          .filter(
            sql: "(date < ?) OR (date = ? AND messageId <= ?)",
            arguments: [targetDate, targetDate, targetMessageId]
          )
          .order(Column("date").desc, Column("messageId").desc)
          .limit(beforeLimit + 1)
          .fetchAll(db)

        let newer = try baseQuery()
          .filter(
            sql: "(date > ?) OR (date = ? AND messageId > ?)",
            arguments: [targetDate, targetDate, targetMessageId]
          )
          .order(Column("date").asc, Column("messageId").asc)
          .limit(afterLimit)
          .fetchAll(db)

        return olderOrTarget.reversed() + newer
      }

      guard var aroundBatch else {
        return false
      }

      aroundBatch = sort(batch: aroundBatch)
      messages = aroundBatch
      updateRange()
      updateLoadedWindowMetadata()

      return messages.contains { $0.message.messageId == messageId }
    } catch {
      Log.shared.error("Failed to load local around-target window", error: error)
      return false
    }
  }

  private func refetchCurrentRange() {
    loadMessages(.preserveRange)
  }

  private enum LoadMode {
    case limit(Int)
    case preserveRange
  }

  private func buildAdditionalLoadRequest(direction: MessagesLoadDirection) -> AdditionalLoadRequest {
    let cursor = direction == .older ? minDate : maxDate
    let limit = messages.count > 200 ? 200 : 100
    let prepend = direction == (reversed ? .newer : .older)
    return AdditionalLoadRequest(
      direction: direction,
      limit: limit,
      cursor: cursor,
      prepend: prepend
    )
  }

  private func buildBaseOrderedQuery() -> QueryInterfaceRequest<FullMessage> {
    baseQuery()
      .order(Column("date").desc, Column("messageId").desc)
  }

  private func buildQueryForLoad(loadMode: LoadMode, previousCount: Int) -> QueryInterfaceRequest<FullMessage> {
    var query = buildBaseOrderedQuery()

    switch loadMode {
      case let .limit(limit):
        query = query.limit(limit)

      case .preserveRange:
        query =
          query
            .filter(Column("date") >= minDate)
            .filter(Column("date") <= maxDate)
            .limit(previousCount)
    }

    return query
  }

  private func fetchMessages(loadMode: LoadMode, previousCount: Int) throws -> [FullMessage] {
    try db.reader.read { db in
      try buildQueryForLoad(loadMode: loadMode, previousCount: previousCount).fetchAll(db)
    }
  }

  private func normalizedMessagesForDisplay(_ batch: [FullMessage]) -> [FullMessage] {
    if reversed {
      // It's already reversed because SQL query sorts descending.
      return batch
    }

    // Reverse back for chronological presentation in non-reversed mode.
    return batch.reversed()
  }

  private func fetchAdditionalMessages(request: AdditionalLoadRequest) throws -> [FullMessage] {
    try db.reader.read { db in
      var query = buildBaseOrderedQuery()
      query = query.filter(Column("date") <= request.cursor)
      query = query.limit(request.limit)
      return try query.fetchAll(db)
    }
  }

  private func loadModeLogLabel(_ loadMode: LoadMode) -> String {
    switch loadMode {
      case let .limit(limit):
        "limit(\(limit))"
      case .preserveRange:
        "preserveRange"
    }
  }

  private func loadMessages(_ loadMode: LoadMode) {
    let prevCount = messages.count
    log.trace("Loading messages mode=\(loadModeLogLabel(loadMode)) previousCount=\(prevCount)")

    do {
      let messagesBatch = try fetchMessages(loadMode: loadMode, previousCount: prevCount)

      //      log.trace("loaded messages: \(messagesBatch.count)")
      messages = normalizedMessagesForDisplay(messagesBatch)

      // Uncomment if we want to sort in SQL based on anything other than date
      // sort()

      updateRange()
      updateLoadedWindowMetadata()

    } catch {
      Log.shared.error("Failed to get messages \(error)")
    }
  }

  private func loadAdditionalMessages(request: AdditionalLoadRequest, publish: Bool) {
    let peer = peer

    log
      .debug(
        "Loading additional messages for \(peer)"
      )

    do {
      var messagesBatch = try fetchAdditionalMessages(request: request)
      let rawCount = messagesBatch.count

      log.debug("loaded additional messages: \(rawCount)")

      messagesBatch = sort(batch: messagesBatch)
      messagesBatch = Self.batchDedupedAtCursor(messagesBatch, existingMessages: messages, cursor: request.cursor)
      log.trace(
        "Batch dedupe direction=\(request.direction.logLabel) raw=\(rawCount) deduped=\(messagesBatch.count)"
      )

      // Only proceed if we have new messages to add
      if !messagesBatch.isEmpty {
        messages = Self.mergedMessages(existing: messages, additionalBatch: messagesBatch, prepend: request.prepend)

        updateRange()
      }
      updateLoadedWindowMetadata()
    } catch {
      Log.shared.error("Failed to get messages \(error)")
    }
  }

  private func baseQuery() -> QueryInterfaceRequest<FullMessage> {
    var query = FullMessage.queryRequest()

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
  public static let shared = MessagesPublisher()

  public struct MessageUpdate {
    public let message: FullMessage
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
    case delete(MessageDelete)
    case reload(peer: Peer, animated: Bool?)
  }

  private init() {}

  private let db = AppDatabase.shared
  let publisher = PassthroughSubject<UpdateType, Never>()

  // Static methods to publish update
  func messageAdded(message: Message, peer: Peer) async {
//    Log.shared.debug("Message added: \(message)")
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

      publisher.send(.add(MessageAdd(messages: [fullMessage], peer: peer)))
    } catch {
      Log.shared.error("Failed to get full message", error: error)
    }
  }

  // Static methods to publish update
  func messageAddedSync(fullMessage: FullMessage, peer: Peer) {
    publisher.send(.add(MessageAdd(messages: [fullMessage], peer: peer)))
  }

  // Message IDs not Global IDs
  public func messagesDeleted(messageIds: [Int64], peer: Peer) {
    publisher.send(.delete(MessageDelete(messageIds: messageIds, peer: peer)))
  }

  public func messageUpdated(message: Message, peer: Peer, animated: Bool?) async {
    //    Log.shared.debug("Message updated: \(message)")
    //    Log.shared.debug("Message updated: \(message.messageId)")
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
    publisher.send(.update(MessageUpdate(message: fullMessage, animated: animated, peer: peer)))
  }

  public func messageUpdatedSync(message: Message, peer: Peer, animated: Bool?) {
    Log.shared.debug("Message updated: \(message)")
    //    Log.shared.debug("Message updated: \(message.messageId)")
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
    publisher.send(.reload(peer: peer, animated: animated))
  }

  public func messageUpdatedWithId(messageId: Int64, chatId: Int64, peer: Peer, animated: Bool?) {
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
    callback = nil
    cancellable.removeAll()
  }
}
