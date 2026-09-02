import AppIntents
import Auth
import Foundation
import InlineKit
import InlineProtocol
import RealtimeV2

struct InlineIntentMessageID: Equatable, Sendable {
  let chat: InlineIntentChatID
  let messageID: Int64
  var rawValue: String { "m1:\(chat.accountID):\(chat.chatID):\(messageID)" }

  init(chat: InlineIntentChatID, messageID: Int64) {
    self.chat = chat
    self.messageID = messageID
  }

  init?(_ value: String) {
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 4, parts[0] == "m1",
          let chat = InlineIntentChatID("v1:\(parts[1]):\(parts[2])"),
          let messageID = Int64(parts[3]), messageID > 0 else { return nil }
    self.init(chat: chat, messageID: messageID)
  }
}

struct InlineIntentConversation: Sendable {
  let chat: InlineIntentChat
  let dialog: InlineProtocol.Dialog
  let lastActivityDate: Int64
  let previewText: String
  var isUnread: Bool { dialog.unreadCount > 0 || dialog.unreadMark }
}

private struct InlineIntentUnreadCursor {
  let accountID: Int64
  let lastActivityDate: Int64
  let chatID: Int64
  var rawValue: String { "u1:\(accountID):\(lastActivityDate):\(chatID)" }

  init(accountID: Int64, lastActivityDate: Int64, chatID: Int64) {
    self.accountID = accountID
    self.lastActivityDate = lastActivityDate
    self.chatID = chatID
  }

  init?(_ rawValue: String) {
    let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 4, parts[0] == "u1",
          let accountID = Int64(parts[1]), accountID > 0,
          let lastActivityDate = Int64(parts[2]), lastActivityDate >= 0,
          let chatID = Int64(parts[3]), chatID > 0
    else { return nil }
    self.init(accountID: accountID, lastActivityDate: lastActivityDate, chatID: chatID)
  }
}

/// Request-local server projection. It neither owns sync cursors nor writes a second message cache.
struct InlineIntentInbox: Sendable {
  let accountID: Int64
  let conversations: [InlineIntentConversation]
  let users: [Int64: InlineProtocol.User]
  let spaces: [Int64: String]

  init(_ result: GetChatsResult, accountID: Int64) {
    self.accountID = accountID
    users = result.users.reduce(into: [:]) { if $1.id > 0 { $0[$1.id] = $1 } }
    let dialogs = result.dialogs.reduce(into: [Int64: InlineProtocol.Dialog]()) {
      if $1.chatID > 0 { $0[$1.chatID] = $1 }
    }
    spaces = result.spaces.reduce(into: [Int64: String]()) { $0[$1.id] = $1.name }
    let users = self.users
    let spaces = self.spaces
    let lastMessages = result.messages.reduce(into: [Int64: InlineProtocol.Message]()) { values, message in
      guard message.chatID > 0 else { return }
      if let current = values[message.chatID],
         current.date > message.date || (current.date == message.date && current.id >= message.id) {
        return
      }
      values[message.chatID] = message
    }
    let lastDates = lastMessages.mapValues(\.date)
    var seen = Set<Int64>()
    let ordered = result.chats.sorted { lhs, rhs in
      let lhsPinned = dialogs[lhs.id]?.pinned == true
      let rhsPinned = dialogs[rhs.id]?.pinned == true
      if lhsPinned != rhsPinned { return lhsPinned }
      let lhsDate = lastDates[lhs.id] ?? lhs.date
      let rhsDate = lastDates[rhs.id] ?? rhs.date
      return lhsDate == rhsDate ? lhs.id > rhs.id : lhsDate > rhsDate
    }
    conversations = ordered.compactMap { source in
      guard source.id > 0,
            seen.insert(source.id).inserted,
            let dialog = dialogs[source.id]
      else { return nil }
      return Self.makeConversation(
        source: source,
        dialog: dialog,
        accountID: accountID,
        users: users,
        spaces: spaces,
        lastActivityDate: lastDates[source.id] ?? source.date,
        previewText: lastMessages[source.id].map(Self.previewText) ?? ""
      )
    }
  }

  private init(
    accountID: Int64,
    conversations: [InlineIntentConversation],
    users: [Int64: InlineProtocol.User],
    spaces: [Int64: String]
  ) {
    self.accountID = accountID
    self.conversations = conversations
    self.users = users
    self.spaces = spaces
  }

