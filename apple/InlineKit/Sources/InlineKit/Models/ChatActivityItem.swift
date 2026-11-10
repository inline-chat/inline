import Foundation
import GRDB
import InlineProtocol
import Logger

/// An unseen mention (or reply) addressed to the current user, or one of their messages with
/// unseen reactions.
///
/// The server owns the counts (`Dialog.unreadMentionsCount`, `Dialog.unreadReactionsCount`);
/// these rows let a chat jump to each one and mark it read when it scrolls into view.
/// `pendingRead` rows were read on this device and are waiting for the server to confirm, so the
/// UI leaves them out. For one viewer a message is either addressed to them or theirs, so a
/// message ID alone identifies the row.
public struct ChatActivityItem: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
  public enum Kind: Int, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    /// Mentions the viewer, or replies to one of their messages.
    case mention = 1
    /// The viewer's message, with reactions they haven't seen.
    case reaction = 2
  }

  public var chatId: Int64
  public var messageId: Int64
  public var kind: Kind
  public var pendingRead: Bool

  public static let databaseTableName = "activityItem"

  public enum Columns {
    public static let chatId = Column(CodingKeys.chatId)
    public static let messageId = Column(CodingKeys.messageId)
    public static let kind = Column(CodingKeys.kind)
    public static let pendingRead = Column(CodingKeys.pendingRead)
  }

  public init(chatId: Int64, messageId: Int64, kind: Kind, pendingRead: Bool = false) {
    self.chatId = chatId
    self.messageId = messageId
    self.kind = kind
    self.pendingRead = pendingRead
  }
}

public struct ActivityCounts: Equatable, Sendable {
  public var mentions: Int
  public var reactions: Int

  public init(mentions: Int = 0, reactions: Int = 0) {
    self.mentions = mentions
    self.reactions = reactions
  }

  public var isEmpty: Bool { mentions == 0 && reactions == 0 }

  subscript(kind: ChatActivityItem.Kind) -> Int {
    get { kind == .mention ? mentions : reactions }
    set {
      if kind == .mention { mentions = newValue } else { reactions = newValue }
    }
  }
}

// MARK: - Queries

public extension ChatActivityItem {
  static func unread(chatId: Int64, kinds: [Kind] = Kind.allCases) -> QueryInterfaceRequest<ChatActivityItem> {
    ChatActivityItem
      .filter(Columns.chatId == chatId)
      .filter(Columns.pendingRead == false)
      .filter(kinds.map(\.rawValue).contains(Columns.kind))
      .order(Columns.messageId.asc)
  }

  /// The oldest unread row of `kind`, which the in-chat button jumps to next.
  static func oldestUnread(_ db: Database, chatId: Int64, kind: Kind) throws -> ChatActivityItem? {
    try unread(chatId: chatId, kinds: [kind]).fetchOne(db)
  }
}

// MARK: - Server reconciliation

extension ChatActivityItem {
  static func pendingCounts(_ db: Database, chatId: Int64) throws -> ActivityCounts {
    var counts = ActivityCounts()
    for kind in Kind.allCases {
      counts[kind] = try ChatActivityItem
        .filter(Columns.chatId == chatId)
        .filter(Columns.pendingRead == true)
        .filter(Columns.kind == kind.rawValue)
        .fetchCount(db)
    }
    return counts
  }

  /// Server counts minus this device's unconfirmed reads, unclamped (see `Dialog.unreadMentionsCount`).
  /// A kind the server reports as empty has nothing left to show, so its local rows (pending or
  /// not) are dropped.
  static func displayedCounts(_ db: Database, chatId: Int64, server: ActivityCounts) throws -> ActivityCounts {
    let emptyKinds = Kind.allCases.filter { server[$0] <= 0 }.map(\.rawValue)
    if !emptyKinds.isEmpty {
      try ChatActivityItem
        .filter(Columns.chatId == chatId)
        .filter(emptyKinds.contains(Columns.kind))
        .deleteAll(db)
    }
    let pending = try pendingCounts(db, chatId: chatId)
    return ActivityCounts(mentions: server.mentions - pending.mentions, reactions: server.reactions - pending.reactions)
  }

  /// Adds unread rows, keeping the pending flag of rows already here.
  static func insertUnread(_ db: Database, chatId: Int64, messageIds: [Int64], kind: Kind) throws {
    for messageId in messageIds {
      try ChatActivityItem(chatId: chatId, messageId: messageId, kind: kind).insert(db, onConflict: .ignore)
    }
  }

  static func remove(_ db: Database, chatId: Int64, messageIds: [Int64]) throws {
    guard !messageIds.isEmpty else { return }
    try ChatActivityItem
      .filter(Columns.chatId == chatId)
      .filter(messageIds.contains(Columns.messageId))
      .deleteAll(db)
  }

  /// Replaces this chat's rows of `kind` with a fresh, complete server list. A row the server no
  /// longer lists is gone, pending or not (a pending one was already read on the server). Rows it
  /// still lists keep their pending flag, so the counts stay exact while reads are in flight.
  /// Only a final page proves absence; a partial page just adds rows.
  static func replaceUnread(_ db: Database, chatId: Int64, kind: Kind, messageIds: [Int64], complete: Bool) throws {
    if complete {
      try ChatActivityItem
        .filter(Columns.chatId == chatId)
        .filter(Columns.kind == kind.rawValue)
        .filter(!messageIds.contains(Columns.messageId))
        .deleteAll(db)
    }
    try insertUnread(db, chatId: chatId, messageIds: messageIds, kind: kind)
  }

