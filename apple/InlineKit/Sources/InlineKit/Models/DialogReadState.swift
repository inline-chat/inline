import Foundation
import GRDB

/// What reading changed on this device.
enum LocalReadChange: Equatable {
  /// Nothing to read.
  case unchanged
  /// The read cursor moved: `ReadStateSync` pushes it.
  case advanced(throughId: Int64)
  /// Only the unread mark was cleared (the cursor was already at the end): the server still has
  /// the mark and needs its own read to clear it.
  case clearedMark
}

// Reading follows Telegram's model: the read cursor and unread count move in the local database
// the moment messages are seen, so the chat, chat list, app icon and Dock change together, and
// `ReadStateSync` pushes the cursor afterwards (`applyMaxReadIndexInteractively` and
// `ManagedSynchronizePeerReadStates`).
extension Dialog {
  /// Reads through `maxId` on this device. The count drops by the stored messages in the range
  /// that count toward unread, as the server counts them; reading through the chat's last
  /// message reads everything. Callers cap `maxId` to certified history (`AutomaticReadAdmission`),
  /// so no message in the range is missing from the count.
  static func applyLocalRead(_ db: Database, peerId: Peer, through maxId: Int64) throws -> LocalReadChange {
    guard maxId > 0, var dialog = try Dialog.get(peerId: peerId).fetchOne(db) else { return .unchanged }
    let current = max(0, dialog.readInboxMaxId ?? 0)
    guard maxId > current else { return .unchanged }

    let lastMsgId = try Self.lastConfirmedMessageId(db, dialog: dialog)
    if let lastMsgId, maxId >= lastMsgId {
      dialog.unreadCount = 0
    } else if let chatId = dialog.chatId {
      let read = try Message.localUnreadCount(db, chatId: chatId, after: current, through: maxId)
      dialog.unreadCount = max(0, (dialog.unreadCount ?? 0) - read)
    }
    dialog.readInboxMaxId = maxId
    // Reading clears a mark, as the server's read does.
    dialog.unreadMark = false
    try dialog.update(db)
    return .advanced(throughId: maxId)
  }

  /// Reads the whole chat on this device: through its last message, count zero, no mark.
  static func applyLocalReadToEnd(_ db: Database, peerId: Peer) throws -> LocalReadChange {
    guard var dialog = try Dialog.get(peerId: peerId).fetchOne(db) else { return .unchanged }
    let current = max(0, dialog.readInboxMaxId ?? 0)
    let wasMarked = dialog.unreadMark == true
    let hadCount = (dialog.unreadCount ?? 0) != 0

    if let lastMsgId = try Self.lastConfirmedMessageId(db, dialog: dialog), lastMsgId > current {
      dialog.readInboxMaxId = lastMsgId
      dialog.unreadCount = 0
      dialog.unreadMark = false
      try dialog.update(db)
      return .advanced(throughId: lastMsgId)
    }
    guard wasMarked || hadCount else { return .unchanged }
    dialog.unreadCount = 0
    dialog.unreadMark = false
    try dialog.update(db)
    return wasMarked ? .clearedMark : .unchanged
  }

  /// The cursor to push for this dialog, or nil when the server has it.
  static func pendingReadMaxId(_ db: Database, dialogId: Int64) throws -> Int64? {
    guard let dialog = try Dialog.fetchOne(db, id: dialogId) else { return nil }
    let local = max(0, dialog.readInboxMaxId ?? 0)
    return local > max(0, dialog.serverReadInboxMaxId ?? 0) ? local : nil
  }

  /// Records that the server has this dialog's reads through `maxId`.
  static func confirmServerRead(_ db: Database, dialogId: Int64, through maxId: Int64) throws {
    guard var dialog = try Dialog.fetchOne(db, id: dialogId),
          maxId > max(0, dialog.serverReadInboxMaxId ?? 0) else { return }
    dialog.serverReadInboxMaxId = maxId
    try dialog.update(db)
  }

  /// Dialogs with reads the server has not got, for the sync to resume after a relaunch or a
  /// reconnect.
  static func pendingReadPeers(_ db: Database) throws -> [Peer] {
    try Dialog
      .filter(sql: #"COALESCE("readInboxMaxId", 0) > COALESCE("serverReadInboxMaxId", 0)"#)
      .fetchAll(db)
      .map(\.peerId)
  }

  /// A server dialog over the stored one. The server's cursor is confirmed, but it never moves
  /// the local cursor back, and the count and mark that go with a cursor stay with it: a dialog
  /// behind this device predates a read made here. Like `UpdateReadMaxId`, and Telegram keeping
  /// local read state while `localReadMarkIsAheadOfServer`.
  mutating func keepReadState(of existing: Dialog, serverReadMaxId: Int64?) {
    if max(0, serverReadMaxId ?? 0) < max(0, existing.readInboxMaxId ?? 0) {
      readInboxMaxId = existing.readInboxMaxId
      unreadCount = existing.unreadCount
      unreadMark = existing.unreadMark
    }
    serverReadInboxMaxId = [existing.serverReadInboxMaxId, serverReadMaxId].compactMap { $0 }.max()
  }

  /// The chat's newest message the server has assigned an id to, if known here.
  private static func lastConfirmedMessageId(_ db: Database, dialog: Dialog) throws -> Int64? {
    let chat: Chat? = if let chatId = dialog.chatId {
      try Chat.fetchOne(db, id: chatId)
    } else {
      try Chat.getByPeerId(db: db, peerId: dialog.peerId)
    }
    guard let lastMsgId = chat?.lastMsgId, lastMsgId > 0 else { return nil }
    return lastMsgId
  }
}