  static func empty(accountID: Int64) -> InlineIntentInbox {
    InlineIntentInbox(accountID: accountID, conversations: [], users: [:], spaces: [:])
  }

  func addingUsers(_ values: [InlineProtocol.User]) -> InlineIntentInbox {
    var merged = users
    for user in values where user.id > 0 { merged[user.id] = user }
    return InlineIntentInbox(
      accountID: accountID,
      conversations: conversations,
      users: merged,
      spaces: spaces
    )
  }

  /// Adds one server-authorized explicit chat without turning its UI placement flags into access rules.
  func addingConversation(_ result: GetChatResult) throws -> InlineIntentInbox {
    guard result.hasChat, result.hasDialog else { throw InlineIntentError.unavailable }
    var mergedUsers = users
    if result.hasUser, result.user.id > 0 { mergedUsers[result.user.id] = result.user }
    guard let value = Self.makeConversation(
      source: result.chat,
      dialog: result.dialog,
      accountID: accountID,
      users: mergedUsers,
      spaces: spaces,
      lastActivityDate: result.chat.date,
      previewText: ""
    ) else { throw InlineIntentError.unavailable }
    var mergedConversations = conversations.filter { $0.chat.id != value.chat.id }
    mergedConversations.append(value)
    return InlineIntentInbox(
      accountID: accountID,
      conversations: mergedConversations,
      users: mergedUsers,
      spaces: spaces
    )
  }

  static func name(_ user: InlineProtocol.User?) -> String {
    guard let user else { return String(localized: "Inline User") }
    let name = [user.firstName, user.lastName].filter { !$0.isEmpty }.joined(separator: " ")
    return name.isEmpty ? (user.username.isEmpty ? String(localized: "Inline User") : user.username) : name
  }

  private static func makeConversation(
    source: InlineProtocol.Chat,
    dialog: InlineProtocol.Dialog,
    accountID: Int64,
    users: [Int64: InlineProtocol.User],
    spaces: [Int64: String],
    lastActivityDate: Int64,
    previewText: String
  ) -> InlineIntentConversation? {
    guard source.id > 0, dialog.chatID == source.id, dialog.peer == source.peerID else { return nil }
    let peer: InlineKit.Peer
    let title: String
    let subtitle: String
    let username: String?
    switch source.peerID.type {
    case let .user(user) where user.userID > 0 && users[user.userID] != nil:
      peer = .user(id: user.userID)
      title = user.userID == accountID ? String(localized: "Saved Messages") : name(users[user.userID])
      let rawUsername = users[user.userID]?.username.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      username = rawUsername.isEmpty ? nil : rawUsername
      subtitle = username.map { "@\($0)" } ?? String(localized: "Direct Message")
    case let .chat(chat) where chat.chatID == source.id:
      peer = .thread(id: chat.chatID)
      let fallbackTitle = source.hasNumber
        ? String(localized: "Thread #\(source.number)")
        : String(localized: "Thread")
      title = source.title.isEmpty ? fallbackTitle : source.title
      let space = spaces[source.spaceID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let threadContext = source.hasNumber
        ? String(localized: "Thread #\(source.number)")
        : String(localized: "Thread")
      subtitle = space.isEmpty ? threadContext : "\(space) · \(threadContext)"
      username = nil
    default:
      return nil
    }
    return InlineIntentConversation(
      chat: .init(
        id: .init(accountID: accountID, chatID: source.id),
        peer: peer,
        title: title,
        subtitle: subtitle,
        username: username
      ),
      dialog: dialog,
      lastActivityDate: lastActivityDate,
      previewText: previewText
    )
  }

  private static func previewText(_ message: InlineProtocol.Message) -> String {
    if !message.message.isEmpty { return message.message }
    return message.hasMedia || message.hasAttachments ? String(localized: "Attachment") : ""
  }

  func conversation(_ id: String) throws -> InlineIntentConversation {
    guard let parsed = InlineIntentChatID(id), parsed.accountID == accountID,
          let conversation = conversations.first(where: { $0.chat.id == parsed }) else {
      throw InlineIntentError.unavailable
    }
    return conversation
  }

  func unreadPage(after: String?) throws -> InlineIntentConversationPage {
    // Match the app's All Chats unread projection. `open` is Inbox placement only.
    let unread = conversations.filter {
      $0.isUnread && !$0.dialog.archived && !$0.dialog.chatListHidden
    }.sorted {
      $0.lastActivityDate == $1.lastActivityDate
        ? $0.chat.id.chatID > $1.chat.id.chatID
        : $0.lastActivityDate > $1.lastActivityDate
    }
    let remaining: [InlineIntentConversation]
    if let after {
      guard let cursor = InlineIntentUnreadCursor(after), cursor.accountID == accountID else {
        throw InlineIntentError.unavailable
      }
      remaining = unread.filter {
        $0.lastActivityDate < cursor.lastActivityDate
          || ($0.lastActivityDate == cursor.lastActivityDate && $0.chat.id.chatID < cursor.chatID)
      }
    } else {
      remaining = unread
    }
    let page = Array(remaining.prefix(InlineIntentMessaging.batchLimit))
    return .init(conversations: page, totalCount: unread.count,
                 nextCursor: remaining.count > page.count ? page.last.map {
                   InlineIntentUnreadCursor(
                     accountID: accountID,
                     lastActivityDate: $0.lastActivityDate,
                     chatID: $0.chat.id.chatID
                   ).rawValue
                 } : nil)
  }
}

struct InlineIntentMessage: Sendable {
  let id: InlineIntentMessageID
  let conversation: InlineIntentConversation
  let source: InlineProtocol.Message
  let author: String
  let authorUsername: String?
  let isRead: Bool