  /// History pages flag messages that are still unread for the viewer. Only adds rows: the
  /// ordered stream owns removals and counts. A row this adds after it was read elsewhere is
  /// cleared when this device reads it, because the server echoes every read.
  public static func insertFromHistory(_ db: Database, chatId: Int64, messages: [InlineProtocol.Message]) throws {
    let mentions = messages.filter { $0.hasUnreadMention && $0.unreadMention }.map(\.id)
    let reactions = messages.filter { $0.hasUnreadReactions && $0.unreadReactions }.map(\.id)
    guard !mentions.isEmpty || !reactions.isEmpty else { return }
    try insertUnread(db, chatId: chatId, messageIds: mentions, kind: .mention)
    try insertUnread(db, chatId: chatId, messageIds: reactions, kind: .reaction)
  }
}

// MARK: - Local reads

public extension ChatActivityItem {
  /// Marks rows read on this device before the server confirms. Returns the rows that changed.
  @discardableResult
  static func markPendingRead(_ db: Database, chatId: Int64, messageIds: [Int64]) throws -> [ChatActivityItem] {
    guard !messageIds.isEmpty else { return [] }
    let items = try unread(chatId: chatId)
      .filter(messageIds.contains(Columns.messageId))
      .fetchAll(db)
    try setPending(db, items, true)
    return items
  }

  /// The newest message this device knows in a chat. "Mark all" is bounded by it, as in
  /// Telegram, so a mention that arrives while the request is in flight stays unread.
  static func markAllBound(_ db: Database, chatId: Int64) throws -> Int64? {
    let chatLast = try Chat.fetchOne(db, id: chatId)?.lastMsgId
    let itemLast = try Int64.fetchOne(db, sql: "SELECT MAX(messageId) FROM activityItem WHERE chatId = ?", arguments: [chatId])
    return [chatLast, itemLast].compactMap(\.self).max()
  }

  /// Marks every unread row of `kinds` read locally, for "Mark all" and "Mark as Read".
  @discardableResult
  static func markAllPendingRead(
    _ db: Database,
    chatId: Int64,
    kinds: [Kind],
    maxId: Int64? = nil
  ) throws -> [ChatActivityItem] {
    let bound = maxId ?? Int64.max
    let items = try unread(chatId: chatId, kinds: kinds).filter(Columns.messageId <= bound).fetchAll(db)
    for var item in items {
      item.pendingRead = true
      try item.update(db)
    }
    // Counts may include rows this device never downloaded, all older than the bound, so a kind
    // is left with exactly the local rows newer than the bound.
    if var dialog = try dialog(db, chatId: chatId) {
      for kind in kinds where dialog.activityCount(kind) != nil {
        let remaining = try unread(chatId: chatId, kinds: [kind]).filter(Columns.messageId > bound).fetchCount(db)
        dialog.setActivityCount(kind, remaining)
      }
      try dialog.update(db)
    }
    return items
  }

  /// Undoes `markPendingRead` after a failed request.
  static func rollbackPendingRead(_ db: Database, items: [ChatActivityItem]) throws {
    var restored: [ChatActivityItem] = []
    for item in items {
      guard let current = try ChatActivityItem.fetchOne(
        db,
        key: ["chatId": item.chatId, "kind": item.kind.rawValue, "messageId": item.messageId]
      ), current.pendingRead else { continue }
      restored.append(current)
    }
    try setPending(db, restored, false)
  }

  internal static func dialog(_ db: Database, chatId: Int64) throws -> Dialog? {
    if let dialog = try Dialog.filter(Dialog.Columns.chatId == chatId).fetchOne(db) {
      return dialog
    }
    return try Dialog.fetchOne(db, id: Dialog.getDialogId(peerThreadId: chatId))
  }

  /// Flips the pending flag and moves the dialog's displayed counts the same way.
  private static func setPending(_ db: Database, _ items: [ChatActivityItem], _ pending: Bool) throws {
    guard let chatId = items.first?.chatId else { return }
    for var item in items {
      item.pendingRead = pending
      try item.update(db)
    }
    guard var dialog = try dialog(db, chatId: chatId) else { return }
    let delta = pending ? -1 : 1
    for kind in Kind.allCases {
      guard let value = dialog.activityCount(kind) else { continue }
      dialog.setActivityCount(kind, value + delta * items.filter { $0.kind == kind }.count)
    }
    try dialog.update(db)
  }
}

// MARK: - Updates

extension InlineProtocol.UpdateUnreadActivity {
  func apply(_ db: Database) throws {
    let peer = peerID.toPeer()
    guard var dialog = try Dialog.get(peerId: peer).fetchOne(db),
          let chatId = try dialog.chatId ?? Chat.getByPeerId(db: db, peerId: peer)?.id
    else {
      Log.shared.debug("Skipped unread activity update for peer without a local dialog \(peer)")
      return
    }
    try ChatActivityItem.remove(db, chatId: chatId, messageIds: clearedMessageIds)
    try ChatActivityItem.insertUnread(db, chatId: chatId, messageIds: unreadMentionIds, kind: .mention)
    try ChatActivityItem.insertUnread(db, chatId: chatId, messageIds: unreadReactionIds, kind: .reaction)
    if dialog.chatId == nil { dialog.chatId = chatId }
    try dialog.applyServerActivityCounts(
      db,
      ActivityCounts(mentions: Int(unreadMentionsCount), reactions: Int(unreadReactionsCount))
    )
    try dialog.update(db)
  }
}
