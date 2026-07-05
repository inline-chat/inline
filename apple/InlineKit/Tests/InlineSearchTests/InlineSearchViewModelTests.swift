import Foundation
import GRDB
import Testing

@testable import InlineKit
@testable import InlineSearch

@Suite("Inline search view model")
@MainActor
struct InlineSearchViewModelTests {
  private let userId: Int64 = 1
  private let privateChatId: Int64 = 5001
  private let threadId: Int64 = 6001
  private let spaceId: Int64 = 77

  @Test("search returns chat, message, and global user results")
  func searchReturnsCombinedResults() async throws {
    let (queue, db) = try makeInMemoryDB()

    try await queue.write { db in
      try seedUser(db, id: userId, firstName: "Search", lastName: "User", username: "search")
      try seedSpace(db, id: spaceId)
      try seedThread(db, id: threadId, title: "Deploy Room", spaceId: spaceId)
      try seedDialog(db, chat: try Chat.fetchOne(db, id: threadId)!)
      try seedMessage(db, chatId: threadId, messageId: 1, fromUserId: userId, text: "deploy keyword one")
      try seedMessage(db, chatId: threadId, messageId: 2, fromUserId: userId, text: "deploy keyword two")
    }

    let model = InlineSearchViewModel(
      db: db,
      limits: InlineSearchLimits(globalDebounceNanoseconds: 0),
      globalClient: StaticGlobalClient(usersByQuery: [
        "deploy": [apiUser(id: 99, firstName: "Deploy", username: "deploy")]
      ])
    )

    model.search("deploy")
    try await waitUntil { model.isSearching == false }

    #expect(model.chats.map(\.title) == ["Deploy Room"])
    #expect(model.messages.map(\.messageId) == [2, 1])
    #expect(model.globalUsers.map(\.id) == [99])
    #expect(model.errorText == nil)
  }

  @Test("global users are deduped against local private chats")
  func globalUsersDedupeLocalPrivateChats() async throws {
    let (queue, db) = try makeInMemoryDB()

    try await queue.write { db in
      try seedUser(db, id: userId, firstName: "Jane", lastName: "Local", username: "jane")
      try seedPrivateChat(db, chatId: privateChatId, userId: userId)
    }

    let model = InlineSearchViewModel(
      db: db,
      limits: InlineSearchLimits(globalDebounceNanoseconds: 0),
      globalClient: StaticGlobalClient(usersByQuery: [
        "jane": [
          apiUser(id: userId, firstName: "Jane", username: "jane"),
          apiUser(id: 42, firstName: "Jane", username: "remotejane"),
        ]
      ])
    )

    model.search("jane")
    try await waitUntil { model.isSearching == false }

    #expect(model.chats.map(\.peer) == [.user(id: userId)])
    #expect(model.globalUsers.map(\.id) == [42])
  }

  @Test("chat search does not match reply thread parent title")
  func chatSearchDoesNotMatchReplyThreadParentTitle() async throws {
    let (queue, db) = try makeInMemoryDB()
    let parentThreadId: Int64 = 7001
    let childThreadId: Int64 = 7002

    try await queue.write { db in
      try seedThread(db, id: parentThreadId, title: "Bug Triage", spaceId: nil)
      try seedThread(
        db,
        id: childThreadId,
        title: "Customer Followup",
        spaceId: nil,
        parentChatId: parentThreadId,
        parentMessageId: 1
      )
      try seedDialog(db, chat: try Chat.fetchOne(db, id: parentThreadId)!)
      try seedDialog(db, chat: try Chat.fetchOne(db, id: childThreadId)!)
    }

    let model = InlineSearchViewModel(
      db: db,
      limits: InlineSearchLimits(globalDebounceNanoseconds: 0),
      globalClient: StaticGlobalClient()
    )

    model.search("bug")
    try await waitUntil { model.isSearching == false }

    #expect(model.chats.map(\.peer) == [.thread(id: parentThreadId)])
  }

  @Test("message search loads more in FTS batches")
  func messageSearchLoadsMore() async throws {
    let (queue, db) = try makeInMemoryDB()

    try await queue.write { db in
      try seedUser(db, id: userId, firstName: "Search", lastName: "User", username: "search")
      try seedThread(db, id: threadId, title: "Keyword Thread", spaceId: nil)
      try seedDialog(db, chat: try Chat.fetchOne(db, id: threadId)!)

      for messageId in 1...25 {
        try seedMessage(
          db,
          chatId: threadId,
          messageId: Int64(messageId),
          fromUserId: userId,
          text: "batch keyword \(messageId)"
        )
      }
    }

    let model = InlineSearchViewModel(
      db: db,
      limits: InlineSearchLimits(messageBatchSize: 10, globalDebounceNanoseconds: 0),
      globalClient: StaticGlobalClient()
    )

    model.search("keyword")
    try await waitUntil { model.isSearchingLocal == false }

    #expect(model.messages.count == 10)
    #expect(model.hasMoreMessages)

    model.loadMoreMessages()
    try await waitUntil { model.isLoadingMoreMessages == false && model.messages.count == 20 }
    #expect(model.hasMoreMessages)

    model.loadMoreMessages()
    try await waitUntil { model.isLoadingMoreMessages == false && model.messages.count == 25 }
    #expect(model.hasMoreMessages == false)
  }

