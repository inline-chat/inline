import Foundation

// One shared row projection for the chat message lists (iOS, macOS, ChatList).
// A snapshot is an ordered, revisioned list of rows, oldest first, with the
// window's coverage and the reason it was published. Consumers diff by row id
// and row revision (`ChatRowDiff`) instead of reloading.

/// A row's identity. Stable for the life of the row: a sent message keeps its
/// id through the temporary-to-server id swap (`FullMessage.id` is the local
/// row id, `globalId`), so an acknowledged send is one row, not delete+insert.
public enum ChatRowID: Hashable, Sendable {
  /// `FullMessage.id`; for an album, its oldest item's, so an album keeps its row as it fills in.
  case message(Int64)
  /// The thread's parent message, shown at the top of a reply thread.
  case threadParent(Int64)
  /// The "replies" header under the thread's parent message.
  case threadRepliesHeader
  /// The marker over history the user cleared (`collapsedMaxId`).
  case collapsedHistory
  /// A day separator, keyed by the start of that day in the builder's calendar.
  case daySeparator(Date)
  /// The unread line. One per chat visit.
  case unreadLine
  /// A line under the newest message, such as a DM peer's silencing Focus.
  case statusNotice
}

/// Where a message sits in its sender group. Part of the row's content, so a
/// neighbour inserted or deleted changes the revision of the rows whose
/// rendering changes, and consumers never recompute groups. Whether a row is
/// the window's first or last message is positional (its index); it is left
/// out so a new message does not change the previous newest row.
public struct ChatRowGrouping: Hashable, Sendable {
  /// No earlier message in the same group (oldest of its group).
  public var isFirstInGroup: Bool
  /// No later message in the same group (newest of its group).
  public var isLastInGroup: Bool
  /// Group chats: the sender's name heads the group.
  public var showsSenderName: Bool
  /// Group chats: the message belongs to an avatar group (incoming, not a
  /// service message). Hosts draw the avatar at the group edge they choose.
  public var showsAvatar: Bool

  public init(
    isFirstInGroup: Bool = true, isLastInGroup: Bool = true,
    showsSenderName: Bool = false, showsAvatar: Bool = false
  ) {
    self.isFirstInGroup = isFirstInGroup
    self.isLastInGroup = isLastInGroup
    self.showsSenderName = showsSenderName
    self.showsAvatar = showsAvatar
  }
}

/// Everything a row renders from. Two equal contents render identically, so a
/// row's revision changes exactly when its content changes. Day labels ("Today")
/// and other text are formatted by the host from these values.
public enum ChatRowContent: Equatable, Sendable {
  case message(FullMessage, ChatRowGrouping)
  /// Photos and videos sent together, in one bubble (`MessageAlbums`). Keyed as its oldest item.
  case album(MessageAlbum, ChatRowGrouping)
  case threadParent(FullMessage)
  case threadRepliesHeader
  case collapsedHistory(maxMessageId: Int64)
  case daySeparator(dayStart: Date)
  /// Above the first unread message, which has this server id.
  case unreadLine(firstUnreadMessageId: Int64)
  case statusNotice(String)

  /// The row's message; an album's oldest item (its sender, reply and identity).
  public var message: FullMessage? {
    switch self {
      case let .message(message, _), let .threadParent(message): message
      case let .album(album, _): album.lead
      default: nil
    }
  }

  /// Every message the row draws: an album's items, oldest first, or its one message.
  public var messages: [FullMessage] {
    switch self {
      case let .album(album, _): album.items
      default: message.map { [$0] } ?? []
    }
  }

  /// The row's newest message: what reading the row marks read, and the row's time.
  public var newestMessage: FullMessage? {
    switch self {
      case let .album(album, _): album.newest
      default: message
    }
  }

  /// Whether the row draws the message with this server id (an album draws several).
  public func contains(messageId: Int64) -> Bool {
    switch self {
      case let .album(album, _): album.items.contains { $0.message.messageId == messageId }
      default: message?.message.messageId == messageId
    }
  }

