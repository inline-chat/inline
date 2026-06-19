import Combine
import Foundation
import GRDB
import Logger

public enum LocalMessageSearchSort: Sendable, Hashable {
  case relevance
  case newest
}

public struct LocalMessageSearchOptions: Sendable, Hashable {
  public var peer: Peer?
  public var spaceId: Int64?
  public var limit: Int
  public var offset: Int
  public var includeArchived: Bool
  public var matchPrefixes: Bool
  public var sort: LocalMessageSearchSort

  public init(
    peer: Peer? = nil,
    spaceId: Int64? = nil,
    limit: Int = 20,
    offset: Int = 0,
    includeArchived: Bool = true,
    matchPrefixes: Bool = true,
    sort: LocalMessageSearchSort = .relevance
  ) {
    self.peer = peer
    self.spaceId = spaceId
    self.limit = limit
    self.offset = offset
    self.includeArchived = includeArchived
    self.matchPrefixes = matchPrefixes
    self.sort = sort
  }
}

public struct LocalMessageSearchResult: Sendable, Hashable, Identifiable {
  public var id: String {
    "message-\(message.message.chatId)-\(message.message.messageId)"
  }

  public let message: FullMessage
  public let peer: Peer
  public let chat: Chat?
  public let space: Space?
  public let peerUser: User?
  public let snippet: String
  public let rank: Double?

  public var messageId: Int64 {
    message.message.messageId
  }

  public var chatId: Int64 {
    message.message.chatId
  }

  public var title: String {
    if let peerUser {
      return peerUser.isCurrentUser() ? "Saved Messages" : peerUser.displayName
    }
    return chat?.humanReadableTitle ?? "Chat"
  }

  public var contextTitle: String? {
    space?.displayName
  }
}

public enum LocalMessageSearch {
  public static let defaultLimit = 20
  public static let maxLimit = 50

  private static let tableName = "messageTextFts"
  fileprivate static let log = Log.scoped("LocalMessageSearch")

  public static func search(
    db appDatabase: AppDatabase,
    query: String,
    options: LocalMessageSearchOptions = LocalMessageSearchOptions()
  ) async throws -> [LocalMessageSearchResult] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isSearchable(trimmedQuery) else { return [] }

    let limit = max(1, min(options.limit, maxLimit))
    let offset = max(0, options.offset)

