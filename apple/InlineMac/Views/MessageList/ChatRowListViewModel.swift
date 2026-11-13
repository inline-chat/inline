import Foundation
import InlineKit

@MainActor
final class ChatRowListViewModel {
  // MARK: - Types

  enum Row: Equatable, Hashable {
    case daySeparator(dayStart: Date)
    case unreadSeparator
    case repliesSeparator
    case collapsedHistory
    case parentMessage(id: Int64)
    case message(id: Int64)
    /// A line under the newest message about the other person, such as a silencing Focus.
    case statusNotice
  }

  enum UpdateKind: Equatable {
    case none
    case insert(IndexSet)
    case remove(IndexSet)
    case reloadRows(IndexSet)
    case reloadAll
  }

  private enum MutationTransition {
    case none
    case append
    case prepend
    case reloadAll
  }

  // MARK: - State

  let progressiveViewModel: MessagesProgressiveViewModel

  private(set) var messages: [FullMessage] = []
  private(set) var rows: [Row] = []

  private var msgIdxById: [Int64: Int] = [:]
  private var rowIdxByMsgId: [Int64: Int] = [:]
  private var rowIdxsByMsgId: [Int64: IndexSet] = [:]

  private(set) var showUnreadAfter: Int64?
  /// Text for the `.statusNotice` row. It shows only while the window reaches the newest
  /// cached message, so it always sits at the real bottom.
  private(set) var statusNotice: String?
  private(set) var collapsedMaxId: Int64?
  var threadAnchor: FullMessage? {
    progressiveViewModel.threadAnchor
  }

  var highestPositiveMessageId: Int64? {
    progressiveViewModel.messages.lazy
      .map(\.message.messageId)
      .filter { $0 > 0 }
      .max()
  }

  var rowCount: Int {
    rows.count
  }

  var canLoadOlderFromLocal: Bool {
    progressiveViewModel.canLoadOlderFromLocal
  }

  var canLoadNewerFromLocal: Bool {
    progressiveViewModel.canLoadNewerFromLocal
  }

  var needsNewerHistoryRepair: Bool {
    progressiveViewModel.needsNewerHistoryRepair
  }

  var historyCoverage: MessageHistoryCoverageProjection {
    progressiveViewModel.historyCoverage
  }

  var reversed: Bool {
    progressiveViewModel.reversed
  }

  // MARK: - Init

  init(
    peer: Peer,
    initialState: MessagesProgressiveViewModel.InitialState?,
    collapsedMaxId: Int64? = nil
  ) {
    self.collapsedMaxId = collapsedMaxId
    progressiveViewModel = MessagesProgressiveViewModel(peer: peer, initialState: initialState)
    messages = visibleMessages
    rebuildRows()
  }

  // MARK: - Public API

  func observe(_ callback: @escaping (MessagesProgressiveViewModel.MessagesChangeSet) -> Void) {
    progressiveViewModel.observe { [weak self] update in
      callback(update)
      self?.progressiveViewModel.ensureThreadAnchorCached()
    }
    progressiveViewModel.ensureThreadAnchorCached()
  }

  func apply(_ update: MessagesProgressiveViewModel.MessagesChangeSet) -> UpdateKind {
    // Raw progressive indexes do not map through a collapse boundary. Keep the established
    // incremental path unchanged for normal chats and rebuild only the collapsed projection.
    if collapsedMaxId != nil {
      messages = visibleMessages
      rebuildRows()
      return .reloadAll
    }

    switch update {
      case let .added(added, _):
        return applyAdded(added)

      case let .deleted(deletedIds, _):
        return applyDeleted(deletedIds)

      case let .updated(updated, _, _):
        return applyUpdated(updated)

      case .reload:
        return reloadFromProgressive()
    }
  }

  func syncFromViewModelAfterManualMutation() -> UpdateKind {
    let oldMessages = messages
    messages = visibleMessages
    return applyMutationTransition(from: oldMessages, to: messages)
  }

  @discardableResult
  func rebuildFromViewModel() -> UpdateKind {
    messages = visibleMessages
    rebuildRows()
    return .reloadAll
  }

  @discardableResult
  func rebuildFromViewModel(showUnreadAfter: Int64?) -> UpdateKind {
    self.showUnreadAfter = showUnreadAfter
    return rebuildFromViewModel()
  }

  func loadBatch(at direction: MessagesProgressiveViewModel.MessagesLoadDirection, publish: Bool = true) {
    progressiveViewModel.loadBatch(at: direction, publish: publish)
  }

