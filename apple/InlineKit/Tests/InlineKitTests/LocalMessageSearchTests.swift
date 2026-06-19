import Foundation
import GRDB
import Testing

@testable import InlineKit

@Suite("Local message search")
struct LocalMessageSearchTests {
  private let userId: Int64 = 1
  private let chatId: Int64 = 1001
  private let otherChatId: Int64 = 1002
  private let spaceId: Int64 = 77

  private func makeInMemoryDB() throws -> (DatabaseQueue, AppDatabase) {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let appDatabase = try AppDatabase(queue)
    return (queue, appDatabase)
  }

  @Test("search finds cached messages with prefix matching")
  func searchFindsCachedMessages() async throws {
    let (queue, appDatabase) = try makeInMemoryDB()

    try await queue.write { db in
      try seedBase(db)
      try seedMessage(db, chatId: chatId, messageId: 1, text: "Deployment starts now")
      try seedMessage(db, chatId: chatId, messageId: 2, text: "Lunch starts later")
    }

    let results = try await LocalMessageSearch.search(
      db: appDatabase,
      query: "deploy",
      options: LocalMessageSearchOptions(peer: .thread(id: chatId), limit: 10)
    )

    #expect(results.map(\.messageId) == [1])
    #expect(results.first?.peer == .thread(id: chatId))
    #expect(results.first?.title == "Search Thread")
    #expect(results.first?.snippet.localizedCaseInsensitiveContains("Deployment") == true)
  }

  @Test("search can sort messages newest first")
  func searchCanSortNewestFirst() async throws {
    let (queue, appDatabase) = try makeInMemoryDB()

    try await queue.write { db in
      try seedBase(db)
      try seedMessage(db, chatId: chatId, messageId: 1, text: "shared ordering keyword")
      try seedMessage(db, chatId: chatId, messageId: 2, text: "shared ordering keyword")
    }

    let results = try await LocalMessageSearch.search(
      db: appDatabase,
      query: "keyword",
      options: LocalMessageSearchOptions(peer: .thread(id: chatId), limit: 10, sort: .newest)
    )

    #expect(results.map(\.messageId) == [2, 1])
  }

  @Test("search updates after message edit and delete")
  func searchTracksMessageChanges() async throws {
    let (queue, appDatabase) = try makeInMemoryDB()

    try await queue.write { db in
      try seedBase(db)
      try seedMessage(db, chatId: chatId, messageId: 1, text: "original text")
      try db.execute(
        sql: "UPDATE message SET text = ? WHERE chatId = ? AND messageId = ?",
        arguments: ["edited searchable text", chatId, 1]
      )
    }

    var results = try await LocalMessageSearch.search(
      db: appDatabase,
      query: "search",
      options: LocalMessageSearchOptions(peer: .thread(id: chatId), limit: 10)
    )
    #expect(results.map(\.messageId) == [1])

    try await queue.write { db in
      try Message.deleteMessages(db, messageIds: [1], chatId: chatId)
    }

    results = try await LocalMessageSearch.search(
      db: appDatabase,
      query: "search",
      options: LocalMessageSearchOptions(peer: .thread(id: chatId), limit: 10)
    )
    #expect(results.isEmpty)
  }

  @Test("search respects peer and space scope")
  func searchRespectsScope() async throws {
    let (queue, appDatabase) = try makeInMemoryDB()

    try await queue.write { db in
      try seedBase(db)
      try seedChat(db, id: otherChatId, title: "Other Thread", spaceId: nil)
      try seedDialog(db, chatId: otherChatId, spaceId: nil)
      try seedMessage(db, chatId: chatId, messageId: 1, text: "shared keyword")
      try seedMessage(db, chatId: otherChatId, messageId: 1, text: "shared keyword")
    }

    let peerResults = try await LocalMessageSearch.search(
      db: appDatabase,
      query: "shared",
      options: LocalMessageSearchOptions(peer: .thread(id: chatId), limit: 10)
    )
    #expect(peerResults.map(\.chatId) == [chatId])

    let spaceResults = try await LocalMessageSearch.search(
      db: appDatabase,
      query: "shared",
      options: LocalMessageSearchOptions(spaceId: spaceId, limit: 10)
    )
    #expect(spaceResults.map(\.chatId) == [chatId])
  }

  @Test("clear tables leaves fts usable")
  func clearTablesLeavesFtsUsable() async throws {
    let (queue, appDatabase) = try makeInMemoryDB()

    try await queue.write { db in
      try seedBase(db)
      try seedMessage(db, chatId: chatId, messageId: 1, text: "clearable keyword")
      try AppDatabase.clearTables(db)
    }

    var results = try await LocalMessageSearch.search(
      db: appDatabase,
      query: "clearable",
      options: LocalMessageSearchOptions(limit: 10)
    )
    #expect(results.isEmpty)

    try await queue.write { db in
      try seedBase(db)
      try seedMessage(db, chatId: chatId, messageId: 2, text: "clearable keyword returns")
    }

    results = try await LocalMessageSearch.search(
      db: appDatabase,
      query: "clearable",
      options: LocalMessageSearchOptions(limit: 10)
    )
    #expect(results.map(\.messageId) == [2])
  }

  @Test("short and invalid queries do not search")
  func shortQueriesDoNotSearch() async throws {
    let (_, appDatabase) = try makeInMemoryDB()

    let empty = try await LocalMessageSearch.search(db: appDatabase, query: "a")
    let punctuation = try await LocalMessageSearch.search(db: appDatabase, query: "***")

    #expect(empty.isEmpty)
    #expect(punctuation.isEmpty)
  }

  private func seedBase(_ db: Database) throws {
    try seedUser(db)
    try seedSpace(db)
    try seedChat(db, id: chatId, title: "Search Thread", spaceId: spaceId)
    try seedDialog(db, chatId: chatId, spaceId: spaceId)
  }

  private func seedUser(_ db: Database) throws {
    try User(
      id: userId,
      email: "search@example.com",
      firstName: "Search",
      lastName: "User",
      username: "search"
    ).insert(db)
  }

  private func seedSpace(_ db: Database) throws {
    try Space(
      id: spaceId,
      name: "search-space",
      date: Date(timeIntervalSince1970: 1)
    ).insert(db)
  }

  private func seedChat(_ db: Database, id: Int64, title: String, spaceId: Int64?) throws {
    try Chat(
      id: id,
      date: Date(timeIntervalSince1970: 1),
      type: .thread,
      title: title,
      spaceId: spaceId
    ).insert(db)
  }

  private func seedDialog(_ db: Database, chatId: Int64, spaceId: Int64?) throws {
    var dialog = Dialog(optimisticForChat: Chat(
      id: chatId,
      date: Date(timeIntervalSince1970: 1),
      type: .thread,
      title: nil,
      spaceId: spaceId
    ))
    dialog.spaceId = spaceId
    dialog.chatId = chatId
    try dialog.insert(db)
  }

  private func seedMessage(_ db: Database, chatId: Int64, messageId: Int64, text: String) throws {
    var message = Message(
      messageId: messageId,
      fromId: userId,
      date: Date(timeIntervalSince1970: TimeInterval(messageId)),
      text: text,
      peerUserId: nil,
      peerThreadId: chatId,
      chatId: chatId
    )
    try message.saveMessage(db)
  }
}