    return try await appDatabase.reader.read { db in
      let pattern: FTS5Pattern?
      if options.matchPrefixes {
        pattern = FTS5Pattern(matchingAllPrefixesIn: trimmedQuery)
      } else {
        pattern = FTS5Pattern(matchingAllTokensIn: trimmedQuery)
      }
      guard let pattern else { return [] }

      let matches = try fetchMatches(
        db,
        pattern: pattern,
        options: options,
        limit: limit,
        offset: offset
      )
      guard !matches.isEmpty else { return [] }

      return try hydrateResults(db, matches: matches, query: trimmedQuery)
    }
  }

  public static func isSearchable(_ query: String) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return false }
    let tokenCharCount = trimmed.unicodeScalars.reduce(into: 0) { count, scalar in
      if CharacterSet.alphanumerics.contains(scalar) {
        count += 1
      }
    }
    return tokenCharCount >= 2
  }

  static func snippet(text: String?, query: String, radius: Int = 70) -> String {
    let normalized = normalizeWhitespace(text ?? "")
    guard normalized.isEmpty == false else { return "" }

    let tokens = query
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
      .filter { isSearchable($0) }

    let matchRange = tokens.lazy.compactMap { token in
      normalized.range(
        of: token,
        options: [.caseInsensitive, .diacriticInsensitive]
      )
    }.first

    guard let matchRange else {
      return clipped(normalized, radius: radius * 2)
    }

    let lower = normalized.index(
      matchRange.lowerBound,
      offsetBy: -radius,
      limitedBy: normalized.startIndex
    ) ?? normalized.startIndex
    let upper = normalized.index(
      matchRange.upperBound,
      offsetBy: radius,
      limitedBy: normalized.endIndex
    ) ?? normalized.endIndex

    let prefix = lower == normalized.startIndex ? "" : "..."
    let suffix = upper == normalized.endIndex ? "" : "..."
    return prefix + String(normalized[lower ..< upper]) + suffix
  }

  private static func fetchMatches(
    _ db: Database,
    pattern: FTS5Pattern,
    options: LocalMessageSearchOptions,
    limit: Int,
    offset: Int
  ) throws -> [Match] {
    var filters = ["\(tableName) MATCH ?"]
    var arguments = StatementArguments([pattern])

    if let peer = options.peer {
      switch peer {
      case let .thread(id):
        filters.append("message.peerThreadId = ?")
        arguments += StatementArguments([id])
      case let .user(id):
        filters.append("message.peerUserId = ?")
        arguments += StatementArguments([id])
      }
    }

    if let spaceId = options.spaceId {
      filters.append("COALESCE(dialog.spaceId, chat.spaceId) = ?")
      arguments += StatementArguments([spaceId])
    }

    if options.includeArchived == false {
      filters.append("(dialog.archived IS NULL OR dialog.archived = 0)")
    }

    arguments += StatementArguments([limit, offset])

    let orderSQL = switch options.sort {
      case .relevance:
        "rank, message.date DESC, message.messageId DESC"
      case .newest:
        "message.date DESC, message.messageId DESC, rank"
    }

    let sql = """
      SELECT message.chatId, message.messageId, rank
      FROM \(tableName)
      JOIN message ON message.globalId = \(tableName).rowid
      LEFT JOIN chat ON chat.id = message.chatId
      LEFT JOIN dialog ON dialog.id = CASE
        WHEN message.peerUserId IS NOT NULL THEN message.peerUserId
        WHEN message.peerThreadId < 500 THEN message.peerThreadId
        ELSE -message.peerThreadId
      END
      WHERE \(filters.joined(separator: " AND "))
      ORDER BY \(orderSQL)
      LIMIT ? OFFSET ?
      """

    return try Match.fetchAll(db, sql: sql, arguments: arguments)
  }

  private static func hydrateResults(
    _ db: Database,
    matches: [Match],
    query: String
  ) throws -> [LocalMessageSearchResult] {
    var fullMessages: [FullMessage] = []
    fullMessages.reserveCapacity(matches.count)

    for match in matches {
      guard let message = try FullMessage.queryRequest()
        .filter(Message.Columns.chatId == match.chatId)
        .filter(Message.Columns.messageId == match.messageId)
        .fetchOne(db)
      else {
        continue
      }
      fullMessages.append(message)
    }

    let chats = try fetchChats(db, fullMessages: fullMessages)
    let spaces = try fetchSpaces(db, chats: Array(chats.values))
    let users = try fetchPeerUsers(db, fullMessages: fullMessages)
    let rankByKey = Dictionary(uniqueKeysWithValues: matches.map { ($0.key, $0.rank) })

    return fullMessages.map { fullMessage in
      let message = fullMessage.message
      let chat = chats[message.chatId]
      let space = chat?.spaceId.flatMap { spaces[$0] }
      let peerUser = message.peerUserId.flatMap { users[$0] }
      let key = Match.Key(chatId: message.chatId, messageId: message.messageId)
      let rank = rankByKey[key] ?? nil

      return LocalMessageSearchResult(
        message: fullMessage,
        peer: message.peerId,
        chat: chat,
        space: space,
        peerUser: peerUser,
        snippet: snippet(text: message.text, query: query),
        rank: rank
      )
    }
  }

  private static func fetchChats(_ db: Database, fullMessages: [FullMessage]) throws -> [Int64: Chat] {
    let chatIds = Set(fullMessages.map(\.message.chatId))
    guard !chatIds.isEmpty else { return [:] }
    let chats = try Chat.fetchAll(db, keys: Array(chatIds))
    return Dictionary(uniqueKeysWithValues: chats.map { ($0.id, $0) })
  }

  private static func fetchSpaces(_ db: Database, chats: [Chat]) throws -> [Int64: Space] {
    let spaceIds = Set(chats.compactMap(\.spaceId))
    guard !spaceIds.isEmpty else { return [:] }
    let spaces = try Space.fetchAll(db, keys: Array(spaceIds))
    return Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0) })
  }

  private static func fetchPeerUsers(_ db: Database, fullMessages: [FullMessage]) throws -> [Int64: User] {
    let userIds = Set(fullMessages.compactMap(\.message.peerUserId))
    guard !userIds.isEmpty else { return [:] }
    let users = try User.fetchAll(db, keys: Array(userIds))
    return Dictionary(uniqueKeysWithValues: users.map { ($0.id, $0) })
  }

  private static func normalizeWhitespace(_ text: String) -> String {
    text
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
  }

  private static func clipped(_ text: String, radius: Int) -> String {
    guard text.count > radius else { return text }
    let upper = text.index(text.startIndex, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
    return String(text[text.startIndex ..< upper]) + "..."
  }

  private struct Match: Decodable, FetchableRecord {
    let chatId: Int64
    let messageId: Int64
    let rank: Double?

    var key: Key {
      Key(chatId: chatId, messageId: messageId)
    }

    struct Key: Hashable {
      let chatId: Int64
      let messageId: Int64
    }
  }
}

@MainActor
public final class LocalMessageSearchViewModel: ObservableObject {
  @Published public private(set) var results: [LocalMessageSearchResult] = []
  @Published public private(set) var isSearching = false
  @Published public private(set) var error: Error?

  private let db: AppDatabase
  private var searchTask: Task<Void, Never>?
  private var searchToken = UUID()

  public init(db: AppDatabase) {
    self.db = db
  }

  deinit {
    searchTask?.cancel()
  }

  public func search(query: String, options: LocalMessageSearchOptions = LocalMessageSearchOptions()) {
    searchTask?.cancel()
    searchToken = UUID()
    let token = searchToken

    guard LocalMessageSearch.isSearchable(query) else {
      results = []
      isSearching = false
      error = nil
      return
    }

    isSearching = true
    error = nil

    searchTask = Task { [db] in
      do {
        let results = try await LocalMessageSearch.search(db: db, query: query, options: options)
        guard !Task.isCancelled else { return }
        guard searchToken == token else { return }
        self.results = results
        isSearching = false
      } catch {
        guard !Task.isCancelled else { return }
        LocalMessageSearch.log.error("Failed local message search", error: error)
        guard searchToken == token else { return }
        self.error = error
        results = []
        isSearching = false
      }
    }
  }

  public func clear() {
    searchTask?.cancel()
    searchToken = UUID()
    results = []
    isSearching = false
    error = nil
  }
}
