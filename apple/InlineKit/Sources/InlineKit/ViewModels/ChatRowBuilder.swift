import Foundation

/// Direct messages show no sender names or avatars; group threads do.
public enum ChatRowChatKind: Equatable, Sendable {
  case direct
  case group

  public init(peer: Peer) {
    switch peer {
      case .user: self = .direct
      case .thread: self = .group
    }
  }
}

/// Pure projection from the window's messages to rows. No database, no UI.
///
/// Order, top to bottom: thread parent and replies header, collapsed-history
/// marker, then for each message (sorted every time) an unread line if it is
/// the first unread message, a day separator if it starts a day, and the
/// message; last, the status notice. The unread line sits above the day
/// separator of the day it starts, so opening at the line still shows the date.
///
/// Cost per build: O(n) over the window's messages (one sortedness check, one
/// pass for rows and groups, one `startOfDay` per message), plus an
/// O(n log n) sort only when the input is out of order (an append or an ack
/// that landed out of place). `ChatRowSnapshot.next` adds one content
/// comparison per row against the previous snapshot.
public enum ChatRowBuilder {
  public struct UnreadLine: Equatable, Sendable {
    /// The last read message id the line is drawn after.
    public var boundary: Int64
    /// The message the line was first placed above. Kept for the visit, so new
    /// windows and new messages never move it; if that message leaves, the line
    /// moves to the next newer unread message.
    public var pinnedMessageId: Int64?

    public init(boundary: Int64, pinnedMessageId: Int64? = nil) {
      self.boundary = boundary
      self.pinnedMessageId = pinnedMessageId
    }
  }

  public struct Input: Sendable {
    /// The window, in any order.
    public var messages: [FullMessage]
    public var threadParent: FullMessage?
    public var unreadLine: UnreadLine?
    /// Messages with `0 < messageId <= collapsedMaxId` are hidden behind the
    /// collapsed-history marker.
    public var collapsedMaxId: Int64?
    /// Shown only when non-nil; owners pass nil away from the newest messages.
    public var statusNotice: String?
    public var chatKind: ChatRowChatKind
    /// The window starts at the chat's first message (for the unread line).
    public var reachesOldest: Bool
    public var calendar: Calendar

    public init(
      messages: [FullMessage], threadParent: FullMessage? = nil, unreadLine: UnreadLine? = nil,
      collapsedMaxId: Int64? = nil, statusNotice: String? = nil, chatKind: ChatRowChatKind = .group,
      reachesOldest: Bool = false, calendar: Calendar = .autoupdatingCurrent
    ) {
      self.messages = messages
      self.threadParent = threadParent
      self.unreadLine = unreadLine
      self.collapsedMaxId = collapsedMaxId
      self.statusNotice = statusNotice
      self.chatKind = chatKind
      self.reachesOldest = reachesOldest
      self.calendar = calendar
    }
  }

  public struct Draft: Equatable, Sendable {
    public let id: ChatRowID
    public let content: ChatRowContent
  }

  public struct Output: Sendable {
    public var rows: [Draft]
    /// The message the unread line was placed above; owners pin it.
    public var unreadLineMessageId: Int64?
  }

  /// Two messages share a group: same sender, neither a service message, same
  /// day, at most five minutes apart. The rule both lists use today.
  public static let groupingInterval: TimeInterval = 300

  public static func canGroup(_ earlier: FullMessage, _ later: FullMessage, calendar: Calendar) -> Bool {
    guard !earlier.message.isServiceMessage, !later.message.isServiceMessage,
          earlier.message.fromId == later.message.fromId else { return false }
    let gap = later.message.date.timeIntervalSince(earlier.message.date)
    guard gap >= 0, gap <= groupingInterval else { return false }
    return calendar.isDate(earlier.message.date, inSameDayAs: later.message.date)
  }

  /// Ascending timeline order; ties keep input order, as the view model does.
  public static func sorted(_ messages: [FullMessage]) -> [FullMessage] {
    var isSorted = true
    for index in messages.indices.dropFirst()
      where MessagesProgressiveViewModel.compareMessages(messages[index - 1], messages[index]) == .orderedDescending
    {
      isSorted = false
      break
    }
    return isSorted ? messages : MessagesProgressiveViewModel.stableSortedMessages(messages, reversed: false)
  }