  @discardableResult
  func loadBatchAsync(
    at direction: MessagesProgressiveViewModel.MessagesLoadDirection,
    publish: Bool = true,
    allowUnavailableLocal: Bool = false
  ) async -> Bool {
    await progressiveViewModel.loadBatchAsync(
      at: direction,
      publish: publish,
      allowUnavailableLocal: allowUnavailableLocal
    )
  }

  @discardableResult
  func loadLatestWindow() async throws -> Bool {
    try await progressiveViewModel.loadLatestWindowAsync()
  }

  func loadUnreadOpeningWindow(boundary: Int64) async throws -> Bool {
    try await progressiveViewModel.loadUnreadOpeningWindowAsync(boundary: boundary)
  }

  func setAtBottom(_ atBottom: Bool) {
    progressiveViewModel.setAtBottom(atBottom)
  }

  func setHistoryAnchor(_ messageID: Int64) {
    progressiveViewModel.setHistoryAnchor(messageID)
  }

  func setCollapsedMaxId(_ collapsedMaxId: Int64?) -> UpdateKind {
    guard self.collapsedMaxId != collapsedMaxId else { return .none }
    self.collapsedMaxId = collapsedMaxId
    messages = visibleMessages
    rebuildRows()
    return .reloadAll
  }

  func setStatusNotice(_ text: String?) -> UpdateKind {
    guard statusNotice != text else { return .none }
    let oldRows = rows
    statusNotice = text
    let newRows = makeRows(for: messages)
    setRows(newRows)

    let oldBody = Self.bodyRows(oldRows)
    let newBody = Self.bodyRows(newRows)
    guard oldBody.elementsEqual(newBody) else { return .reloadAll }
    switch (oldBody.count < oldRows.count, newBody.count < newRows.count) {
      case (false, true): return .insert(IndexSet(integer: newBody.count))
      case (true, false): return .remove(IndexSet(integer: oldBody.count))
      case (true, true): return .reloadRows(IndexSet(integer: newBody.count))
      case (false, false): return .none
    }
  }

  func loadLocalWindowAroundMessage(messageId: Int64, publish: Bool = true) -> Bool {
    progressiveViewModel.loadLocalWindowAroundMessage(messageId: messageId, publish: publish)
  }

  func dispose() {
    progressiveViewModel.dispose()
  }

  func row(at index: Int) -> Row? {
    guard index >= 0, index < rows.count else { return nil }
    return rows[index]
  }

  func canSelect(row: Int) -> Bool {
    guard case .message = self.row(at: row) else { return false }
    return true
  }

  func messageStableId(forRow row: Int) -> Int64? {
    guard let row = self.row(at: row) else { return nil }
    switch row {
      case let .message(id), let .parentMessage(id):
        return id
      case .daySeparator, .unreadSeparator, .repliesSeparator, .collapsedHistory, .statusNotice:
        return nil
    }
  }

  func messageIndex(forStableMessageId id: Int64) -> Int? {
    msgIdxById[id]
  }

  func rowIndex(forMessageStableId id: Int64) -> Int? {
    rowIdxByMsgId[id]
  }

  func rowIndexes(forMessageStableId id: Int64) -> IndexSet {
    rowIdxsByMsgId[id] ?? []
  }

  // MARK: - Update Handling

  private func applyAdded(_ added: [FullMessage]) -> UpdateKind {
    let oldMessages = messages
    messages = visibleMessages

    guard !added.isEmpty else { return .none }
    return applyMutationTransition(from: oldMessages, to: messages)
  }

  private func applyDeleted(_ deletedIds: [Int64]) -> UpdateKind {
    messages = visibleMessages

    guard !deletedIds.isEmpty else {
      reindex()
      return .none
    }

    let oldRows = rows
    let newRows = makeRows(for: messages)

    guard let removed = removalIdxs(from: oldRows, to: newRows) else {
      setRows(newRows)
      return .reloadAll
    }

    setRows(newRows)
    return removed.isEmpty ? .none : .remove(removed)
  }

