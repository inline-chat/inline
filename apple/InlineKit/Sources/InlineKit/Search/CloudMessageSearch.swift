import Foundation
import GRDB
import InlineProtocol
import Logger

/// A verified hit from the account-wide whole-word search, named from this device's cache.
public struct CloudMessageSearchResult: Sendable, Hashable, Identifiable {
  /// Matches `LocalMessageSearchResult.id`, so one message is listed once.
  public var id: String {
    "message-\(chatId)-\(messageId)"
  }

  public let peer: Peer
  public let chatId: Int64
  public let messageId: Int64
  public let date: Date
  public let fromUserId: Int64
  /// The matched body fragment or attachment filename.
  public let snippet: String
  /// Matched words in `snippet`, in UTF-16 code units.
  public let highlights: [NSRange]
  public let matchedFileName: Bool
  public let chat: Chat?
  public let space: Space?
  public let peerUser: User?
  public let sender: User?
  /// False when this device has never stored the chat; opening it fetches the chat first.
  public let isChatStored: Bool

  /// Who wrote it, in chats with more than one other person.
  public var senderName: String? {
    searchSenderName(peer: peer, fromUserId: fromUserId, sender: sender)
  }

  public var title: String {
    if let peerUser {
      return peerUser.displayName
    }
    return chat?.humanReadableTitle ?? "Chat"
  }

  public var contextTitle: String? {
    space?.displayName
  }
}

public struct CloudMessageSearchPage: Sendable, Hashable {
  public let results: [CloudMessageSearchResult]
  /// Present while the server may have older hits, even after an empty page.
  public let nextCursor: String?
  /// Some eligible history isn't indexed yet, so older matches can be missing.
  public let indexIncomplete: Bool

  public init(results: [CloudMessageSearchResult], nextCursor: String?, indexIncomplete: Bool) {
    self.results = results
    self.nextCursor = nextCursor
    self.indexIncomplete = indexIncomplete
  }
}

public struct CloudMessageSearchScope: Sendable, Hashable {
  public var spaceId: Int64?
  /// Only chats outside spaces.
  public var homeOnly: Bool
  public var includeArchived: Bool

  public init(spaceId: Int64? = nil, homeOnly: Bool = false, includeArchived: Bool = true) {
    self.spaceId = spaceId
    self.homeOnly = homeOnly
    self.includeArchived = includeArchived
  }
}

public enum CloudMessageSearch {
  public static let pageLimit: Int32 = 20
  private static let log = Log.scoped("CloudMessageSearch")

  public static func search(
    query: String,
    scope: CloudMessageSearchScope = CloudMessageSearchScope(),
    cursor: String? = nil,
    db: AppDatabase = .shared,
    rpc: InlineRPCClient = .shared
  ) async throws -> CloudMessageSearchPage {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard LocalMessageSearch.isSearchable(trimmed) else {
      return CloudMessageSearchPage(results: [], nextCursor: nil, indexIncomplete: false)
    }
    let response = try await rpc.searchMessagesGlobal(
      query: trimmed,
      spaceID: scope.spaceId,
      homeOnly: scope.spaceId == nil && scope.homeOnly,
      includeArchived: scope.includeArchived,
      cursor: cursor,
      limit: pageLimit
    )
    try Task.checkCancellation()
    let hits = response.hits.map(Hit.init(proto:))
    var cache = try await cached(db, hits: hits)
    await fetchMissingChats(hits: hits, cache: &cache, rpc: rpc)
    return CloudMessageSearchPage(
      results: hits.map { $0.result(cache: cache) },
      nextCursor: response.hasNextCursor ? response.nextCursor : nil,
      indexIncomplete: response.indexIncomplete
    )
  }

  struct Hit: Sendable {
    let peer: Peer
    let chatId: Int64
    let messageId: Int64
    let date: Date
    let fromUserId: Int64
    let snippet: String
    let highlights: [NSRange]
    let matchedFileName: Bool

