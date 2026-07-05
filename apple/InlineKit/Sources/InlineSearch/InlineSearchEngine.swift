import Foundation
import GRDB
import InlineKit

actor InlineSearchEngine {
  private let db: AppDatabase
  private let globalClient: any InlineGlobalUserSearching

  init(
    db: AppDatabase,
    globalClient: any InlineGlobalUserSearching
  ) {
    self.db = db
    self.globalClient = globalClient
  }

  func searchLocal(
    query: String,
    scope: InlineSearchScope,
    limits: InlineSearchLimits
  ) async -> InlineSearchLocalPayload {
    guard let preparedQuery = InlineSearchRanker.prepare(query) else {
      return .empty()
    }

    async let chatResult = Self.catching {
      try await Self.searchChats(
        db: db,
        query: preparedQuery,
        scope: scope,
        limit: limits.chatLimit
      )
    }

    async let messageResult = Self.catching {
      try await Self.searchMessages(
        db: db,
        query: preparedQuery.raw,
        scope: scope,
        offset: 0,
        limit: limits.messageBatchSize
      )
    }

    let chats = await chatResult
    let messages = await messageResult
    var errors: [String] = []

    let chatResults: [InlineSearchChatResult]
    switch chats {
    case let .success(results):
      chatResults = results
    case let .failure(error):
      chatResults = []
      errors.append("Chats: \(error.localizedDescription)")
    }

    let messagePage: InlineSearchMessagePage
    switch messages {
    case let .success(page):
      messagePage = page
    case let .failure(error):
      messagePage = .empty
      errors.append("Messages: \(error.localizedDescription)")
    }

    return InlineSearchLocalPayload(
      chats: chatResults,
      messages: messagePage.results,
      hasMoreMessages: messagePage.hasMore,
      errorText: errors.isEmpty ? nil : errors.joined(separator: "\n")
    )
  }

  func searchMoreMessages(
    query: String,
    scope: InlineSearchScope,
    offset: Int,
    limit: Int
  ) async -> InlineSearchMessagePage {
    guard LocalMessageSearch.isSearchable(query) else { return .empty }

    do {
      return try await Self.searchMessages(
        db: db,
        query: query,
        scope: scope,
        offset: offset,
        limit: limit
      )
    } catch {
      return InlineSearchMessagePage(
        results: [],
        hasMore: false,
        errorText: "Messages: \(error.localizedDescription)"
      )
    }
  }

  func searchGlobalUsers(
    query: String,
    scope: InlineSearchScope,
    limit: Int
  ) async throws -> [InlineSearchGlobalUserResult] {
    guard scope.includeGlobalUsers else { return [] }
    guard let preparedQuery = InlineSearchRanker.prepare(query), preparedQuery.compact.count >= 2 else {
      return []
    }

    return try await globalClient
      .searchUsers(query: preparedQuery.raw)
      .compactMap { user -> InlineSearchGlobalUserResult? in
        let fields = [
          InlineSearchRanker.Field(apiUserTitle(user), weight: 4),
          InlineSearchRanker.Field(user.username, weight: 5),
          InlineSearchRanker.Field(user.email, weight: 2),
        ]
        guard let score = InlineSearchRanker.score(query: preparedQuery, fields: fields) else {
          return nil
        }
        return InlineSearchGlobalUserResult(user: user, score: score)
      }
      .sorted { lhs, rhs in
        if lhs.score != rhs.score {
          return lhs.score > rhs.score
        }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
      }
      .prefix(limit)
      .map { $0 }
  }

  private static func searchChats(
    db appDatabase: AppDatabase,
    query: InlineSearchRanker.PreparedQuery,
    scope: InlineSearchScope,
    limit: Int
  ) async throws -> [InlineSearchChatResult] {
    try await appDatabase.reader.read { db in
      let items = try HomeChatItem.all().fetchAll(db)
      let snapshots = try HomeChatListItemSnapshot.snapshots(from: items, db: db)
      let scoped = snapshots.filter { snapshot in
        if scope.includeArchived == false, snapshot.archived {
          return false
        }

        let itemSpaceId = snapshot.item.dialog.spaceId ?? snapshot.item.chat?.spaceId ?? snapshot.item.space?.id

        if let scopeSpaceId = scope.spaceId {
          return itemSpaceId == scopeSpaceId
        }

        if scope.includeSpaceChatsInHome == false {
          return itemSpaceId == nil
        }

        return true
      }

      let counts = try messageCounts(db, chatIds: scoped.compactMap(\.chatId))

      return scoped
        .compactMap { snapshot -> InlineSearchChatResult? in
          let messageCount = snapshot.chatId.flatMap { counts[$0] } ?? 0
          guard var score = chatScore(snapshot, query: query, messageCount: messageCount) else {
            return nil
          }

          if snapshot.unread {
            score += 80
          }
          if snapshot.pinned {
            score += 30
          }

          return InlineSearchChatResult(
            snapshot: snapshot,
            messageCount: messageCount,
            score: score
          )
        }
        .sorted { lhs, rhs in
          if lhs.score != rhs.score {
            return lhs.score > rhs.score
          }
          if lhs.lastDate != rhs.lastDate {
            return lhs.lastDate > rhs.lastDate
          }
          return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        .prefix(limit)
        .map { $0 }
    }
  }

  private static func chatScore(
    _ snapshot: HomeChatListItemSnapshot,
    query: InlineSearchRanker.PreparedQuery,
    messageCount: Int
  ) -> Int? {
    let user = snapshot.item.displayUserInfo?.user
    let fields = [
      InlineSearchRanker.Field(snapshot.title, weight: 5),
      InlineSearchRanker.Field(snapshot.spaceTitle, weight: 2),
      InlineSearchRanker.Field(snapshot.preview, weight: 1),
      InlineSearchRanker.Field(user?.username, weight: 5),
      InlineSearchRanker.Field(user?.email, weight: 2),
    ]

    guard let matchScore = InlineSearchRanker.score(query: query, fields: fields) else {
      return nil
    }

    return matchScore + InlineSearchRanker.activityScore(
      messageCount: messageCount,
      lastDate: snapshot.sortDate
    )
  }

  private static func searchMessages(
    db appDatabase: AppDatabase,
    query: String,
    scope: InlineSearchScope,
    offset: Int,
    limit: Int
  ) async throws -> InlineSearchMessagePage {
    guard LocalMessageSearch.isSearchable(query) else {
      return .empty
    }

    let batchSize = max(1, min(limit, LocalMessageSearch.maxLimit - 1))
    let results = try await LocalMessageSearch.search(
      db: appDatabase,
      query: query,
      options: LocalMessageSearchOptions(
        spaceId: scope.spaceId,
        limit: batchSize + 1,
        offset: offset,
        includeArchived: scope.includeArchived,
        sort: scope.messageSort
      )
    )

    return InlineSearchMessagePage(
      results: Array(results.prefix(batchSize)),
      hasMore: results.count > batchSize,
      errorText: nil
    )
  }

  private static func messageCounts(_ db: Database, chatIds: [Int64]) throws -> [Int64: Int] {
    let ids = Array(Set(chatIds))
    guard ids.isEmpty == false else { return [:] }

    let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
    let rows = try MessageCount.fetchAll(
      db,
      sql: """
      SELECT chatId, COUNT(*) AS count
      FROM message
      WHERE chatId IN (\(placeholders))
      GROUP BY chatId
      """,
      arguments: StatementArguments(ids)
    )

    return Dictionary(uniqueKeysWithValues: rows.map { ($0.chatId, $0.count) })
  }

  private static func catching<T: Sendable>(
    _ body: @Sendable () async throws -> T
  ) async -> Result<T, Error> {
    do {
      return .success(try await body())
    } catch {
      return .failure(error)
    }
  }

  private struct MessageCount: Decodable, FetchableRecord {
    let chatId: Int64
    let count: Int
  }
}
