import Foundation
import InlineKit

@MainActor
final class ChatRowListViewModel {
  // MARK: - Types

  enum Row: Equatable, Hashable {
    case daySeparator(dayStart: Date)
    case unreadSeparator(anchorMessageId: Int64?)
    case parentMessage(id: Int64)
    case message(id: Int64)
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

  private(set) var unreadBeforeMsgId: Int64?
  var threadAnchor: FullMessage? { progressiveViewModel.threadAnchor }

  var rowCount: Int { rows.count }
  var canLoadOlderFromLocal: Bool { progressiveViewModel.canLoadOlderFromLocal }
  var reversed: Bool { progressiveViewModel.reversed }

  // MARK: - Init

  init(peer: Peer, initialState: MessagesProgressiveViewModel.InitialState?) {
    progressiveViewModel = MessagesProgressiveViewModel(peer: peer, initialState: initialState)
    messages = progressiveViewModel.messages
    rebuildRows()
  }

  // MARK: - Public API

  func observe(_ callback: @escaping (MessagesProgressiveViewModel.MessagesChangeSet) -> Void) {
    progressiveViewModel.observe(callback)
  }

  func apply(_ update: MessagesProgressiveViewModel.MessagesChangeSet) -> UpdateKind {
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
    messages = progressiveViewModel.messages
    return applyMutationTransition(from: oldMessages, to: messages)
  }

  @discardableResult
  func rebuildFromViewModel() -> UpdateKind {
    messages = progressiveViewModel.messages
    rebuildRows()
    return .reloadAll
  }

  @discardableResult
  func rebuildFromViewModel(unreadBeforeMsgId: Int64?) -> UpdateKind {
    self.unreadBeforeMsgId = unreadBeforeMsgId
    return rebuildFromViewModel()
  }

  func loadBatch(at direction: MessagesProgressiveViewModel.MessagesLoadDirection, publish: Bool = true) {
    progressiveViewModel.loadBatch(at: direction, publish: publish)
  }

  func setAtBottom(_ atBottom: Bool) {
    progressiveViewModel.setAtBottom(atBottom)
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
      case .daySeparator, .unreadSeparator:
        return nil
    }
  }

  func messageIndex(forStableMessageId id: Int64) -> Int? {
    msgIdxById[id]
  }

  func rowIndex(forMessageStableId id: Int64) -> Int? {
    rowIdxByMsgId[id]
  }

  // MARK: - Update Handling

  private func applyAdded(_ added: [FullMessage]) -> UpdateKind {
    let oldMessages = messages
    messages = progressiveViewModel.messages

    guard !added.isEmpty else { return .none }
    return applyMutationTransition(from: oldMessages, to: messages)
  }

  private func applyDeleted(_ deletedIds: [Int64]) -> UpdateKind {
    messages = progressiveViewModel.messages

    guard !deletedIds.isEmpty else {
      reindex()
      return .none
    }

    let oldRows = rows
    let newRows = Self.makeRows(
      messages: messages,
      unreadBeforeMsgId: unreadBeforeMsgId,
      parentMessageStableId: threadAnchor?.id
    )

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
    messages = progressiveViewModel.messages
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
         if case let .parentMessage(id) = $0 { return id == anchorId }
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
    let newRows = Self.makeRows(
      messages: new,
      unreadBeforeMsgId: unreadBeforeMsgId,
      parentMessageStableId: threadAnchor?.id
    )

    switch transition {
      case .none:
        guard oldRows != newRows else { return .none }
        setRows(newRows)
        return .reloadAll

      case .append:
        guard newRows.count >= oldRows.count,
              newRows.prefix(oldRows.count).elementsEqual(oldRows)
        else {
          setRows(newRows)
          return .reloadAll
        }

        let inserted = IndexSet(integersIn: oldRows.count ..< newRows.count)
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
    messages = progressiveViewModel.messages
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

        case .daySeparator, .unreadSeparator:
          break
      }
    }

    rowIdxByMsgId = primaryIdxByMsgId
    rowIdxsByMsgId = allIdxsByMsgId
  }

  private func rowIdxs<S: Sequence>(forMsgIds ids: S) -> IndexSet where S.Element == Int64 {
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

  private func sameMsgIds<C1: Collection, C2: Collection>(_ lhs: C1, _ rhs: C2) -> Bool
  where C1.Element == FullMessage, C2.Element == FullMessage {
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
    setRows(
      Self.makeRows(
        messages: messages,
        unreadBeforeMsgId: unreadBeforeMsgId,
        parentMessageStableId: threadAnchor?.id
      )
    )
  }

  private func setRows(_ newRows: [Row]) {
    rows = newRows
    reindex()
  }

  private static func makeRows(
    messages: [FullMessage],
    unreadBeforeMsgId: Int64?,
    parentMessageStableId: Int64?
  ) -> [Row] {
    var out: [Row] = []
    out.reserveCapacity(messages.count + 9)

    if let parentMessageStableId {
      out.append(.parentMessage(id: parentMessageStableId))
    }

    var prevDayStart: Date?
    var didInsertUnread = false

    for msg in messages {
      let dayStart = dayStart(for: msg.message.date)
      if prevDayStart == nil || dayStart != prevDayStart {
        out.append(.daySeparator(dayStart: dayStart))
        prevDayStart = dayStart
      }

      if !didInsertUnread, unreadBeforeMsgId == msg.id {
        out.append(.unreadSeparator(anchorMessageId: msg.id))
        didInsertUnread = true
      }

      out.append(.message(id: msg.id))
    }

    return out
  }

  private static func dayStart(for date: Date) -> Date {
    Calendar.autoupdatingCurrent.startOfDay(for: date)
  }
}
