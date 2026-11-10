import Foundation
import GRDB

/// Opening a chat at its first unread message, as Telegram does: the window is read around the
/// last read message, the "Unread messages" line sits above the first unread message, and the
/// list starts with that line at the top.
///
/// The read boundary is taken once when the chat opens and kept for the whole visit, so reading
/// while the chat is open never moves or removes the line.
public enum ChatUnreadOpening {
  /// Rows read around the last read message: 44 before and 44 after, as Telegram.
  public static let windowLimit = 88

  /// The last read message id to open at, or nil when the chat opens at its newest message.
  /// Zero means nothing in the chat has been read.
  public static func boundary(unreadCount: Int?, readInboxMaxId: Int64?) -> Int64? {
    guard (unreadCount ?? 0) > 0 else { return nil }
    return max(0, readInboxMaxId ?? 0)
  }

  /// The message the unread line sits above: the first message after the boundary, past any of
  /// the user's own messages that directly follow it.
  ///
  /// `reachesHistoryStart` is true when no older message exists before the window. Without that,
  /// or a read message inside the window, the window may start after unread messages it does not
  /// hold, and its first message is not the first unread one.
  public static func firstUnreadMessageId(
    in messages: [FullMessage],
    boundary: Int64,
    reachesHistoryStart: Bool
  ) -> Int64? {
    let positive = messages.lazy.filter { $0.message.messageId > 0 }
    let containsReadMessage = positive.contains { $0.message.messageId <= boundary }
    guard containsReadMessage || reachesHistoryStart else { return nil }
    return positive
      .filter { $0.message.messageId > boundary && $0.message.out != true }
      .map(\.message.messageId)
      .min()
  }

  /// The unread line for rows shown by a progressive view model, which knows whether the
  /// window reaches the start of history.
  @MainActor
  public static func firstUnreadMessageId(
    in messages: [FullMessage],
    boundary: Int64,
    of model: MessagesProgressiveViewModel
  ) -> Int64? {
    firstUnreadMessageId(
      in: messages,
      boundary: boundary,
      reachesHistoryStart: !model.canLoadOlderFromLocal && model.historyCoverage.hasCertifiedOlderEdge
    )
  }

  /// Whether a window holds the boundary with the messages after it, so it can be opened as is.
  public static func windowReachesBoundary(_ messages: [FullMessage], boundary: Int64) -> Bool {
    guard let oldest = messages.lazy.map(\.message.messageId).filter({ $0 > 0 }).min() else { return false }
    return oldest <= boundary
  }

  /// The first window for a chat with unread messages, from the local cache only: the latest
  /// page when the part of it the view model keeps reaches the boundary, else the certified
  /// window around the boundary. Nil when history must be fetched first.
  public nonisolated static func localOpeningWindow(
    _ db: Database,
    peer: Peer,
    chatId: Int64? = nil,
    boundary: Int64,
    latest: [FullMessage]
  ) throws -> [FullMessage]? {
    if try opensAtLine(latest, db: db, peer: peer, boundary: boundary) {
      return latest
    }
    guard let around = try certifiedWindow(db, peer: peer, chatId: chatId, boundary: boundary),
          try opensAtLine(around, db: db, peer: peer, boundary: boundary)
    else { return nil }
    return around
  }

  /// Whether the part of a window the view model keeps can place the unread line: it reaches the
  /// read side (a read message, or the start of history) and the unread side (a message after the
  /// boundary, or proof that none exists). A latest page whose cached tail stops at the last read
  /// message reaches the boundary but cannot show what follows it (open-at-unread fuzz, 2026-11-08).
  nonisolated static func opensAtLine(
    _ window: [FullMessage],
    db: Database,
    peer: Peer,
    boundary: Int64
  ) throws -> Bool {
    let metadata = try MessagesProgressiveViewModel.loadedWindowMetadata(db, peer: peer, messages: window)
    let shown = metadata.historyCoverage.contiguousWindow(from: window)
    let shownMetadata = shown.count == window.count
      ? metadata
      : try MessagesProgressiveViewModel.loadedWindowMetadata(db, peer: peer, messages: shown)
    let coverage = shownMetadata.historyCoverage
    let reachesHistoryStart = !shownMetadata.canLoadOlderFromLocal && coverage.hasCertifiedOlderEdge
    guard windowReachesBoundary(shown, boundary: boundary) || reachesHistoryStart else { return false }
    return shown.contains { $0.message.messageId > boundary } || coverage.isAtCertifiedLiveEnd
  }

  /// A local window around the boundary that durable history coverage proves continuous, or nil
  /// when the chat's cache cannot show it without fetching. The window is the one the progressive
  /// view model keeps, so no row in it is dropped on the way to the screen.
  public nonisolated static func certifiedWindow(
    _ db: Database,
    peer: Peer,
    chatId: Int64? = nil,
    boundary: Int64
  ) throws -> [FullMessage]? {
    guard let window = try MessagesProgressiveViewModel.localWindowAroundCoordinate(
      db,
      peer: peer,
      chatId: chatId,
      messageID: max(1, boundary),
      limit: windowLimit
    ), !window.isEmpty else { return nil }

    // A missing boundary row is already proven by `localWindowAroundCoordinate`. Any
    // unknown gap between rows would make the view model drop the side across it.
    let metadata = try MessagesProgressiveViewModel.loadedWindowMetadata(db, peer: peer, messages: window)
    guard metadata.historyCoverage.contiguousWindow(from: window).count == window.count else { return nil }
    return window
  }
}
