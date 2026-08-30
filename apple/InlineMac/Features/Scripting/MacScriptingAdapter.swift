import AppKit
import Auth
import GRDB
import InlineKit
import InlineMacScripting
import RealtimeV2

/// The only application-specific part of the AppleScript module. No independent account or cache.
@MainActor
final class MacScriptingAdapter {
  private weak var delegate: AppDelegate?

  init(delegate: AppDelegate) { self.delegate = delegate }

  func execute(_ request: ScriptingRequest) async throws -> ScriptingValue {
    do { return try await perform(request) }
    catch is AuthStorageError { throw ScriptingError.unavailable }
  }

  private func perform(_ request: ScriptingRequest) async throws -> ScriptingValue {
    guard let delegate else { throw ScriptingError.unavailable }
    if request == .show {
      delegate.showAndFocusMainWindow()
      return .boolean(true)
    }

    guard delegate.scriptingAccountIsReady else { throw ScriptingError.unavailable }
    let auth = delegate.dependencies.auth.handle
    let token = try auth.beginAccountMutation()

    let database = delegate.dependencies.database
    let result: ScriptingValue
    switch request {
    case .show: return .boolean(true)
    case .account:
      result = try await database.reader.read { db in
        try auth.validateAccountMutation(token)
        guard let user = try User.fetchOne(db, id: token.userID) else { throw ScriptingError.notFound }
        return .record([
          .userID: .text(String(user.id)),
          .displayName: .text(Self.name(first: user.firstName, last: user.lastName, username: user.username)),
          .username: .text(user.username ?? ""),
        ])
      }
    case let .spaces(limit, offset):
      result = try await database.reader.read { db in
        try auth.validateAccountMutation(token)
        return .list(try Space.order(Space.Columns.id).limit(limit, offset: offset).fetchAll(db).map {
          .record([.spaceID: .text(String($0.id)), .title: .text($0.name)])
        })
      }
    case let .chats(query, spaceID, limit, offset):
      result = try await database.reader.read { db in
        try auth.validateAccountMutation(token)
        var sql = Self.chatSQL
        var arguments: StatementArguments = []
        if let spaceID {
          sql += " AND c.spaceId = ?"
          arguments += [spaceID]
        }
        if let query {
          // Bound parameters + escaped LIKE metacharacters make this a literal substring search.
          let pattern = "%" + query.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
          sql += """
             AND (c.title LIKE ? ESCAPE '\\' OR
             trim(coalesce(u.firstName, '') || ' ' || coalesce(u.lastName, '')) LIKE ? ESCAPE '\\' OR
             u.username LIKE ? ESCAPE '\\')
            """
          arguments += [pattern, pattern, pattern]
        }
        sql += " ORDER BY c.id LIMIT ? OFFSET ?"
        arguments += [limit, offset]
        return .list(try Row.fetchAll(db, sql: sql, arguments: arguments).map(Self.chatRecord))
      }
    case .currentChat:
      guard let peer = Self.frontWindow?.scriptingPrimaryChat else { return .missing }
      result = try await database.reader.read { db in
        try auth.validateAccountMutation(token)
        let condition: String
        let id: Int64
        switch peer {
        case let .user(userID): condition = "c.type = 'private' AND c.peerUserId = ?"; id = userID
        case let .thread(chatID): condition = "c.type = 'thread' AND c.id = ?"; id = chatID
        }
        guard let row = try Row.fetchOne(db, sql: Self.chatSQL + " AND " + condition, arguments: [id]) else {
          return .missing
        }
        return Self.chatRecord(row)
      }
    case let .messages(chatID, limit, before):
      result = try await database.reader.read { db in
        try auth.validateAccountMutation(token)
        let chat = try Self.cachedChat(db, id: chatID)
        let collapsed: Int64 = chat["scriptingCollapsedMaxId"]
        var messages = Message.filter(Column("chatId") == chatID)
          .filter(Column("messageId") > max(0, collapsed))
        if let before { messages = messages.filter(Column("messageId") < before) }
        return .list(try messages.order(Column("messageId").desc).limit(limit).fetchAll(db).map {
          .record([
            .messageID: .text(String($0.messageId)), .chatID: .text(String(chatID)),
            .senderID: .text(String($0.fromId)), .text: .text($0.text ?? ""),
            .sentAt: .seconds($0.date.timeIntervalSince1970), .outgoing: .boolean($0.fromId == token.userID),
          ])
        })
      }
    case let .openChat(chatID), let .link(chatID), let .send(_, chatID, _):
      let chat = try await database.reader.read { db in
        try auth.validateAccountMutation(token)
        return try Chat(row: Self.cachedChat(db, id: chatID))
      }
      try validate(auth: auth, token: token, delegate: delegate)
      guard let peer = chat.deepLinkPeer else { throw ScriptingError.notFound }
      switch request {
      case .openChat:
        let window = Self.frontWindow ?? MainWindowController.showDefault(dependencies: delegate.dependencies)
        window.openChat(peer: peer, targetMessageId: nil)
        window.window?.deminiaturize(nil)
        window.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        result = .text(String(chatID))
      case .link:
        guard let link = InlineDeepLink.chat(id: chatID).url else { throw ScriptingError.notFound }
        result = .text(link.absoluteString)
      case let .send(text, _, requestID):
        let realtime = delegate.dependencies.realtimeV2
        do {
          let response = try await realtime.callRpcDirect(
            method: .sendMessage,
            input: .sendMessage(.with {
              $0.peerID = peer.toInputPeer()
              $0.message = text
              $0.randomID = requestID
            }),
            timeout: .seconds(20),
            accountToken: token
          )
          try validate(auth: auth, token: token, delegate: delegate)
          guard case let .sendMessage(sent) = response else { throw ScriptingError.failed }
          // The update ID mapping is the server's receipt, including deduplicated retries.
          let messageID = sent.updates.compactMap { update -> Int64? in
            guard case let .updateMessageID(mapping) = update.update,
                  mapping.randomID == requestID, mapping.messageID > 0 else { return nil }
            return mapping.messageID
          }.first
          try await realtime.applyUpdatesAndWait(sent.updates, accountToken: token)
          try validate(auth: auth, token: token, delegate: delegate)
          guard let messageID else {
            throw ScriptingError(-10000, "The server acknowledged the send but returned no message ID. Check the chat before retrying.")
          }
          result = .record([
            .chatID: .text(String(chatID)), .messageID: .text(String(messageID)), .requestID: .text(String(requestID)),
          ])
        } catch let error as RealtimeDirectRpcError {
          switch error {
          case .timeout, .commitOutcomeUnknown: throw ScriptingError.timeout
          default: throw ScriptingError(-10000, error.localizedDescription)
          }
        }
      default: throw ScriptingError.failed
      }
    }
    try validate(auth: auth, token: token, delegate: delegate)
    return result
  }

