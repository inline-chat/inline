import Foundation
import InlineKit
import InlineMacUI

@MainActor
final class ExperimentalChatRowListViewModel {
  // MARK: - Types

  typealias Row = ExperimentalMessageListRow

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
  private var projectedThreadAnchor: FullMessage?

  private var msgIdxById: [Int64: Int] = [:]
  private var rowIdxByMsgId: [Int64: Int] = [:]
  private var rowIdxsByMsgId: [Int64: IndexSet] = [:]

  typealias Measurement = (NSSize, NSSize, NSSize?, MessageSizeCalculator.LayoutPlans)
  private struct PlanKey: Hashable {
    let id: Int64
    let props: MessageViewInputProps
    let width: CGFloat
    let richContent: Bool
    let inlineMath: Bool
  }

  private struct MeasuredMessage {
    let message: FullMessage
    let measurement: Measurement
  }

  private var measuredMessages: [PlanKey: MeasuredMessage] = [:]

  func measurement(
    for message: FullMessage, props: MessageViewInputProps, width: CGFloat,
    calculate: () -> Measurement
  ) -> Measurement {
    let key = PlanKey(
      id: message.id, props: props, width: width,
      richContent: AppSettings.shared.richContentRendererEnabled,
      inlineMath: AppSettings.shared.richTextInlineMathEnabled
    )
    if let measured = measuredMessages[key], measured.message == message {
      return measured.measurement
    }
    // Keep a bounded per-window plan cache, including during continuous resize.
    if measuredMessages.count >= 512 { measuredMessages.removeAll(keepingCapacity: true) }
    let result = calculate()
    measuredMessages[key] = MeasuredMessage(message: message, measurement: result)
    return result
  }

  func invalidateMeasurements(for stableID: Int64? = nil) {
    if let stableID {
      measuredMessages = measuredMessages.filter { $0.key.id != stableID }
    } else {
      measuredMessages.removeAll(keepingCapacity: true)
    }
  }

  private(set) var showUnreadAfter: Int64?
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
    showUnreadAfter: Int64? = nil,
    collapsedMaxId: Int64? = nil
  ) {
    self.showUnreadAfter = showUnreadAfter
    self.collapsedMaxId = collapsedMaxId
    progressiveViewModel = MessagesProgressiveViewModel(peer: peer, initialState: initialState, maximumWindowCount: 400)
    messages = visibleMessages
    rebuildRows()
  }

  // MARK: - Public API

  func observe(_ callback: @escaping (MessagesProgressiveViewModel.MessagesChangeSet) -> Void) {
    progressiveViewModel.observe(callback)
  }

  func apply(_ update: MessagesProgressiveViewModel.MessagesChangeSet) -> UpdateKind {
    // Raw progressive indexes do not map through a collapse boundary. Keep the established
    // incremental path unchanged for normal chats and rebuild only the collapsed projection.
    if collapsedMaxId != nil {
      return reloadFromProgressive()
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
    guard self.showUnreadAfter != showUnreadAfter || messages != visibleMessages else { return .none }
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

  func loadLatestWindow() {
    progressiveViewModel.loadLatestWindow()
  }

  func setAtBottom(_ atBottom: Bool) {
    progressiveViewModel.setAtBottom(atBottom)
  }

  func setHistoryAnchor(_ messageID: Int64) {
    progressiveViewModel.setHistoryAnchor(messageID)
  }

  func loadLocalWindowAroundMessageAsync(messageId: Int64, limit: Int? = nil) async throws -> Bool {
    try await progressiveViewModel.loadLocalWindowAroundMessageAsync(messageId: messageId, limit: limit)
  }

  func loadLatestWindowAsync() async throws -> Bool {
    try await progressiveViewModel.loadLatestWindowAsync()
  }

  func isCertifiedHistoryContinuation(
    between firstMessageID: Int64,
    and secondMessageID: Int64
  ) -> Bool {
    historyCoverage.isCertifiedContinuation(
      between: firstMessageID,
      and: secondMessageID
    )
  }

  func setCollapsedMaxId(_ collapsedMaxId: Int64?) -> UpdateKind {
    guard self.collapsedMaxId != collapsedMaxId else { return .none }
    self.collapsedMaxId = collapsedMaxId
    messages = visibleMessages
    rebuildRows()
    return .reloadAll
  }

  func loadLocalWindowAroundMessage(messageId: Int64, publish: Bool = true) -> Bool {
    progressiveViewModel.loadLocalWindowAroundMessage(messageId: messageId, publish: publish)
  }

  func dispose() {
    measuredMessages.removeAll()
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
      case .daySeparator, .unreadSeparator, .repliesSeparator, .collapsedHistory, .historyHole:
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
    messages = visibleMessages
    let projectedRows = makeRows(for: messages)
    guard projectedRows == rows else {
      setRows(projectedRows)
      return .reloadAll
    }
    setRows(projectedRows)
    let affectedRows = ExperimentalMessageListRowProjection.rowsToReload(
      changedMessageIDs: Set(updated.map(\.id)), in: rows
    )
    return affectedRows.isEmpty ? .none : .reloadRows(affectedRows)
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
        if oldRows == newRows {
          var changedIDs = Set(zip(old, new).compactMap { $0 == $1 ? nil : $1.id })
          if projectedThreadAnchor != threadAnchor, let threadAnchor { changedIDs.insert(threadAnchor.id) }
          setRows(newRows)
          let affected = ExperimentalMessageListRowProjection.rowsToReload(changedMessageIDs: changedIDs, in: rows)
          return affected.isEmpty ? .none : .reloadRows(affected)
        }
        setRows(newRows)
        return .reloadAll

      case .append:
        guard newRows.count >= oldRows.count,
              new.prefix(old.count).elementsEqual(old),
              projectedThreadAnchor == threadAnchor,
              newRows.prefix(oldRows.count).elementsEqual(oldRows)
        else {
          setRows(newRows)
          return .reloadAll
        }

        let inserted = IndexSet(integersIn: oldRows.count ..< newRows.count)
        setRows(newRows)
        return inserted.isEmpty ? .none : .insert(inserted)

      case .prepend:
        guard newRows.count >= oldRows.count,
              new.suffix(old.count).elementsEqual(old),
              projectedThreadAnchor == threadAnchor
        else {
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
    let previousMessages = messages
    messages = visibleMessages
    return applyMutationTransition(from: previousMessages, to: messages)
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

        case .daySeparator, .unreadSeparator, .repliesSeparator, .collapsedHistory, .historyHole:
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
    projectedThreadAnchor = threadAnchor
    reindex()
    measuredMessages = measuredMessages.filter { msgIdxById[$0.key.id] != nil || threadAnchor?.id == $0.key.id }
  }

  private func makeRows(for messages: [FullMessage]) -> [Row] {
    ExperimentalMessageListRowProjection.makeRows(
      messages: messages,
      showUnreadAfter: showUnreadAfter,
      showsCollapsedHistory: collapsedMaxId != nil,
      parentMessageStableId: threadAnchor?.id,
      coverage: historyCoverage
    )
  }

  private var visibleMessages: [FullMessage] {
    guard let collapsedMaxId else { return progressiveViewModel.messages }
    return progressiveViewModel.messages.filter { message in
      let messageId = message.message.messageId
      return messageId <= 0 || messageId > collapsedMaxId
    }
  }
}