    init(proto hit: InlineProtocol.GlobalMessageSearchHit) {
      peer = hit.hasPeer ? hit.peer.toPeer() : .thread(id: hit.chatID)
      chatId = hit.chatID
      messageId = hit.messageID
      date = Date(timeIntervalSince1970: TimeInterval(hit.date))
      fromUserId = hit.fromUserID
      let excerpt = hit.excerpts.first
      snippet = excerpt?.text ?? ""
      let length = (snippet as NSString).length
      highlights = (excerpt?.highlights ?? []).compactMap { range in
        let location = Int(range.offset)
        let size = Int(range.length)
        guard size > 0, location + size <= length else { return nil }
        return NSRange(location: location, length: size)
      }
      matchedFileName = excerpt?.field == .documentFilename
    }

    var peerUserId: Int64? {
      if case let .user(id) = peer { return id }
      return nil
    }

    func result(cache: Cache) -> CloudMessageSearchResult {
      let chat = cache.chats[chatId] ?? cache.fetchedChats[chatId]
      return CloudMessageSearchResult(
        peer: peer,
        chatId: chatId,
        messageId: messageId,
        date: date,
        fromUserId: fromUserId,
        snippet: snippet,
        highlights: highlights,
        matchedFileName: matchedFileName,
        chat: chat,
        space: chat?.spaceId.flatMap { cache.spaces[$0] },
        peerUser: peerUserId.flatMap { cache.users[$0] },
        sender: cache.users[fromUserId],
        isChatStored: cache.chats[chatId] != nil
      )
    }
  }

  struct Cache: Sendable {
    var chats: [Int64: Chat] = [:]
    /// Fetched only to name a hit; never saved.
    var fetchedChats: [Int64: Chat] = [:]
    var users: [Int64: User] = [:]
    var spaces: [Int64: Space] = [:]
  }

  private static func cached(_ appDatabase: AppDatabase, hits: [Hit]) async throws -> Cache {
    guard hits.isEmpty == false else { return Cache() }
    return try await appDatabase.reader.read { db in
      var cache = Cache()
      let chats = try Chat.fetchAll(db, keys: Array(Set(hits.map(\.chatId))))
      cache.chats = Dictionary(chats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      let userIds = Set(hits.compactMap(\.peerUserId) + hits.map(\.fromUserId))
      if userIds.isEmpty == false {
        let users = try User.fetchAll(db, keys: Array(userIds))
        cache.users = Dictionary(users.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      }
      let spaceIds = Set(chats.compactMap(\.spaceId))
      if spaceIds.isEmpty == false {
        let spaces = try Space.fetchAll(db, keys: Array(spaceIds))
        cache.spaces = Dictionary(spaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      }
      return cache
    }
  }

  /// Names hits in chats this device never stored, such as a thread never opened.
  /// Direct calls keep them out of the database, so a result can't add a chat to the sidebar.
  private static func fetchMissingChats(hits: [Hit], cache: inout Cache, rpc: InlineRPCClient) async {
    var missing: [Int64: Peer] = [:]
    for hit in hits {
      let userMissing = hit.peerUserId.map { cache.users[$0] == nil } ?? false
      if cache.chats[hit.chatId] == nil || userMissing {
        missing[hit.chatId] = hit.peer
      }
    }
    guard missing.isEmpty == false else { return }

    // A page has at most 20 hits; most are already stored.
    let fetched = await withTaskGroup(of: (Int64, Chat?, User?).self) { group in
      for (chatId, peer) in missing.sorted(by: { $0.key < $1.key }).prefix(8) {
        group.addTask {
          do {
            let result = try await rpc.getChat(peerID: peer)
            return (
              chatId,
              result.hasChat ? Chat(from: result.chat) : nil,
              result.hasUser ? User(from: result.user) : nil
            )
          } catch {
            log.debug("Couldn't name a search hit's chat: \(error.localizedDescription)")
            return (chatId, nil, nil)
          }
        }
      }
      var values: [(Int64, Chat?, User?)] = []
      for await value in group {
        values.append(value)
      }
      return values
    }
    for (chatId, chat, user) in fetched {
      if let chat, cache.chats[chatId] == nil { cache.fetchedChats[chatId] = chat }
      if let user, cache.users[user.id] == nil { cache.users[user.id] = user }
    }
  }
}