  private func validate(auth: AuthHandle, token: AuthAccountMutationToken, delegate: AppDelegate) throws {
    try Task.checkCancellation()
    guard delegate.scriptingAccountIsReady else { throw ScriptingError.unavailable }
    try auth.validateAccountMutation(token)
  }

  private static var frontWindow: MainWindowController? {
    (NSApp.keyWindow?.windowController as? MainWindowController)
      ?? (NSApp.mainWindow?.windowController as? MainWindowController)
      ?? NSApp.orderedWindows.compactMap { $0.windowController as? MainWindowController }.first
  }

  // A dialog is the local account's relationship, not merely a discovered/cached public chat.
  nonisolated private static let chatSQL = """
    SELECT c.*, coalesce(d.unreadCount, 0) AS scriptingUnreadCount,
      coalesce(d.collapsedMaxId, 0) AS scriptingCollapsedMaxId,
      u.firstName AS scriptingFirstName, u.lastName AS scriptingLastName, u.username AS scriptingUsername
    FROM chat c JOIN dialog d ON coalesce(d.chatId, d.peerThreadId) = c.id LEFT JOIN user u ON u.id = c.peerUserId
    WHERE c.id > 0 AND c.createState IS NULL AND coalesce(d.chatListHidden, 0) = 0
    """

  nonisolated private static func cachedChat(_ db: Database, id: Int64) throws -> Row {
    guard let row = try Row.fetchOne(db, sql: chatSQL + " AND c.id = ?", arguments: [id]) else {
      throw ScriptingError.notFound
    }
    return row
  }

  nonisolated private static func chatRecord(_ row: Row) -> ScriptingValue {
    let id: Int64 = row["id"]
    let spaceID: Int64? = row["spaceId"]
    let kind: String = row["type"]
    let title: String? = row["title"]
    let unread: Int = row["scriptingUnreadCount"]
    let displayTitle = kind == "private"
      ? name(first: row["scriptingFirstName"], last: row["scriptingLastName"], username: row["scriptingUsername"])
      : (title.flatMap { $0.isEmpty ? nil : $0 } ?? "New thread")
    return .record([
      .chatID: .text(String(id)), .title: .text(displayTitle), .kind: .text(kind),
      .spaceID: .text(spaceID.map(String.init) ?? ""), .unreadCount: .integer(Int32(clamping: max(0, unread))),
    ])
  }

  nonisolated private static func name(first: String?, last: String?, username: String?) -> String {
    let name = [first, last].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? (username.flatMap { $0.isEmpty ? nil : $0 } ?? "Inline user") : name
  }
}