  init(_ message: InlineProtocol.Message, conversation: InlineIntentConversation, inbox: InlineIntentInbox) throws {
    guard message.id > 0, message.chatID == conversation.chat.id.chatID,
          message.id > conversation.dialog.collapsedMaxID else { throw InlineIntentError.unavailable }
    id = .init(chat: conversation.chat.id, messageID: message.id)
    self.conversation = conversation
    source = message
    author = message.fromID == inbox.accountID ? String(localized: "You")
      : inbox.users[message.fromID].map { InlineIntentInbox.name($0) }
      ?? String(localized: "Unknown Sender")
    let username = inbox.users[message.fromID]?.username.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    authorUsername = username.isEmpty ? nil : username
    // GetChats exposes our inbox cursor, not other recipients' receipts. Never invent an outgoing receipt.
    isRead = (!message.out || conversation.chat.peer == .user(id: inbox.accountID)) && message.id <= conversation.dialog.readMaxID
  }

  var text: String {
    if !source.message.isEmpty { return source.message }
    return source.hasMedia || source.hasAttachments ? String(localized: "Attachment") : ""
  }
}

enum InlineIntentMessaging {
  static let batchLimit = 20

  static func connected<Value: Sendable>(
    account: AuthAccountMutationToken,
    mutation: Bool = false,
    _ operation: @escaping @Sendable (RealtimeV2) async throws -> Value
  ) async throws -> Value {
    try InlineIntentService.validate(account)
    do {
      return try await Api.realtime.withUserInitiatedConnection(accountToken: account, operation: operation)
    } catch is CancellationError {
      if mutation { throw InlineIntentError.operationNotConfirmed }
      throw CancellationError()
    } catch let error as InlineIntentError {
      throw error
    } catch {
      try InlineIntentService.validate(account)
      // The deadline may race with a committed mutation. Never invite an automatic retry.
      throw mutation ? InlineIntentError.operationNotConfirmed : InlineIntentError.connectionUnavailable
    }
  }

  static func inbox(on realtime: RealtimeV2, account: AuthAccountMutationToken) async throws -> InlineIntentInbox {
    let result = try await realtime.callRpcDirect(method: .getChats, input: .getChats(.init()),
                                                 timeout: .seconds(10), accountToken: account)
    try InlineIntentService.validate(account)
    guard case let .getChats(value)? = result else { throw InlineIntentError.unavailable }
    return InlineIntentInbox(value, accountID: account.userID)
  }

  static func searchUsers(
    matching search: String,
    on realtime: RealtimeV2,
    account: AuthAccountMutationToken
  ) async throws -> [InlineProtocol.User] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(
      of: "^@",
      with: "",
      options: .regularExpression
    )
    guard query.count >= 2 else { return [] }
    let result = try await realtime.callRpcDirect(
      method: .searchUsers,
      input: .searchUsers(.with { $0.query = query; $0.limit = Int32(batchLimit) }),
      timeout: .seconds(10),
      accountToken: account
    )
    try InlineIntentService.validate(account)
    guard case let .searchUsers(value)? = result else { throw InlineIntentError.unavailable }
    return Array(value.users.prefix(batchLimit))
  }