  public static func build(_ input: Input) -> Output {
    var visible = sorted(input.messages)
    if let collapsedMaxId = input.collapsedMaxId {
      visible.removeAll { $0.message.messageId > 0 && $0.message.messageId <= collapsedMaxId }
    }

    let unreadTarget = unreadLineTarget(in: visible, line: input.unreadLine, reachesOldest: input.reachesOldest)
    // The unread line sits above the first positive message at or after the
    // target, only when the boundary falls inside this window: that message is
    // the target itself, an older message is shown above it, or the window
    // starts at the chat's first message. A window entirely after the line
    // (after a jump) shows none.
    let unreadIndex = unreadTarget.flatMap { target -> Int? in
      guard let index = visible.firstIndex(where: { $0.message.messageId > 0 && $0.message.messageId >= target })
      else { return nil }
      let inWindow = visible[index].message.messageId == target || input.reachesOldest
        || visible[..<index].contains { $0.message.messageId > 0 }
      return inWindow ? index : nil
    }

    var rows: [Draft] = []
    rows.reserveCapacity(visible.count + visible.count / 8 + 6)

    if let parent = input.threadParent {
      rows.append(.init(id: .threadParent(parent.id), content: .threadParent(parent)))
      rows.append(.init(id: .threadRepliesHeader, content: .threadRepliesHeader))
    }
    if let collapsedMaxId = input.collapsedMaxId {
      rows.append(.init(id: .collapsedHistory, content: .collapsedHistory(maxMessageId: collapsedMaxId)))
    }

    // One calendar lookup per day, not per message.
    var day: DateInterval?
    let days = visible.map { message -> Date in
      let date = message.message.date
      if let day, date >= day.start, date < day.end { return day.start }
      let interval = input.calendar.dateInterval(of: .day, for: date)
        ?? DateInterval(start: input.calendar.startOfDay(for: date), duration: 1)
      day = interval
      return interval.start
    }
    // A message joins the previous one's group unless a day or the unread line
    // falls between them.
    func joinsPrevious(_ index: Int) -> Bool {
      index > 0 && index != unreadIndex && days[index] == days[index - 1]
        && canGroup(visible[index - 1], visible[index], calendar: input.calendar)
    }
    var previousJoinsNext = false
    var placedUnread: Int64?
    for index in visible.indices {
      let message = visible[index]
      if index == unreadIndex {
        placedUnread = message.message.messageId
        rows.append(.init(id: .unreadLine, content: .unreadLine(firstUnreadMessageId: message.message.messageId)))
      }
      if index == 0 || days[index] != days[index - 1] {
        rows.append(.init(id: .daySeparator(days[index]), content: .daySeparator(dayStart: days[index])))
      }
      let joinsNext = index + 1 < visible.count && joinsPrevious(index + 1)
      let incoming = input.chatKind == .group && message.message.out != true && !message.message.isServiceMessage
      let isFirstInGroup = index == 0 ? true : !previousJoinsNext
      let grouping = ChatRowGrouping(
        isFirstInGroup: isFirstInGroup,
        isLastInGroup: !joinsNext,
        showsSenderName: incoming && isFirstInGroup,
        showsAvatar: incoming
      )
      rows.append(.init(id: .message(message.id), content: .message(message, grouping)))
      previousJoinsNext = joinsNext
    }

    if let statusNotice = input.statusNotice {
      rows.append(.init(id: .statusNotice, content: .statusNotice(statusNotice)))
    }
    return Output(rows: rows, unreadLineMessageId: placedUnread)
  }

  private static func unreadLineTarget(
    in messages: [FullMessage], line: UnreadLine?, reachesOldest: Bool
  ) -> Int64? {
    guard let line else { return nil }
    if let pinned = line.pinnedMessageId { return pinned }
    return ChatUnreadOpening.firstUnreadMessageId(
      in: messages, boundary: line.boundary, reachesHistoryStart: reachesOldest
    )
  }
}

public extension ChatRowSnapshot {
  /// The snapshot after `previous` with these rows. A row keeps its revision
  /// when its content is unchanged and takes this snapshot's revision when it
  /// is new or changed.
  ///
  /// `changedMessageIDs`, when the caller knows it, names every message whose
  /// data changed since `previous` (a live add, edit or delete). Other message
  /// rows then compare only their grouping, so a streaming edit costs
  /// O(changed) comparisons instead of one full message comparison per row.
  /// Nil compares every row in full.
  static func next(
    after previous: ChatRowSnapshot?, rows drafts: [ChatRowBuilder.Draft], reason: ChatRowReason,
    coverage: ChatRowCoverage, unreadLineMessageId: Int64? = nil, changedMessageIDs: Set<Int64>? = nil
  ) -> ChatRowSnapshot {
    let revision = (previous?.revision ?? 0) &+ 1
    let rows = drafts.map { draft -> ChatRow in
      if let old = previous?.row(for: draft.id) {
        if let changedMessageIDs, case let .message(id) = draft.id, !changedMessageIDs.contains(id),
           case let .message(_, oldGrouping) = old.content, case let .message(message, grouping) = draft.content
        {
          if grouping == oldGrouping { return old }
          return ChatRow(id: draft.id, revision: revision, content: .message(message, grouping))
        }
        if old.content == draft.content { return old }
      }
      return ChatRow(id: draft.id, revision: revision, content: draft.content)
    }
    return ChatRowSnapshot(
      revision: revision, reason: reason, rows: rows, coverage: coverage,
      unreadLineMessageId: unreadLineMessageId
    )
  }
}
