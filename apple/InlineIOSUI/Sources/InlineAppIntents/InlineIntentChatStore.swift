import Foundation
import InlineKit

/// These identifiers are persisted by Shortcuts. Keep the version and namespaces stable.
struct InlineIntentChatID: Equatable, Sendable {
  let accountID: Int64
  let chatID: Int64

  var rawValue: String { "v1:\(accountID):\(chatID)" }

  init(accountID: Int64, chatID: Int64) {
    self.accountID = accountID
    self.chatID = chatID
  }

  init?(_ rawValue: String) {
    let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "v1",
          let accountID = Int64(parts[1]), accountID > 0,
          let chatID = Int64(parts[2]), chatID > 0
    else { return nil }
    self.init(accountID: accountID, chatID: chatID)
  }
}

struct InlineIntentChat: Sendable {
  let id: InlineIntentChatID
  let peer: Peer
  let title: String
  let subtitle: String
  let username: String?

  init(id: InlineIntentChatID, peer: Peer, title: String, subtitle: String, username: String? = nil) {
    self.id = id
    self.peer = peer
    self.title = title
    self.subtitle = subtitle
    self.username = username
  }
}

/// Pure, request-local projection of the server inbox; never opens or queries SQLite.
enum InlineIntentChatStore {
  static let resultLimit = 20

  static func fetch(in inbox: InlineIntentInbox, chatIDs: [Int64]? = nil, search: String = "", directMessagesOnly: Bool = false) -> [InlineIntentChat] {
    if let chatIDs {
      let byID = Dictionary(uniqueKeysWithValues: inbox.conversations.map { ($0.chat.id.chatID, $0.chat) })
      return chatIDs.prefix(50).compactMap { byID[$0] }
    }
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    let usernameQuery = query.hasPrefix("@") ? String(query.dropFirst()) : query
    return inbox.conversations.filter { conversation in
      if directMessagesOnly && conversation.chat.peer.asUserId() == nil { return false }
      // Mirror the ordinary All Chats/search projection. Explicit identifier resolution uses
      // the separate server-authorized path and may still return archived or hidden chats.
      guard !conversation.dialog.archived, !conversation.dialog.chatListHidden else { return false }
      if query.isEmpty { return true }
      let username = conversation.chat.peer.asUserId().flatMap { inbox.users[$0]?.username } ?? ""
      return conversation.chat.title.localizedCaseInsensitiveContains(query)
        || (!usernameQuery.isEmpty && username.localizedCaseInsensitiveContains(usernameQuery))
    }.prefix(resultLimit).map(\.chat)
  }
}