  static func currentUser(on realtime: RealtimeV2, account: AuthAccountMutationToken) async throws -> InlineProtocol.User {
    let result = try await realtime.callRpcDirect(
      method: .getMe, input: .getMe(.init()), timeout: .seconds(10), accountToken: account
    )
    try InlineIntentService.validate(account)
    guard case let .getMe(value)? = result, value.hasUser, value.user.id == account.userID else {
      throw InlineIntentError.unavailable
    }
    return value.user
  }

  static func users(ids: [Int64], on realtime: RealtimeV2, account: AuthAccountMutationToken) async throws -> [InlineProtocol.User] {
    guard ids.count <= 50 else { throw InlineIntentError.tooManyMessages }
    guard !ids.isEmpty else { return [] }
    let result = try await realtime.callRpcDirect(
      method: .getUsers, input: .getUsers(.with { $0.userIds = ids }), timeout: .seconds(10), accountToken: account
    )
    try InlineIntentService.validate(account)
    guard case let .getUsers(value)? = result, value.users.count <= 50 else { throw InlineIntentError.unavailable }
    let requested = Set(ids)
    return value.users.filter { requested.contains($0.id) }
  }

  static func conversations(unreadOnly: Bool = false) async throws -> [InlineIntentConversation] {
    let account = try await InlineIntentService.account()
    return try await connected(account: account) { realtime in
      let snapshot = try await inbox(on: realtime, account: account)
      return Array(snapshot.conversations.filter {
        !$0.dialog.archived && !$0.dialog.chatListHidden && (!unreadOnly || $0.isUnread)
      }.prefix(batchLimit))
    }
  }

  static func conversations(identifiers: [String]) async throws -> [InlineIntentConversation] {
    guard identifiers.count <= 50 else { throw InlineIntentError.tooManyMessages }
    let account = try await InlineIntentService.account()
    let parsed = identifiers.compactMap(InlineIntentChatID.init).filter { $0.accountID == account.userID }
    return try await connected(account: account) { realtime in
      var snapshot = try await inbox(on: realtime, account: account)
      let existing = Set(snapshot.conversations.map { $0.chat.id.chatID })
      let missing = Set(parsed.map(\.chatID)).subtracting(existing)
      guard missing.count <= 8 else { throw InlineIntentError.tooManyConversations }
      var values: [InlineIntentConversation] = []
      for identifier in parsed.map(\.rawValue) {
        do {
          let resolution = try await conversation(
            identifier,
            on: realtime,
            inbox: snapshot,
            account: account
          )
          snapshot = resolution.inbox
          values.append(resolution.conversation)
        } catch let error as RealtimeDirectRpcError where error.isUnavailableEntity {
          continue
        }
      }
      return values
    }
  }

  static func unreadConversations(after: String?) async throws -> InlineIntentConversationPage {
    let account = try await InlineIntentService.account()
    return try await connected(account: account) { realtime in
      try await inbox(on: realtime, account: account).unreadPage(after: after)
    }
  }

  static func messages(chatID: String, unreadOnly: Bool, after: String? = nil) async throws -> InlineIntentMessagePage {
    let account = try await InlineIntentService.account()
    return try await connected(account: account) { realtime in
      let snapshot = try await inbox(on: realtime, account: account)
      let resolution = try await conversation(chatID, on: realtime, inbox: snapshot, account: account)
      let conversation = resolution.conversation
      var afterID = max(conversation.dialog.collapsedMaxID, unreadOnly ? conversation.dialog.readMaxID : 0)
      if let after {
        guard let cursor = InlineIntentMessageID(after), cursor.chat == conversation.chat.id else {
          throw InlineIntentError.unavailable
        }
        afterID = max(afterID, cursor.messageID)
      }
      let result = try await realtime.callRpcDirect(method: .getChatHistory, input: .getChatHistory(.with {
        $0.peerID = conversation.chat.peer.toInputPeer()
        $0.limit = Int32(batchLimit)
        $0.mode = unreadOnly || after != nil ? .historyModeNewer : .historyModeLatest
        if unreadOnly || after != nil { $0.afterID = afterID }
      }), timeout: .seconds(10), accountToken: account)
      try InlineIntentService.validate(account)
      guard case let .getChatHistory(value)? = result else { throw InlineIntentError.unavailable }
      let authorSnapshot = try await addingAuthors(
        for: value.messages, conversation: conversation, to: resolution.inbox, on: realtime, account: account
      )
      return try page(value.messages, conversation: conversation, inbox: authorSnapshot, unreadOnly: unreadOnly,
                      afterID: afterID, newer: unreadOnly || after != nil)
    }
  }

