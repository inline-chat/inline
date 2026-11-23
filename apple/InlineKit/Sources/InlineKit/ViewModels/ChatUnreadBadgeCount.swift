import Foundation

/// The number on the scroll-to-bottom button.
///
/// It is the dialog's unread count, the same number the chat list shows. Reading lowers it in the
/// local database a few times a second, so between those writes the list's own read frontier (the
/// highest incoming message on screen) is subtracted. Once `readInboxMaxId` reaches the frontier
/// nothing is pending, so no message is counted twice.
///
/// The pending range is capped by certified coverage, and only loaded messages that count toward
/// unread are subtracted: across a gap the button waits for the write and the server's count.
public enum ChatUnreadBadgeCount {
  public static func resolve(
    unreadCount: Int,
    readInboxMaxId: Int64,
    readFrontier: Int64,
    coverage: MessageHistoryCoverageProjection,
    loadedMessages: some Sequence<FullMessage>
  ) -> Int {
    let unread = max(0, unreadCount)
    let readMaxID = max(0, readInboxMaxId)
    guard unread > 0,
          readFrontier > readMaxID,
          let pendingMaxID = coverage.certifiedReadMaxID(after: readMaxID, through: readFrontier)
    else { return unread }

    var pendingIDs = Set<Int64>()
    for full in loadedMessages {
      let message = full.message
      guard message.messageId > readMaxID,
            message.messageId <= pendingMaxID,
            message.countsTowardUnread
      else { continue }
      pendingIDs.insert(message.messageId)
    }
    return max(0, unread - pendingIDs.count)
  }

  /// "8", "800", "1.2K", "12K". Rounds down so the badge never overstates.
  public static func format(_ count: Int) -> String {
    let count = max(0, count)
    if count < 1_000 { return String(count) }
    if count < 10_000 {
      let tenths = count / 100
      return tenths % 10 == 0 ? "\(tenths / 10)K" : "\(tenths / 10).\(tenths % 10)K"
    }
    return "\(count / 1_000)K"
  }
}
