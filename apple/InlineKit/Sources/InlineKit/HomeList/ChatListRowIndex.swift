import GRDB

/// The keys chat list rows are joined on, for every dialog, chat and draft, so `ChatListChangeRouter`
/// maps a committed row to the list rows that read it with dictionary lookups instead of table scans.
///
/// Mirrors the joins in `ChatListDatabaseQuery`: a dialog's row is drawn from the chat
/// `COALESCE(chatId, peerThreadId)` and shows its peer user, the draft keyed by its peer, and the chat's
/// last message with its sender, translation and document. A reply thread's row also shows its parent
/// chat, the parent's DM peer (`COALESCE` of the peer of the dialog whose `chatId` is the parent, and the
/// parent's own peer), and the anchor message with its document.
///
/// The router primes it once with a full read and keeps it current at each commit by reading the changed
/// rows by primary key, so a commit costs the same however many chats there are.
struct ChatListRowIndex: Equatable, Sendable {
  struct MessageKey: Hashable, Sendable {
    let chatID: Int64
    let messageID: Int64
  }

  struct DialogKeys: Equatable, Sendable {
    var peerUserID: Int64?
    var peerThreadID: Int64?
    var chatID: Int64?

    /// The chat the row is drawn from.
    var listChatID: Int64? { chatID ?? peerThreadID }

    /// `draft2.peerKey` as the chat list joins it.
    var draftKey: String? {
      if let peerUserID { return "user_\(peerUserID)" }
      return peerThreadID.map { "thread_\($0)" }
    }
  }

  struct ChatKeys: Equatable, Sendable {
    var peerUserID: Int64?
    var parentChatID: Int64?
    var parentMessageID: Int64?
    var lastMessageID: Int64?
    /// Rowids (`globalId`) of the last and anchor messages, so their deletes and id rewrites (a sent
    /// message getting its server id) still reach the rows that showed them.
    var lastMessageRowID: Int64?
    var anchorMessageRowID: Int64?
    var lastSenderID: Int64?
    var lastDocumentID: Int64?
    var anchorDocumentID: Int64?

    var anchor: MessageKey? {
      guard let parentChatID, let parentMessageID else { return nil }
      return MessageKey(chatID: parentChatID, messageID: parentMessageID)
    }
  }

  private(set) var dialogs: [Int64: DialogKeys] = [:]
  private(set) var chats: [Int64: ChatKeys] = [:]
  /// `draft2` rowid to `peerKey`: a deleted draft can no longer be read.
  private(set) var draftKeys: [Int64: String] = [:]
  /// The parent DM peers a reply thread under each chat shows.
  private(set) var listPeers: [Int64: Set<Int64>] = [:]

  private var rowsByChat = Multimap<Int64, Int64>()
  /// The `parentDialog` join: dialogs by `chatId` alone.
  private var dialogsByChatID = Multimap<Int64, Int64>()
  private var rowsByPeerUser = Multimap<Int64, Int64>()
  private var rowsByDraftKey = Multimap<String, Int64>()
  private var threadsByParent = Multimap<Int64, Int64>()
  private var threadsByAnchor = Multimap<MessageKey, Int64>()
  private var chatsByLastSender = Multimap<Int64, Int64>()
  private var chatsByLastDocument = Multimap<Int64, Int64>()
  private var threadsByAnchorDocument = Multimap<Int64, Int64>()
  private var chatsByListPeer = Multimap<Int64, Int64>()
  private var chatsByLastMessageRow = Multimap<Int64, Int64>()
  private var threadsByAnchorRow = Multimap<Int64, Int64>()

  // MARK: Reading

  /// Dialog rows drawn from these chats.
  func rows(ofChats chatIDs: some Sequence<Int64>) -> Set<Int64> {
    var rows = Set<Int64>()
    for chatID in chatIDs { rows.formUnion(rowsByChat[chatID]) }
    return rows
  }

  /// Rows of the reply threads under these chats, which show the parent's title and DM peer.
  func rows(ofThreadsUnder parentIDs: some Sequence<Int64>) -> Set<Int64> {
    var threads = Set<Int64>()
    for parentID in parentIDs { threads.formUnion(threadsByParent[parentID]) }
    return rows(ofChats: threads)
  }

  func rows(ofDraftKey key: String) -> Set<Int64> {
    rowsByDraftKey[key]
  }

  /// Rows that show this message: as their chat's last message, or as a thread's anchor.
  func rows(showingMessage key: MessageKey) -> Set<Int64> {
    var chats = threadsByAnchor[key]
    if self.chats[key.chatID]?.lastMessageID == key.messageID {
      chats.insert(key.chatID)
    }
    return rows(ofChats: chats)
  }