  static func page(_ fetched: [InlineProtocol.Message], conversation: InlineIntentConversation,
                   inbox: InlineIntentInbox, unreadOnly: Bool, afterID: Int64, newer: Bool) throws -> InlineIntentMessagePage {
    guard fetched.count <= batchLimit,
          fetched.allSatisfy({ $0.chatID == conversation.chat.id.chatID && $0.id > 0 && (!newer || $0.id > afterID) }) else {
      throw InlineIntentError.unavailable
    }
    let rows = try fetched.filter {
      $0.id > conversation.dialog.collapsedMaxID && (!unreadOnly || !$0.out)
    }.sorted { $0.id < $1.id }.map {
      try InlineIntentMessage($0, conversation: conversation, inbox: inbox)
    }
    // Advance even over outgoing-only pages. A stale/nonadvancing page must fail instead of looping.
    let last = fetched.map(\.id).max()
    let next = newer && fetched.count == batchLimit
      ? last.map { InlineIntentMessageID(chat: conversation.chat.id, messageID: $0).rawValue } : nil
    return InlineIntentMessagePage(messages: rows, nextCursor: next)
  }

  static func resolve(_ identifiers: [String]) async throws -> [InlineIntentMessage] {
    guard identifiers.count <= 50 else { throw InlineIntentError.tooManyMessages }
    let account = try await InlineIntentService.account()
    let ids = identifiers.compactMap(InlineIntentMessageID.init).filter { $0.chat.accountID == account.userID }
    if ids.isEmpty { return [] }
    return try await connected(account: account) { realtime in
      let snapshot = try await inbox(on: realtime, account: account)
      return try await resolve(ids.map(\.rawValue), on: realtime, inbox: snapshot, account: account)
    }
  }

  private static func resolve(
    _ identifiers: [String],
    on realtime: RealtimeV2,
    inbox snapshot: InlineIntentInbox,
    account: AuthAccountMutationToken
  ) async throws -> [InlineIntentMessage] {
    let ids = identifiers.compactMap(InlineIntentMessageID.init).filter { $0.chat.accountID == account.userID }
    let grouped = Dictionary(grouping: ids, by: { $0.chat.rawValue })
    guard grouped.count <= 8 else { throw InlineIntentError.tooManyConversations }
    let messages = try await withThrowingTaskGroup(of: [InlineIntentMessage].self) { group in
      for (chatID, requestedIDs) in grouped {
        group.addTask {
          let resolution: ConversationResolution
          do {
            resolution = try await conversation(chatID, on: realtime, inbox: snapshot, account: account)
          } catch let error as RealtimeDirectRpcError where error.isUnavailableEntity {
            return []
          }
          let conversation = resolution.conversation
          let requested = Set(requestedIDs.map(\.messageID))
          let result = try await realtime.callRpcDirect(method: .getMessages, input: .getMessages(.with {
            $0.peerID = conversation.chat.peer.toInputPeer()
            $0.messageIds = Array(requested)
          }), timeout: .seconds(10), accountToken: account)
          try InlineIntentService.validate(account)
          guard case let .getMessages(value)? = result else { throw InlineIntentError.unavailable }
          let authorSnapshot = try await addingAuthors(
            for: value.messages, conversation: conversation, to: resolution.inbox, on: realtime, account: account
          )
          return try value.messages.compactMap { source in
            guard requested.contains(source.id), source.id > conversation.dialog.collapsedMaxID else { return nil }
            return try InlineIntentMessage(source, conversation: conversation, inbox: authorSnapshot)
          }
        }
      }
      var values: [InlineIntentMessage] = []
      for try await value in group { values += value }
      return values
    }
    var firstPosition: [String: Int] = [:]
    for (index, id) in ids.enumerated() where firstPosition[id.rawValue] == nil {
      firstPosition[id.rawValue] = index
    }
    return messages.sorted { firstPosition[$0.id.rawValue, default: .max] < firstPosition[$1.id.rawValue, default: .max] }
  }