  private func applyUpdated(_ updated: [FullMessage]) -> UpdateKind {
    guard !updated.isEmpty else { return .none }

    let prevMessages = messages
    let prevMsgIdxById = msgIdxById
    messages = visibleMessages
    let anchorId = threadAnchor?.id

    for msg in updated {
      guard let prevIdx = prevMsgIdxById[msg.id], prevMessages.indices.contains(prevIdx) else {
        if anchorId == msg.id {
          continue
        }
        rebuildRows()
        return .reloadAll
      }

      let prevMsg = prevMessages[prevIdx]
      if Self.dayStart(for: prevMsg.message.date) != Self.dayStart(for: msg.message.date) {
        rebuildRows()
        return .reloadAll
      }
    }

    if let anchorId,
       updated.contains(where: { $0.id == anchorId }),
       !rows.contains(where: {
         if case let .parentMessage(id) = $0 {
           return id == anchorId
         }
         return false
       })
    {
      rebuildRows()
      return .reloadAll
    }

    indexMsgs()
    let rowsToReload = rowIdxs(forMsgIds: updated.map(\.id))
    return rowsToReload.isEmpty ? .none : .reloadRows(rowsToReload)
  }

  private func mutationTransition(from old: [FullMessage], to new: [FullMessage]) -> MutationTransition {
    if sameMsgIds(old, new) {
      return .none
    }

    if new.count <= old.count {
      return .reloadAll
    }

    if sameMsgIds(new.prefix(old.count), old) {
      return .append
    }

    if sameMsgIds(new.suffix(old.count), old) {
      return .prepend
    }

    return .reloadAll
  }

  private func applyMutationTransition(from old: [FullMessage], to new: [FullMessage]) -> UpdateKind {
    let transition = mutationTransition(from: old, to: new)
    let oldRows = rows
    let newRows = makeRows(for: new)

    switch transition {
      case .none:
        guard oldRows != newRows else { return .none }
        setRows(newRows)
        return .reloadAll

      case .append:
        // The status notice stays last, so appended rows go in above it.
        let oldBody = Self.bodyRows(oldRows)
        let newBody = Self.bodyRows(newRows)
        let oldHasNotice = oldBody.count < oldRows.count
        let newHasNotice = newBody.count < newRows.count
        guard newBody.count >= oldBody.count,
              newBody.prefix(oldBody.count).elementsEqual(oldBody),
              !(oldHasNotice && !newHasNotice)
        else {
          setRows(newRows)
          return .reloadAll
        }

        var inserted = IndexSet(integersIn: oldBody.count ..< newBody.count)
        if newHasNotice, !oldHasNotice {
          inserted.insert(newBody.count)
        }
        setRows(newRows)
        return inserted.isEmpty ? .none : .insert(inserted)

      case .prepend:
        guard newRows.count >= oldRows.count else {
          setRows(newRows)
          return .reloadAll
        }
        let insertedCount = newRows.count - oldRows.count
        if insertedCount == 0 {
          setRows(newRows)
          return .none
        }

        let commonPrefix = commonPrefixRowCount(oldRows, newRows)
        let oldSuffix = oldRows.dropFirst(commonPrefix)
        let newSuffix = newRows.dropFirst(commonPrefix + insertedCount)
        guard oldSuffix.elementsEqual(newSuffix) else {
          setRows(newRows)
          return .reloadAll
        }

        let inserted = IndexSet(integersIn: commonPrefix ..< (commonPrefix + insertedCount))
        setRows(newRows)
        return inserted.isEmpty ? .none : .insert(inserted)

      case .reloadAll:
        setRows(newRows)
        return .reloadAll
    }
  }

  private func reloadFromProgressive() -> UpdateKind {
    messages = visibleMessages
    rebuildRows()
    return .reloadAll
  }

  // MARK: - Indexing

  private func reindex() {
    indexMsgs()
    indexRows()
  }

  private func indexMsgs() {
    var idxById: [Int64: Int] = [:]
    idxById.reserveCapacity(messages.count)

    for (idx, msg) in messages.enumerated() {
      idxById[msg.id] = idx
    }

    msgIdxById = idxById
  }

  private func indexRows() {
    var primaryIdxByMsgId: [Int64: Int] = [:]
    primaryIdxByMsgId.reserveCapacity(messages.count)

    var allIdxsByMsgId: [Int64: IndexSet] = [:]
    allIdxsByMsgId.reserveCapacity(messages.count)

    for (rowIdx, row) in rows.enumerated() {
      switch row {
        case let .message(id):
          primaryIdxByMsgId[id] = rowIdx
          allIdxsByMsgId[id, default: []].insert(rowIdx)

        case let .parentMessage(id):
          allIdxsByMsgId[id, default: []].insert(rowIdx)

        case .daySeparator, .unreadSeparator, .repliesSeparator, .collapsedHistory, .statusNotice:
          break
      }
    }

    rowIdxByMsgId = primaryIdxByMsgId
    rowIdxsByMsgId = allIdxsByMsgId
  }