  @Test("stale global results do not replace newer queries")
  func staleGlobalResultsAreIgnored() async throws {
    let (_, db) = try makeInMemoryDB()
    let client = BlockingGlobalClient()
    let model = InlineSearchViewModel(
      db: db,
      limits: InlineSearchLimits(globalDebounceNanoseconds: 0),
      globalClient: client
    )

    model.search("first")
    await client.waitForQuery("first")

    model.search("second")
    await client.waitForQuery("second")

    await client.resume(query: "second", users: [apiUser(id: 2, firstName: "Second", username: "second")])
    try await waitUntil { model.isSearchingGlobal == false && model.globalUsers.map(\.id) == [2] }

    await client.resume(query: "first", users: [apiUser(id: 1, firstName: "First", username: "first")])
    try await Task.sleep(nanoseconds: 20_000_000)

    #expect(model.globalUsers.map(\.id) == [2])
  }

  @Test("ranker prefers exact field matches over contains matches")
  func rankerPrefersExactMatches() throws {
    let query = try #require(InlineSearchRanker.prepare("deploy"))
    let exact = try #require(InlineSearchRanker.score(
      query: query,
      fields: [InlineSearchRanker.Field("deploy", weight: 1)]
    ))
    let contains = try #require(InlineSearchRanker.score(
      query: query,
      fields: [InlineSearchRanker.Field("weekly deploy notes", weight: 1)]
    ))

    #expect(exact > contains)
    #expect(InlineSearchRanker.activityScore(
      messageCount: 50,
      lastDate: Date(timeIntervalSince1970: 100),
      now: Date(timeIntervalSince1970: 200)
    ) > InlineSearchRanker.activityScore(
      messageCount: 1,
      lastDate: Date(timeIntervalSince1970: -1_000_000),
      now: Date(timeIntervalSince1970: 200)
    ))
  }

  nonisolated private func makeInMemoryDB() throws -> (DatabaseQueue, AppDatabase) {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let appDatabase = try AppDatabase(queue)
    return (queue, appDatabase)
  }

  nonisolated private func seedUser(
    _ db: Database,
    id: Int64,
    firstName: String,
    lastName: String?,
    username: String?
  ) throws {
    try User(
      id: id,
      email: "\(username ?? "user")@example.com",
      firstName: firstName,
      lastName: lastName,
      username: username
    ).insert(db)
  }

  nonisolated private func seedSpace(_ db: Database, id: Int64) throws {
    try Space(
      id: id,
      name: "search-space",
      date: Date(timeIntervalSince1970: 1)
    ).insert(db)
  }

  nonisolated private func seedThread(
    _ db: Database,
    id: Int64,
    title: String,
    spaceId: Int64?,
    parentChatId: Int64? = nil,
    parentMessageId: Int64? = nil
  ) throws {
    try Chat(
      id: id,
      date: Date(timeIntervalSince1970: 1),
      type: .thread,
      title: title,
      spaceId: spaceId,
      parentChatId: parentChatId,
      parentMessageId: parentMessageId
    ).insert(db)
  }

  nonisolated private func seedPrivateChat(_ db: Database, chatId: Int64, userId: Int64) throws {
    let chat = Chat(
      id: chatId,
      date: Date(timeIntervalSince1970: 1),
      type: .privateChat,
      title: nil,
      spaceId: nil,
      peerUserId: userId
    )
    try chat.insert(db)
    try seedDialog(db, chat: chat)
  }

  nonisolated private func seedDialog(_ db: Database, chat: Chat) throws {
    var dialog = Dialog(optimisticForChat: chat)
    dialog.chatId = chat.id
    dialog.spaceId = chat.spaceId
    try dialog.insert(db)
  }

  nonisolated private func seedMessage(
    _ db: Database,
    chatId: Int64,
    messageId: Int64,
    fromUserId: Int64,
    text: String
  ) throws {
    var message = Message(
      messageId: messageId,
      fromId: fromUserId,
      date: Date(timeIntervalSince1970: TimeInterval(messageId)),
      text: text,
      peerUserId: nil,
      peerThreadId: chatId,
      chatId: chatId
    )
    try message.saveMessage(db)
  }

  private func waitUntil(
    timeout: TimeInterval = 2,
    _ predicate: @MainActor @escaping () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while predicate() == false {
      if Date() > deadline {
        throw WaitError.timedOut
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
  }
}

private struct StaticGlobalClient: InlineGlobalUserSearching {
  var usersByQuery: [String: [ApiUser]] = [:]

  func searchUsers(query: String) async throws -> [ApiUser] {
    usersByQuery[query] ?? []
  }
}

private actor BlockingGlobalClient: InlineGlobalUserSearching {
  private var continuations: [String: CheckedContinuation<[ApiUser], any Error>] = [:]
  private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

  func searchUsers(query: String) async throws -> [ApiUser] {
    try await withCheckedThrowingContinuation { continuation in
      continuations[query] = continuation
      let queryWaiters = waiters.removeValue(forKey: query) ?? []
      for waiter in queryWaiters {
        waiter.resume()
      }
    }
  }

  func waitForQuery(_ query: String) async {
    if continuations[query] != nil {
      return
    }

    await withCheckedContinuation { continuation in
      waiters[query, default: []].append(continuation)
    }
  }

  func resume(query: String, users: [ApiUser]) {
    continuations.removeValue(forKey: query)?.resume(returning: users)
  }
}

private func apiUser(id: Int64, firstName: String, username: String) -> ApiUser {
  ApiUser(
    id: id,
    email: "\(username)@example.com",
    firstName: firstName,
    lastName: nil,
    date: 1,
    username: username
  )
}

private enum WaitError: Error {
  case timedOut
}