  private static func addingAuthors(
    for messages: [InlineProtocol.Message],
    conversation: InlineIntentConversation,
    to snapshot: InlineIntentInbox,
    on realtime: RealtimeV2,
    account: AuthAccountMutationToken
  ) async throws -> InlineIntentInbox {
    guard conversation.chat.peer.asUserId() == nil else { return snapshot }
    let missing = Set(messages.map(\.fromID).filter { $0 > 0 })
      .subtracting(snapshot.users.keys).subtracting([account.userID])
    guard !missing.isEmpty else { return snapshot }
    // Historical and inherited-thread authors need not be current participants. Resolve only
    // the public profiles named by these already-authorized messages, without fetching a roster.
    let profiles = try await users(ids: Array(missing), on: realtime, account: account)
    return snapshot.addingUsers(profiles)
  }

  struct ConversationResolution: Sendable {
    let conversation: InlineIntentConversation
    let inbox: InlineIntentInbox
  }

  /// `getChats` is a catalog projection. Explicit stable IDs fall back to `getChat`, whose
  /// server access guard supports closed, archived, hidden, inherited, and group-granted chats.
  static func conversation(
    _ identifier: String,
    on realtime: RealtimeV2,
    inbox snapshot: InlineIntentInbox,
    account: AuthAccountMutationToken
  ) async throws -> ConversationResolution {
    guard let parsed = InlineIntentChatID(identifier), parsed.accountID == account.userID else {
      throw InlineIntentError.unavailable
    }
    if let existing = try? snapshot.conversation(identifier) {
      return ConversationResolution(conversation: existing, inbox: snapshot)
    }
    return try await authorizedConversation(identifier, on: realtime, inbox: snapshot, account: account)
  }

  /// Resolves through the server even when a suggestion snapshot contains the chat. Use this
  /// immediately before UI navigation or other work whose visible target must reflect current access.
  static func authorizedConversation(
    _ identifier: String,
    on realtime: RealtimeV2,
    inbox snapshot: InlineIntentInbox,
    account: AuthAccountMutationToken
  ) async throws -> ConversationResolution {
    guard let parsed = InlineIntentChatID(identifier), parsed.accountID == account.userID else {
      throw InlineIntentError.unavailable
    }
    let result = try await realtime.callRpcDirect(
      method: .getChat,
      input: .getChat(.with { $0.peerID = InlineKit.Peer.thread(id: parsed.chatID).toInputPeer() }),
      timeout: .seconds(10),
      accountToken: account
    )
    try InlineIntentService.validate(account)
    guard case let .getChat(value)? = result else { throw InlineIntentError.unavailable }
    let resolved = try snapshot.addingConversation(value)
    return ConversationResolution(
      conversation: try resolved.conversation(identifier),
      inbox: resolved
    )
  }

  /// Resolves or creates the ordinary DM through the app's existing server contract. This avoids
  /// treating a dialog's list placement as a recipient-access rule.
  static func directConversation(
    userID: Int64,
    on realtime: RealtimeV2,
    inbox snapshot: InlineIntentInbox,
    account: AuthAccountMutationToken
  ) async throws -> ConversationResolution {
    guard userID > 0 else { throw InlineIntentError.unavailable }
    let result = try await realtime.callRpcDirect(
      method: .getChat,
      input: .getChat(.with { $0.peerID = InlineKit.Peer.user(id: userID).toInputPeer() }),
      timeout: .seconds(10),
      accountToken: account
    )
    try InlineIntentService.validate(account)
    guard case let .getChat(value)? = result else { throw InlineIntentError.unavailable }
    let resolved = try snapshot.addingConversation(value)
    guard let conversation = resolved.conversations.first(where: { $0.chat.peer == .user(id: userID) }) else {
      throw InlineIntentError.unavailable
    }
    return ConversationResolution(conversation: conversation, inbox: resolved)
  }

  static func send(text: String, chatID: String, replyingTo: String? = nil, account: AuthAccountMutationToken) async throws -> [InlineIntentMessage] {
    try InlineIntentService.validateMessage(text)
    return try await connected(account: account, mutation: true) { realtime in
      let snapshot = try await inbox(on: realtime, account: account)
      let resolution = try await conversation(chatID, on: realtime, inbox: snapshot, account: account)
      return try await send(
        text: text,
        replyingTo: replyingTo,
        resolution: resolution,
        on: realtime,
        account: account
      )
    }
  }