  private func rowIdxs(forMsgIds ids: some Sequence<Int64>) -> IndexSet {
    var idxs = IndexSet()

    for id in ids {
      guard let rowIdxsForMsg = rowIdxsByMsgId[id] else { continue }
      idxs.formUnion(rowIdxsForMsg)
    }

    return idxs
  }

  private func removalIdxs(from oldRows: [Row], to newRows: [Row]) -> IndexSet? {
    guard oldRows.count >= newRows.count else { return nil }

    var removed = IndexSet()
    var oldIdx = 0
    var newIdx = 0

    while oldIdx < oldRows.count, newIdx < newRows.count {
      if oldRows[oldIdx] == newRows[newIdx] {
        oldIdx += 1
        newIdx += 1
      } else {
        removed.insert(oldIdx)
        oldIdx += 1
      }
    }

    while oldIdx < oldRows.count {
      removed.insert(oldIdx)
      oldIdx += 1
    }

    guard newIdx == newRows.count else { return nil }
    guard removed.count == oldRows.count - newRows.count else { return nil }
    return removed
  }

  private func sameMsgIds(_ lhs: some Collection<FullMessage>, _ rhs: some Collection<FullMessage>) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.id == $1.id }
  }

  private func commonPrefixRowCount(_ oldRows: [Row], _ newRows: [Row]) -> Int {
    var idx = 0
    let upperBound = min(oldRows.count, newRows.count)
    while idx < upperBound, oldRows[idx] == newRows[idx] {
      idx += 1
    }
    return idx
  }

  // MARK: - Row Building

  private func rebuildRows() {
    setRows(makeRows(for: messages))
  }

  private func setRows(_ newRows: [Row]) {
    rows = newRows
    reindex()
  }

  /// The message the unread line sits above, fixed for the visit once a window shows it, so
  /// later windows and new messages never move it.
  private(set) var unreadLineMessageId: Int64?

  private func resolveUnreadLineMessageId(in messages: [FullMessage]) -> Int64? {
    if let unreadLineMessageId { return unreadLineMessageId }
    guard let showUnreadAfter else { return nil }
    unreadLineMessageId = ChatUnreadOpening.firstUnreadMessageId(
      in: messages,
      boundary: showUnreadAfter,
      of: progressiveViewModel
    )
    return unreadLineMessageId
  }

  private func makeRows(for messages: [FullMessage]) -> [Row] {
    Self.makeRows(
      messages: messages,
      unreadLineMessageId: resolveUnreadLineMessageId(in: messages),
      showsCollapsedHistory: collapsedMaxId != nil,
      parentMessageStableId: threadAnchor?.id,
      showsStatusNotice: statusNotice != nil && !progressiveViewModel.canLoadNewerFromLocal
    )
  }

  /// Rows without the trailing status notice.
  private static func bodyRows(_ rows: [Row]) -> ArraySlice<Row> {
    rows.last == .statusNotice ? rows.dropLast() : rows[...]
  }

  private static func makeRows(
    messages: [FullMessage],
    unreadLineMessageId: Int64?,
    showsCollapsedHistory: Bool,
    parentMessageStableId: Int64?,
    showsStatusNotice: Bool
  ) -> [Row] {
    var out: [Row] = []
    out.reserveCapacity(messages.count + 9)

    if let parentMessageStableId {
      out.append(.parentMessage(id: parentMessageStableId))
      out.append(.repliesSeparator)
    }

    if showsCollapsedHistory {
      out.append(.collapsedHistory)
    }

    var prevDayStart: Date?

    for msg in messages {
      // The unread line goes above the date that starts with the first unread message, so
      // opening with the line at the top still shows that date.
      if let unreadLineMessageId, msg.message.messageId == unreadLineMessageId {
        out.append(.unreadSeparator)
      }

      let dayStart = dayStart(for: msg.message.date)
      if prevDayStart == nil || dayStart != prevDayStart {
        out.append(.daySeparator(dayStart: dayStart))
        prevDayStart = dayStart
      }

      out.append(.message(id: msg.id))
    }

    if showsStatusNotice {
      out.append(.statusNotice)
    }

    return out
  }

  private static func dayStart(for date: Date) -> Date {
    Calendar.autoupdatingCurrent.startOfDay(for: date)
  }

  private var visibleMessages: [FullMessage] {
    guard let collapsedMaxId else { return progressiveViewModel.messages }
    return progressiveViewModel.messages.filter { message in
      let messageId = message.message.messageId
      return messageId <= 0 || messageId > collapsedMaxId
    }
  }
}