  public var grouping: ChatRowGrouping? {
    switch self {
      case let .message(_, grouping), let .album(_, grouping): grouping
      default: nil
    }
  }

  public var album: MessageAlbum? {
    if case let .album(album, _) = self { album } else { nil }
  }
}

public struct ChatRow: Equatable, Identifiable, Sendable {
  public let id: ChatRowID
  /// The snapshot revision at which this row's content last changed.
  public let revision: UInt64
  public let content: ChatRowContent

  public init(id: ChatRowID, revision: UInt64, content: ChatRowContent) {
    self.id = id
    self.revision = revision
    self.content = content
  }
}

/// What the window reaches, from the view model's history coverage.
public struct ChatRowCoverage: Equatable, Sendable {
  /// The window starts at the chat's first message: nothing older is cached and
  /// the older edge is certified.
  public var reachesOldest: Bool
  /// The window ends at the certified live end.
  public var reachesNewest: Bool
  public var canLoadOlderFromLocal: Bool
  public var canLoadNewerFromLocal: Bool

  public init(
    reachesOldest: Bool = false, reachesNewest: Bool = false,
    canLoadOlderFromLocal: Bool = false, canLoadNewerFromLocal: Bool = false
  ) {
    self.reachesOldest = reachesOldest
    self.reachesNewest = reachesNewest
    self.canLoadOlderFromLocal = canLoadOlderFromLocal
    self.canLoadNewerFromLocal = canLoadNewerFromLocal
  }
}

public enum ChatRowJumpTarget: Equatable, Sendable {
  /// A window around this server message id.
  case message(Int64)
  /// The window the chat opens on for its unread line.
  case unreadLine(boundary: Int64)
  /// The newest messages.
  case latest
}

/// Why a snapshot was published.
public enum ChatRowReason: Equatable, Sendable {
  /// The first snapshot of a chat view model, opened at this anchor.
  case initialOpen(ChatOpenAnchor)
  case olderPage
  case newerPage
  /// Messages arrived from elsewhere.
  case liveAdd
  /// Rows changed in place: edits, reactions, pins, read cursors, a send failing.
  case liveUpdate
  case delete
  /// The window was read again from the database: a reload, reconnect
  /// catch-up, history repair, or the thread's parent message arriving.
  case refresh
  /// The window was replaced by another one.
  case jump(ChatRowJumpTarget)
  /// The current user's message, not yet acknowledged, was added.
  case localSend
  /// A sent message gained its server id.
  case sendAck
  /// Presentation input changed without the messages changing: collapsed
  /// history, the status notice, or the unread boundary.
  case presentation
  /// Rows far from the reader left a long window (`trimWindow`).
  case trim
}

public struct ChatRowSnapshot: Equatable, Sendable {
  /// Monotonic per view model, starting at 1.
  public let revision: UInt64
  public let reason: ChatRowReason
  /// Oldest first.
  public let rows: [ChatRow]
  public let coverage: ChatRowCoverage
  /// The message the unread line sits above, if it is shown.
  public let unreadLineMessageId: Int64?
  private let indices: [ChatRowID: Int]

  public init(
    revision: UInt64, reason: ChatRowReason, rows: [ChatRow], coverage: ChatRowCoverage,
    unreadLineMessageId: Int64? = nil
  ) {
    self.revision = revision
    self.reason = reason
    self.rows = rows
    self.coverage = coverage
    self.unreadLineMessageId = unreadLineMessageId
    var indices: [ChatRowID: Int] = [:]
    indices.reserveCapacity(rows.count)
    for (index, row) in rows.enumerated() { indices[row.id] = index }
    self.indices = indices
  }

  public var ids: [ChatRowID] { rows.map(\.id) }

  public func index(of id: ChatRowID) -> Int? { indices[id] }

  public func row(for id: ChatRowID) -> ChatRow? { indices[id].map { rows[$0] } }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.revision == rhs.revision && lhs.reason == rhs.reason && lhs.rows == rhs.rows
      && lhs.coverage == rhs.coverage && lhs.unreadLineMessageId == rhs.unreadLineMessageId
  }
}