  static func send(
    text: String,
    userID: Int64,
    account: AuthAccountMutationToken
  ) async throws -> [InlineIntentMessage] {
    try InlineIntentService.validateMessage(text)
    return try await connected(account: account, mutation: true) { realtime in
      let snapshot = try await inbox(on: realtime, account: account)
      let resolution = try await directConversation(
        userID: userID,
        on: realtime,
        inbox: snapshot,
        account: account
      )
      return try await send(
        text: text,
        replyingTo: nil,
        resolution: resolution,
        on: realtime,
        account: account
      )
    }
  }

  private static func send(
    text: String,
    replyingTo: String?,
    resolution: ConversationResolution,
    on realtime: RealtimeV2,
    account: AuthAccountMutationToken
  ) async throws -> [InlineIntentMessage] {
    let conversation = resolution.conversation
    let reply = try replyID(replyingTo, in: conversation.chat.id)
    if let reply {
      let result = try await realtime.callRpcDirect(method: .getMessages, input: .getMessages(.with {
        $0.peerID = conversation.chat.peer.toInputPeer(); $0.messageIds = [reply]
      }), timeout: .seconds(10), accountToken: account)
      guard case let .getMessages(value)? = result,
            value.messages.contains(where: {
              $0.id == reply && $0.chatID == conversation.chat.id.chatID &&
                $0.id > conversation.dialog.collapsedMaxID
            })
      else {
        throw InlineIntentError.unavailable
      }
    }
    let result: RpcResult.OneOf_Result?
    do {
      result = try await realtime.callRpcDirect(method: .sendMessage, input: .sendMessage(.with {
        $0.peerID = conversation.chat.peer.toInputPeer()
        $0.message = text
        $0.randomID = Int64.random(in: 1 ... Int64.max)
        if let reply { $0.replyToMsgID = reply }
      }), timeout: .seconds(10), accountToken: account)
    } catch is CancellationError { throw InlineIntentError.sendNotConfirmed }
    catch { throw InlineIntentError.sendNotConfirmed }
    try InlineIntentService.validate(account)
    guard case let .sendMessage(sent)? = result else { throw InlineIntentError.sendNotConfirmed }
    try await realtime.applyUpdatesAndWait(sent.updates, accountToken: account)
    let messages = sent.updates.compactMap { update -> InlineProtocol.Message? in
      if case let .newMessage(value) = update.update { return value.message }
      return nil
    }
    guard !messages.isEmpty else { throw InlineIntentError.sendNotConfirmed }
    let authorSnapshot = try await addingAuthors(
      for: messages,
      conversation: conversation,
      to: resolution.inbox,
      on: realtime,
      account: account
    )
    return try messages.map { try InlineIntentMessage($0, conversation: conversation, inbox: authorSnapshot) }
  }

  static func replyID(_ identifier: String?, in chat: InlineIntentChatID) throws -> Int64? {
    guard let identifier else { return nil }
    guard let id = InlineIntentMessageID(identifier), id.chat == chat else { throw InlineIntentError.unavailable }
    return id.messageID
  }

  enum Mutation: Sendable { case edit(String), unsend, read, unread }

  static func ownedMessage(_ id: String, account: AuthAccountMutationToken) async throws -> InlineIntentMessage {
    try InlineIntentService.validate(account)
    guard let message = try await resolve([id]).first else { throw InlineIntentError.unavailable }
    try InlineIntentService.validate(account)
    guard message.source.fromID == account.userID else { throw InlineIntentError.ownMessagesOnly }
    return message
  }

