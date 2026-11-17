import Foundation
import InlineKit
import Translation

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
  /// Photos and videos sent together draw as one row, keyed by the album's oldest item
  /// (`MessageAlbums`). Every item's stable id maps to that row.
  private var albumByLead: [Int64: MessageAlbum] = [:]
  private var leadByMember: [Int64: Int64] = [:]

  /// Whether rows collapse albums. Off for the minimal style, which has no album grid yet.
  var groupsAlbums = true {
    didSet {
      guard groupsAlbums != oldValue else { return }
      rebuildRows()
    }
  }

  /// An album item drawn in another item's row.
  func isAlbumMember(_ stableId: Int64) -> Bool {
    leadByMember[stableId] != nil
  }

  private(set) var showUnreadAfter: Int64?
  /// Text for the `.statusNotice` row. It shows only while the window reaches the newest
  /// cached message, so it always sits at the real bottom.
  private(set) var statusNotice: String?
  private(set) var collapsedMaxId: Int64?
  /// Render inputs from outside the messages, as of the last rows the table was given. A reload
  /// that changes them can't be applied row by row.
  private var renderedThreadAnchor: FullMessage?
  private var renderedTranslationKey: String?
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
    chatId: Int64?,
    initialState: MessagesProgressiveViewModel.InitialState?,
    collapsedMaxId: Int64? = nil
  ) {
    self.collapsedMaxId = collapsedMaxId
    // A direct message's chat is only known from here; without it the transcript queries filter
    // on the peer column, which SQLite has to sort or scan instead of seeking (chatId, messageId).
    progressiveViewModel = MessagesProgressiveViewModel(peer: peer, chatId: chatId, initialState: initialState)
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
    let albumsBefore = albumByLead
    return reconcilingAlbums(applyWithoutAlbums(update), albumsBefore: albumsBefore)
  }

  /// The album row an item draws in: its album when it is one, else nil.
  func album(forStableId id: Int64) -> MessageAlbum? {
    albumByLead[leadByMember[id] ?? id]
  }

  /// Albums change without their rows changing (an item arrives, is acknowledged, is deleted),
  /// so their rows are reloaded on top of whatever the update did. Rows that no longer match the
  /// messages (an item turned into an album member, or out of one) rebuild everything.
  private func reconcilingAlbums(_ kind: UpdateKind, albumsBefore: [Int64: MessageAlbum]) -> UpdateKind {
    indexAlbums()
    // Windows without albums (most) skip the check.
    if albumsBefore.isEmpty, albumByLead.isEmpty { return kind }
    let expected = makeRows(for: messages)
    if expected != rows {
      setRows(expected)
      return .reloadAll
    }
    guard albumsBefore != albumByLead else { return kind }
    var changed = IndexSet()
    for lead in Set(albumsBefore.keys).union(albumByLead.keys) where albumsBefore[lead] != albumByLead[lead] {
      if let row = rowIdxByMsgId[lead] { changed.insert(row) }
    }
    // Rows the update inserts already show their album.
    if case let .insert(inserted) = kind { changed.subtract(inserted) }
    guard !changed.isEmpty else { return kind }
    switch kind {
      case .none: return .reloadRows(changed)
      case let .reloadRows(rows): return .reloadRows(rows.union(changed))
      case .insert, .remove, .reloadAll: return .reloadAll
    }
  }

  private func applyWithoutAlbums(_ update: MessagesProgressiveViewModel.MessagesChangeSet) -> UpdateKind {
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
    let albumsBefore = albumByLead
    let oldMessages = messages
    messages = visibleMessages
    return reconcilingAlbums(applyMutationTransition(from: oldMessages, to: messages), albumsBefore: albumsBefore)
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
    renderedThreadAnchor = threadAnchor
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

  /// A reload rereads the whole window; most return the rows already shown (a history refetch
  /// on open, sync catch-up). Compare with what the table shows and touch only what changed.
  private func reloadFromProgressive() -> UpdateKind {
    let oldMessages = messages
    let oldRows = rows
    let oldThreadAnchor = renderedThreadAnchor
    let oldTranslationKey = renderedTranslationKey
    messages = visibleMessages

    // Translation is toggled through a reload and lives outside the rows.
    guard translationKey() == oldTranslationKey else {
      rebuildRows()
      return .reloadAll
    }

    let diff = MessageWindowDiff(from: oldMessages, to: messages)
    switch diff {
      case .unchanged, .updated:
        let newRows = makeRows(for: messages)
        guard newRows == oldRows else {
          setRows(newRows)
          return .reloadAll
        }
        var changedIDs = Set<Int64>()
        if case let .updated(ids) = diff {
          changedIDs = ids
        }
        if let anchor = threadAnchor, anchor != oldThreadAnchor {
          changedIDs.insert(anchor.id)
        }
        renderedThreadAnchor = threadAnchor
        indexMsgs()
        guard !changedIDs.isEmpty else { return .none }
        return .reloadRows(rowIdxsWithMessageNeighbors(forMsgIds: changedIDs))

      case .inserted, .removed:
        // Structural changes come back as row inserts or removals only when the thread anchor
        // and every kept row are unchanged; anything else falls back to a full reload.
        guard threadAnchor == oldThreadAnchor else {
          rebuildRows()
          return .reloadAll
        }
        if oldMessages.count < messages.count {
          return applyMutationTransition(from: oldMessages, to: messages)
        }
        let newRows = makeRows(for: messages)
        guard let removed = removalIdxs(from: oldRows, to: newRows) else {
          setRows(newRows)
          return .reloadAll
        }
        setRows(newRows)
        return removed.isEmpty ? .none : .remove(removed)

      case .replaced:
        rebuildRows()
        return .reloadAll
    }
  }

  /// Rows of the given messages and of the messages right next to them, whose grouping (first
  /// or last in a run) depends on their neighbours.
  private func rowIdxsWithMessageNeighbors(forMsgIds ids: Set<Int64>) -> IndexSet {
    var idxs = rowIdxs(forMsgIds: ids)
    for row in idxs {
      for neighbor in [row - 1, row + 1] where rows.indices.contains(neighbor) {
        if case .message = rows[neighbor] { idxs.insert(neighbor) }
      }
    }
    return idxs
  }

  private func translationKey() -> String {
    let peer = progressiveViewModel.peer
    guard TranslationState.shared.isTranslationEnabled(for: peer) else { return "off" }
    return "on:\(UserLocale.getCurrentLanguage())"
  }

  // MARK: - Indexing

  private func reindex() {
    indexMsgs()
    indexAlbums()
    indexRows()
  }

  private func indexAlbums() {
    var albums: [Int64: MessageAlbum] = [:]
    var leads: [Int64: Int64] = [:]
    let window = groupsAlbums && messages.contains { $0.message.groupedId != nil } ? messages : []
    for case let .album(album) in MessageAlbums.rows(in: window) {
      albums[album.lead.id] = album
      for item in album.items.dropFirst() {
        leads[item.id] = album.lead.id
      }
    }
    albumByLead = albums
    leadByMember = leads
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

    // An album's items live in its oldest item's row.
    for (member, lead) in leadByMember {
      if let row = primaryIdxByMsgId[lead] { primaryIdxByMsgId[member] = row }
      if let rows = allIdxsByMsgId[lead] { allIdxsByMsgId[member] = rows }
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
    renderedThreadAnchor = threadAnchor
    renderedTranslationKey = translationKey()
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
      showsStatusNotice: statusNotice != nil && !progressiveViewModel.canLoadNewerFromLocal,
      groupsAlbums: groupsAlbums
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
    showsStatusNotice: Bool,
    groupsAlbums: Bool
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

    // An album (photos and videos sent together) is one row, keyed by its oldest item.
    let runs: [Range<Int>] = groupsAlbums ? MessageAlbums.runs(in: messages) : messages.indices.map { $0 ..< $0 + 1 }
    for run in runs {
      let msg = messages[run.lowerBound]
      // The unread line goes above the date that starts with the first unread message, so
      // opening with the line at the top still shows that date. An album is never split by it.
      if let unreadLineMessageId, messages[run].contains(where: { $0.message.messageId == unreadLineMessageId }) {
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