  /// Rows that show this message's translation: as their chat's last message.
  func rows(translating key: MessageKey) -> Set<Int64> {
    chats[key.chatID]?.lastMessageID == key.messageID ? rows(ofChats: [key.chatID]) : []
  }

  /// Rows that show this user: as the DM peer, the last sender, or a reply thread's parent DM peer.
  func rows(showingUser userID: Int64) -> Set<Int64> {
    rowsByPeerUser[userID]
      .union(rows(ofChats: chatsByLastSender[userID]))
      .union(rows(ofThreadsUnder: chatsByListPeer[userID]))
  }

  /// Rows that show this document: on their last message or a thread's anchor.
  func rows(showingDocument documentID: Int64) -> Set<Int64> {
    rows(ofChats: chatsByLastDocument[documentID].union(threadsByAnchorDocument[documentID]))
  }

  /// Chats whose last or anchor message was this row when the index last read them.
  func chats(linkedToMessageRow rowID: Int64) -> Set<Int64> {
    chatsByLastMessageRow[rowID].union(threadsByAnchorRow[rowID])
  }

  /// Chats whose stored keys a write to this message can change.
  func chats(readingMessage key: MessageKey) -> Set<Int64> {
    var chats = threadsByAnchor[key]
    if self.chats[key.chatID]?.lastMessageID == key.messageID {
      chats.insert(key.chatID)
    }
    return chats
  }

  // MARK: Writing

  mutating func setDialog(_ id: Int64, _ keys: DialogKeys?) {
    if let old = dialogs[id] {
      rowsByChat.remove(id, from: old.listChatID)
      dialogsByChatID.remove(id, from: old.chatID)
      rowsByPeerUser.remove(id, from: old.peerUserID)
      rowsByDraftKey.remove(id, from: old.draftKey)
    }
    dialogs[id] = keys
    if let keys {
      rowsByChat.insert(id, into: keys.listChatID)
      dialogsByChatID.insert(id, into: keys.chatID)
      rowsByPeerUser.insert(id, into: keys.peerUserID)
      rowsByDraftKey.insert(id, into: keys.draftKey)
    }
  }

  mutating func setChat(_ id: Int64, _ keys: ChatKeys?) {
    if let old = chats[id] {
      threadsByParent.remove(id, from: old.parentChatID)
      threadsByAnchor.remove(id, from: old.anchor)
      chatsByLastSender.remove(id, from: old.lastSenderID)
      chatsByLastDocument.remove(id, from: old.lastDocumentID)
      threadsByAnchorDocument.remove(id, from: old.anchorDocumentID)
      chatsByLastMessageRow.remove(id, from: old.lastMessageRowID)
      threadsByAnchorRow.remove(id, from: old.anchorMessageRowID)
    }
    chats[id] = keys
    if let keys {
      threadsByParent.insert(id, into: keys.parentChatID)
      threadsByAnchor.insert(id, into: keys.anchor)
      chatsByLastSender.insert(id, into: keys.lastSenderID)
      chatsByLastDocument.insert(id, into: keys.lastDocumentID)
      threadsByAnchorDocument.insert(id, into: keys.anchorDocumentID)
      chatsByLastMessageRow.insert(id, into: keys.lastMessageRowID)
      threadsByAnchorRow.insert(id, into: keys.anchorMessageRowID)
    }
  }

  mutating func setDraft(rowID: Int64, key: String?) {
    draftKeys[rowID] = key
  }

  /// Recomputes the parent DM peers a thread under `chatID` shows, after the chat or a dialog whose
  /// `chatId` is (or was) the chat changed.
  mutating func updateListPeers(of chatID: Int64) {
    var peers = Set<Int64>()
    if let chat = chats[chatID] {
      let parentDialogs = dialogsByChatID[chatID]
      if parentDialogs.isEmpty {
        if let peer = chat.peerUserID { peers.insert(peer) }
      } else {
        for dialogID in parentDialogs {
          if let peer = dialogs[dialogID]?.peerUserID ?? chat.peerUserID { peers.insert(peer) }
        }
      }
    }
    for peer in listPeers[chatID] ?? [] where !peers.contains(peer) {
      chatsByListPeer.remove(chatID, from: peer)
    }
    for peer in peers {
      chatsByListPeer.insert(chatID, into: peer)
    }
    listPeers[chatID] = peers.isEmpty ? nil : peers
  }

  // MARK: Database

  /// Reads every dialog, chat and draft.
  static func primed(_ db: Database) throws -> ChatListRowIndex {
    var index = ChatListRowIndex()
    for (id, keys) in try fetchDialogKeys(db, ids: nil) { index.setDialog(id, keys) }
    for (id, keys) in try fetchChatKeys(db, ids: nil) { index.setChat(id, keys) }
    for (rowID, key) in try fetchDraftKeys(db, rowIDs: nil) { index.setDraft(rowID: rowID, key: key) }
    for chatID in index.chats.keys { index.updateListPeers(of: chatID) }
    return index
  }

