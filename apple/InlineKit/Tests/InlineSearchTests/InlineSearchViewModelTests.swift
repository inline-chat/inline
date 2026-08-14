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

  @Test("command bar catalog matches rich chat identity and ordering without message hydration")
  func commandBarCatalogUsesCompactSnapshots() async throws {
    let (queue, appDatabase) = try makeInMemoryDB()
    let directUserId: Int64 = 31
    let cachedUserId: Int64 = 32
    let directChatId: Int64 = 5031
    let roomId: Int64 = 6031
    let unreferencedSpaceId: Int64 = 78

    try await queue.write { db in
      try seedUser(db, id: directUserId, firstName: "Alexander", lastName: nil, username: "alexander")
      try seedUser(db, id: cachedUserId, firstName: "Mo", lastName: nil, username: "mo")
      try seedPrivateChat(db, chatId: directChatId, userId: directUserId)
      try seedSpace(db, id: spaceId)
      try seedSpace(db, id: unreferencedSpaceId)
      try seedThread(db, id: roomId, title: "Dena planning", spaceId: spaceId)
      try seedDialog(db, chat: try Chat.fetchOne(db, id: roomId)!)

      try seedMessage(db, chatId: directChatId, messageId: 20, fromUserId: directUserId, text: "direct")
      try seedMessage(db, chatId: roomId, messageId: 30, fromUserId: directUserId, text: "room")
      try setLastMessage(db, chatId: directChatId, messageId: 20)
      try setLastMessage(db, chatId: roomId, messageId: 30)
    }

    let commandBarSnapshot = try await appDatabase.fetchCommandBarCatalogSnapshot()
    let compact = commandBarSnapshot.chats
    let rich = try await queue.read { db in
      try HomeChatListItemSnapshot.snapshots(from: HomeChatItem.all().fetchAll(db), db: db)
    }

    #expect(compact.map(\.peerId) == rich.map(\.peerId))
    #expect(compact.map(\.title) == rich.map(\.title))
    #expect(compact.map(\.spaceTitle) == rich.map(\.spaceTitle))
    #expect(compact.map(\.sortDate) == rich.map(\.sortDate))
    #expect(compact.allSatisfy { $0.item.lastMessage == nil })
    #expect(compact.allSatisfy { $0.preview.isEmpty })
    #expect(compact.first { $0.peerId == .user(id: directUserId) }?.item.user?.user.username == "alexander")
    #expect(Set(commandBarSnapshot.knownUsers.map(\.id)).isSuperset(of: [directUserId, cachedUserId]))
    #expect(Set(commandBarSnapshot.spaces.map(\.id)) == [spaceId, unreferencedSpaceId])
  }

  @Test("command bar catalog includes cached people without duplicating dialogs or self")
  func commandBarCatalogIncludesCachedPeople() async throws {
    let (queue, appDatabase) = try makeInMemoryDB()
    let cachedUserId: Int64 = 41
    let dialogUserId: Int64 = 42
    let currentUserId: Int64 = 43

    try await queue.write { db in
      try seedUser(db, id: cachedUserId, firstName: "Mo", lastName: "Cached", username: "mo")
      try seedUser(db, id: dialogUserId, firstName: "Mo", lastName: "Dialog", username: "modialog")
      try seedPrivateChat(db, chatId: 5_042, userId: dialogUserId)
      try seedUser(db, id: currentUserId, firstName: "Mo", lastName: "Self", username: "moself")
    }

    let snapshot = try await appDatabase.fetchCommandBarCatalogSnapshot()
    let catalog = InlineSearchChatCatalog()
    await catalog.replace(snapshot.chats, knownUsers: snapshot.knownUsers)
    let projection = await catalog.project(
      query: "mo",
      usage: [:],
      currentPeer: nil,
      currentUserID: currentUserId,
      scope: InlineSearchScope(includeArchived: true)
    )

    #expect(projection.knownUsers.map(\.id) == [cachedUserId])
    #expect(projection.chats.map(\.peer) == [.user(id: dialogUserId)])
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

  @Test("clearing search ignores an in-flight global result")
  func clearingSearchIgnoresInFlightGlobalResult() async throws {
    let (_, db) = try makeInMemoryDB()
    let client = BlockingGlobalClient()
    let model = InlineSearchViewModel(
      db: db,
      limits: InlineSearchLimits(globalDebounceNanoseconds: 0),
      globalClient: client
    )

    model.search("first")
    await client.waitForQuery("first")

    model.clear()
    await client.resume(
      query: "first",
      users: [apiUser(id: 1, firstName: "First", username: "first")]
    )
    try await Task.sleep(nanoseconds: 20_000_000)

    #expect(model.query.isEmpty)
    #expect(model.globalUsers.isEmpty)
    #expect(model.isSearching == false)
    #expect(model.errorText == nil)
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

  @Test("chat catalog uses switch frequency within the same match tier")
  func chatCatalogUsesSwitchFrequencyWithinTier() async throws {
    let (queue, _) = try makeInMemoryDB()
    let alexanderId: Int64 = 10
    let alexThreadId: Int64 = 7010

    try await queue.write { db in
      try seedUser(db, id: alexanderId, firstName: "Alexander", lastName: nil, username: "alexander")
      try seedPrivateChat(db, chatId: 5010, userId: alexanderId)
      try seedThread(db, id: alexThreadId, title: "Alex's xyz", spaceId: nil)
      try seedDialog(db, chat: try Chat.fetchOne(db, id: alexThreadId)!)
    }

    let snapshots = try await queue.read { db in
      try HomeChatListItemSnapshot.snapshots(from: HomeChatItem.all().fetchAll(db), db: db)
    }
    let catalog = InlineSearchChatCatalog()
    await catalog.replace(snapshots)

    let projection = await catalog.project(
      query: "alex",
      usage: [
        .user(id: alexanderId): InlineSearchUsageSignal(switchFrecency: 50),
        .thread(id: alexThreadId): InlineSearchUsageSignal(switchFrecency: 1),
      ],
      currentPeer: nil,
      scope: InlineSearchScope(includeArchived: true)
    )

    #expect(projection.chats.map(\.peer).prefix(2) == [
      .user(id: alexanderId),
      .thread(id: alexThreadId),
    ])
  }

  @Test("command bar catalog searches numbered space threads by provisional reference")
  func commandBarCatalogSearchesSpaceThreadReferences() async throws {
    let (queue, _) = try makeInMemoryDB()
    let numberedThreadId: Int64 = 7_011
    let homeThreadId: Int64 = 7_012

    try await queue.write { db in
      try seedSpace(db, id: spaceId)
      try seedThread(db, id: numberedThreadId, title: "Decision follow-up", spaceId: spaceId, number: 314)
      try seedThread(db, id: homeThreadId, title: "Home notes", spaceId: nil, number: 314)
      try seedDialog(db, chat: try Chat.fetchOne(db, id: numberedThreadId)!)
      try seedDialog(db, chat: try Chat.fetchOne(db, id: homeThreadId)!)
    }

    let snapshots = try await queue.read { db in
      try HomeChatListItemSnapshot.snapshots(from: HomeChatItem.all().fetchAll(db), db: db)
    }
    let catalog = InlineSearchChatCatalog()
    await catalog.replace(snapshots)

    for query in ["314", "#314"] {
      let projection = await catalog.project(
        query: query,
        usage: [:],
        currentPeer: nil,
        scope: InlineSearchScope(includeArchived: true)
      )

      #expect(projection.chats.map(\.peer) == [.thread(id: numberedThreadId)])
      #expect(projection.chats.first?.chat?.spaceThreadReferenceLabel == "#314")
    }
  }

  @Test("chat catalog query affinity learns the selected Dena")
  func chatCatalogUsesQueryAffinity() async throws {
    let (queue, _) = try makeInMemoryDB()
    let preferredId: Int64 = 20
    let otherId: Int64 = 21

    try await queue.write { db in
      try seedUser(db, id: preferredId, firstName: "Dena", lastName: "Preferred", username: "denap")
      try seedPrivateChat(db, chatId: 5020, userId: preferredId)
      try seedUser(db, id: otherId, firstName: "Dena", lastName: "Other", username: "denao")
      try seedPrivateChat(db, chatId: 5021, userId: otherId)
    }

    let snapshots = try await queue.read { db in
      try HomeChatListItemSnapshot.snapshots(from: HomeChatItem.all().fetchAll(db), db: db)
    }
    let catalog = InlineSearchChatCatalog()
    await catalog.replace(snapshots)

    let projection = await catalog.project(
      query: "dena",
      usage: [
        .user(id: preferredId): InlineSearchUsageSignal(queryAffinity: 8),
        .user(id: otherId): InlineSearchUsageSignal(queryAffinity: 1),
      ],
      currentPeer: nil,
      scope: InlineSearchScope(includeArchived: true)
    )

    #expect(projection.chats.first?.peer == .user(id: preferredId))
  }

  @Test("chat catalog never lets usage outrank text relevance")
  func chatCatalogKeepsTextTierAheadOfUsage() async throws {
    let (queue, _) = try makeInMemoryDB()
    let exactThreadId: Int64 = 7020
    let heavilyUsedUserId: Int64 = 22

    try await queue.write { db in
      try seedThread(db, id: exactThreadId, title: "Alex", spaceId: nil)
      try seedDialog(db, chat: try Chat.fetchOne(db, id: exactThreadId)!)
      try seedUser(db, id: heavilyUsedUserId, firstName: "Alexander", lastName: nil, username: "alexander")
      try seedPrivateChat(db, chatId: 5022, userId: heavilyUsedUserId)
    }

    let snapshots = try await queue.read { db in
      try HomeChatListItemSnapshot.snapshots(from: HomeChatItem.all().fetchAll(db), db: db)
    }
    let catalog = InlineSearchChatCatalog()
    await catalog.replace(snapshots)

    let projection = await catalog.project(
      query: "alex",
      usage: [
        .user(id: heavilyUsedUserId): InlineSearchUsageSignal(
          switchFrecency: 1_000_000,
          queryAffinity: 1_000_000
        )
      ],
      currentPeer: nil,
      scope: InlineSearchScope(includeArchived: true)
    )

    #expect(projection.chats.map(\.peer).prefix(2) == [
      .thread(id: exactThreadId),
      .user(id: heavilyUsedUserId),
    ])
  }

  @Test("empty chat catalog returns suggestions then deduped chats")
  func chatCatalogEmptyProjection() async throws {
    let (queue, _) = try makeInMemoryDB()
    let firstId: Int64 = 30
    let secondId: Int64 = 31
    let currentId: Int64 = 32

    try await queue.write { db in
      for (id, name) in [(firstId, "First"), (secondId, "Second"), (currentId, "Current")] {
        try seedUser(db, id: id, firstName: name, lastName: nil, username: name.lowercased())
        try seedPrivateChat(db, chatId: 5_000 + id, userId: id)
      }
    }

    let snapshots = try await queue.read { db in
      try HomeChatListItemSnapshot.snapshots(from: HomeChatItem.all().fetchAll(db), db: db)
    }
    let catalog = InlineSearchChatCatalog()
    await catalog.replace(snapshots)

    let projection = await catalog.project(
      query: "",
      usage: [
        .user(id: firstId): InlineSearchUsageSignal(switchFrecency: 10),
        .user(id: secondId): InlineSearchUsageSignal(switchFrecency: 5),
        .user(id: currentId): InlineSearchUsageSignal(switchFrecency: 100),
      ],
      currentPeer: .user(id: currentId),
      scope: InlineSearchScope(includeArchived: false),
      suggestionLimit: 1,
      chatLimit: 5
    )

    #expect(projection.suggestions.map(\.peer) == [.user(id: firstId)])
    #expect(projection.chats.map(\.peer) == [.user(id: secondId)])
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
    number: Int? = nil,
    parentChatId: Int64? = nil,
    parentMessageId: Int64? = nil
  ) throws {
    try Chat(
      id: id,
      date: Date(timeIntervalSince1970: 1),
      type: .thread,
      title: title,
      spaceId: spaceId,
      number: number,
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

  nonisolated private func setLastMessage(
    _ db: Database,
    chatId: Int64,
    messageId: Int64
  ) throws {
    guard var chat = try Chat.fetchOne(db, id: chatId) else { return }
    chat.lastMsgId = messageId
    try chat.update(db)
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