  static func mutate(_ id: String, operation: Mutation, account: AuthAccountMutationToken) async throws {
    try InlineIntentService.validate(account)
    guard let message = try await resolve([id]).first else { throw InlineIntentError.unavailable }
    try InlineIntentService.validate(account)
    let peer = message.conversation.chat.peer.toInputPeer()
    let method: InlineProtocol.Method
    let input: RpcCall.OneOf_Input
    switch operation {
    case let .edit(text):
      guard message.source.fromID == account.userID else { throw InlineIntentError.ownMessagesOnly }
      method = .editMessage
      input = .editMessage(.with { $0.peerID = peer; $0.messageID = message.id.messageID; $0.text = text })
    case .unsend:
      guard message.source.fromID == account.userID else { throw InlineIntentError.ownMessagesOnly }
      method = .deleteMessages
      input = .deleteMessages(.with { $0.peerID = peer; $0.messageIds = [message.id.messageID] })
    case .read:
      guard !message.source.out || message.conversation.chat.peer == .user(id: account.userID) else {
        throw InlineIntentError.outgoingReadStatusUnsupported
      }
      method = .readMessages
      input = .readMessages(.with { $0.peerID = peer; $0.maxID = message.id.messageID })
    case .unread:
      // Inline's unread action is a conversation reminder. Read receipts remain monotonic.
      method = .markAsUnread
      input = .markAsUnread(.with { $0.peerID = peer })
    }
    try await connected(account: account, mutation: true) { realtime in
      let result: RpcResult.OneOf_Result?
      do {
        result = try await realtime.callRpcDirect(
          method: method, input: input, timeout: .seconds(10), accountToken: account
        )
      } catch {
        throw InlineIntentError.operationNotConfirmed
      }
      try InlineIntentService.validate(account)
      let updates: [InlineProtocol.Update]
      switch (operation, result) {
      case let (.edit, .editMessage(value)?): updates = value.updates
      case let (.unsend, .deleteMessages(value)?): updates = value.updates
      case let (.read, .readMessages(value)?): updates = value.updates
      case let (.unread, .markAsUnread(value)?): updates = value.updates
      default: throw InlineIntentError.operationNotConfirmed
      }
      do {
        try await realtime.applyUpdatesAndWait(updates, accountToken: account)
      } catch {
        throw InlineIntentError.operationNotConfirmed
      }
    }
  }
}

struct InlineIntentMessagePage: Sendable {
  let messages: [InlineIntentMessage]
  let nextCursor: String?
}

struct InlineIntentConversationPage: Sendable {
  let conversations: [InlineIntentConversation]
  let totalCount: Int
  let nextCursor: String?
}

public struct InlineUnreadChatPage: TransientAppEntity {
  public init() {}
  public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Unread Inline Chats")
  @Property(title: "Chats") public var chats: [InlineChatEntity]
  @Property(title: "Total Unread Chats") public var totalCount: Int
  @Property(title: "Next Cursor") public var nextCursor: String?
  public var displayRepresentation: DisplayRepresentation { .init(title: "\(totalCount) unread chats") }
  init(_ page: InlineIntentConversationPage) {
    chats = page.conversations.map(InlineChatEntity.init)
    totalCount = page.totalCount
    nextCursor = page.nextCursor
  }
}

public struct InlineMessagePage: TransientAppEntity {
  public init() {}
  public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Inline Message Page")
  @Property(title: "Messages") public var messages: [InlineMessageEntity]
  @Property(title: "Next Cursor") public var nextCursor: String?
  @Property(title: "More May Be Available") public var hasMore: Bool
  public var displayRepresentation: DisplayRepresentation { .init(title: "\(messages.count) messages") }
  init(_ page: InlineIntentMessagePage) {
    messages = page.messages.map(InlineMessageEntity.init)
    nextCursor = page.nextCursor
    hasMore = page.nextCursor != nil
  }
}

public struct InlineMessageEntity: AppEntity {
  public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Inline Message")
  public static let defaultQuery = InlineMessageQuery()
  public let id: String
  @Property(title: "Chat") public var chat: InlineChatEntity
  @Property(title: "Author") public var author: String
  @Property(title: "Text") public var text: String
  @Property(title: "Date") public var date: Date
  @Property(title: "Read") public var isRead: Bool
  @Property(title: "Has Attachments") public var hasAttachments: Bool
  public var displayRepresentation: DisplayRepresentation {
    .init(title: "\(author): \(text)", subtitle: "\(chat.name)")
  }
  init(_ value: InlineIntentMessage) {
    id = value.id.rawValue
    chat = InlineChatEntity(value.conversation.chat)
    author = value.author
    text = value.text
    date = Date(timeIntervalSince1970: TimeInterval(value.source.date))
    isRead = value.isRead
    hasAttachments = value.source.hasMedia || value.source.hasAttachments
  }
}

public struct InlineMessageQuery: EntityQuery {
  #if compiler(>=6.4)
  @available(iOS 27.0, macOS 27.0, *)
  public static var allowedExecutionTargets: IntentExecutionTargets { .main }
  #endif
  public init() {}
  public func entities(for identifiers: [String]) async throws -> [InlineMessageEntity] {
    try await InlineIntentMessaging.resolve(identifiers).map(InlineMessageEntity.init)
  }
}

extension RealtimeDirectRpcError {
  var isUnavailableEntity: Bool {
    switch self {
    case let .rpcError(errorCode, _, _):
      errorCode == .chatIDInvalid || errorCode == .peerIDInvalid
    default:
      false
    }
  }
}