  static func fetchDialogKeys(_ db: Database, ids: Set<Int64>?) throws -> [Int64: DialogKeys] {
    let sql = "SELECT id, peerUserId, peerThreadId, chatId FROM dialog"
    let rows = if let ids {
      try Row.fetchAll(db.cachedStatement(sql: sql + " WHERE id IN (SELECT value FROM json_each(?))"), arguments: [jsonArray(ids)])
    } else {
      try Row.fetchAll(db, sql: sql)
    }
    var keys: [Int64: DialogKeys] = [:]
    for row in rows {
      keys[row[0]] = DialogKeys(peerUserID: row[1], peerThreadID: row[2], chatID: row[3])
    }
    return keys
  }

  static func fetchChatKeys(_ db: Database, ids: Set<Int64>?) throws -> [Int64: ChatKeys] {
    let sql = """
    SELECT c.id, c.peerUserId, c.parentChatId, c.parentMessageId, c.lastMsgId,
      lm.fromId, lm.documentId, am.documentId, lm.globalId, am.globalId
    FROM chat c
    LEFT JOIN message lm ON lm.chatId = c.id AND lm.messageId = c.lastMsgId
    LEFT JOIN message am ON am.chatId = c.parentChatId AND am.messageId = c.parentMessageId
    """
    let rows = if let ids {
      try Row.fetchAll(db.cachedStatement(sql: sql + " WHERE c.id IN (SELECT value FROM json_each(?))"), arguments: [jsonArray(ids)])
    } else {
      try Row.fetchAll(db, sql: sql)
    }
    var keys: [Int64: ChatKeys] = [:]
    for row in rows {
      keys[row[0]] = ChatKeys(
        peerUserID: row[1], parentChatID: row[2], parentMessageID: row[3], lastMessageID: row[4],
        lastMessageRowID: row[8], anchorMessageRowID: row[9],
        lastSenderID: row[5], lastDocumentID: row[6], anchorDocumentID: row[7]
      )
    }
    return keys
  }

  static func fetchDraftKeys(_ db: Database, rowIDs: Set<Int64>?) throws -> [Int64: String] {
    let sql = "SELECT rowid, peerKey FROM draft2"
    let rows = if let rowIDs {
      try Row.fetchAll(db.cachedStatement(sql: sql + " WHERE rowid IN (SELECT value FROM json_each(?))"), arguments: [jsonArray(rowIDs)])
    } else {
      try Row.fetchAll(db, sql: sql)
    }
    var keys: [Int64: String] = [:]
    for row in rows { keys[row[0]] = row[1] }
    return keys
  }

  /// `(chatId, messageId)` of rows of `message` (by `globalId`) or `translation` (by rowid).
  static func fetchMessageKeys(_ db: Database, table: String, rowIDs: Set<Int64>) throws -> [MessageKey] {
    let rowIDColumn = table == "message" ? "globalId" : "rowid"
    return try Row.fetchAll(
      db.cachedStatement(sql: "SELECT chatId, messageId FROM \(table) WHERE \(rowIDColumn) IN (SELECT value FROM json_each(?))"),
      arguments: [jsonArray(rowIDs)]
    ).compactMap { row in
      guard let chatID: Int64 = row[0], let messageID: Int64 = row[1] else { return nil }
      return MessageKey(chatID: chatID, messageID: messageID)
    }
  }

  static func fetchDocumentIDs(_ db: Database, rowIDs: Set<Int64>) throws -> [Int64] {
    try Int64?.fetchAll(
      db.cachedStatement(sql: "SELECT documentId FROM document WHERE rowid IN (SELECT value FROM json_each(?))"),
      arguments: [jsonArray(rowIDs)]
    ).compactMap { $0 }
  }
}

/// Sets of values by key, with empty sets removed.
struct Multimap<Key: Hashable & Sendable, Value: Hashable & Sendable>: Equatable, Sendable {
  private var storage: [Key: Set<Value>] = [:]

  subscript(key: Key) -> Set<Value> {
    storage[key] ?? []
  }

  mutating func insert(_ value: Value, into key: Key?) {
    guard let key else { return }
    storage[key, default: []].insert(value)
  }

  mutating func remove(_ value: Value, from key: Key?) {
    guard let key, var values = storage[key] else { return }
    values.remove(value)
    storage[key] = values.isEmpty ? nil : values
  }
}

func jsonArray(_ values: Set<Int64>) -> String {
  "[" + values.map(String.init).joined(separator: ",") + "]"
}
