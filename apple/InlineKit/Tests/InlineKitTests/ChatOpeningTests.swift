import Foundation
import GRDB
@testable import InlineKit
import Testing

@Suite("Where a chat opens")
struct ChatOpeningTests {
  private static let peer = Peer.thread(id: 1)

  // MARK: Saved place

  @Test @MainActor
  func savedPlaceInsideHistoryOpensAroundItsRow() async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    let place = ChatReadingPlace(messageId: 1_000, offset: 12)
    let opening = try await fixture.resolve(saved: place)

    #expect(opening.anchor == .saved(place))
    #expect(!opening.droppedSavedPlace)
    #expect(opening.unreadBoundary == nil)
    #expect(opening.uncachedUnreadBoundary == nil)
    let ids = opening.messages.map(\.message.messageId)
    #expect(ids.contains(1_000))
    #expect(ids == Array(956 ... 1_043))
    #expect(try await fixture.isContinuous(opening.messages))

    // The prepared state carries the same window with its own metadata, and the view model keeps
    // every row of it.
    let state = try await fixture.prepare(saved: place)
    #expect(state.openAnchor == .saved(place))
    #expect(state.unreadBoundary == nil)
    #expect(state.messages.map(\.message.messageId) == ids)
    #expect(state.loadedWindowMetadata == (try await fixture.metadata(state.messages)))
    #expect(!state.historyCoverage.isAtCertifiedLiveEnd)
    let model = fixture.model(state)
    defer { model.dispose() }
    #expect(model.messages.map(\.message.messageId) == ids)
  }

  @Test @MainActor
  func savedPlaceInsideTheLatestPageOpensOnTheLatestPage() async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    let place = ChatReadingPlace(messageId: 2_380, offset: 0)
    let latest = try await fixture.latest(60)
    let opening = try await fixture.resolve(saved: place, latest: latest)

    #expect(opening.anchor == .saved(place))
    #expect(opening.messages.map(\.id) == latest.map(\.id))

    let state = try await fixture.prepare(saved: place)
    let plain = try await fixture.prepare(saved: nil)
    #expect(state.openAnchor == .saved(place))
    #expect(state.messages.map(\.id) == plain.messages.map(\.id))
    #expect(state.loadedWindowMetadata == plain.loadedWindowMetadata)
    #expect(state.historyCoverage.isAtCertifiedLiveEnd)
  }

  @Test @MainActor
  func savedPlaceWhoseMessageWasDeletedIsDropped() async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    try await fixture.database.dbWriter.write { db in
      _ = try Message.filter(Column("chatId") == 1 && Column("messageId") == 1_000).deleteAll(db)
    }
    let latest = try await fixture.latest(60)
    let opening = try await fixture.resolve(saved: .init(messageId: 1_000, offset: 4), latest: latest)

    #expect(opening.anchor == .latest)
    #expect(opening.droppedSavedPlace)
    #expect(opening.messages.map(\.id) == latest.map(\.id))
  }

  @Test @MainActor
  func savedPlaceAcrossAHoleIsDroppedForTheLatestMessages() async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    try await fixture.holeAround1_000()
    let latest = try await fixture.latest(60)
    let opening = try await fixture.resolve(saved: .init(messageId: 1_000, offset: 0), latest: latest)

    #expect(opening.anchor == .latest)
    #expect(opening.droppedSavedPlace)
    #expect(opening.unreadBoundary == nil)
    #expect(opening.messages.map(\.id) == latest.map(\.id))
  }

  @Test @MainActor
  func savedPlaceAcrossAHoleIsDroppedForTheUnreadLine() async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    try await fixture.holeAround1_000()
    try await fixture.setUnread(count: 300, readInboxMaxId: 2_100)
    let opening = try await fixture.resolve(saved: .init(messageId: 1_000, offset: 0))

    #expect(opening.anchor == .unread(boundary: 2_100))
    #expect(opening.droppedSavedPlace)
    #expect(opening.unreadBoundary == 2_100)
    #expect(opening.messages.contains { $0.message.messageId == 2_101 })

    let state = try await fixture.prepare(saved: .init(messageId: 1_000, offset: 0))
    #expect(state.openAnchor == .unread(boundary: 2_100))
    #expect(state.messages.map(\.id) == opening.messages.map(\.id))
  }

  @Test @MainActor
  func savedPlaceWinsOverUnreadAndKeepsTheBoundary() async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    try await fixture.setUnread(count: 400, readInboxMaxId: 2_000)
    let place = ChatReadingPlace(messageId: 1_000, offset: 30)
    let opening = try await fixture.resolve(saved: place)

    #expect(opening.anchor == .saved(place))
    #expect(opening.unreadBoundary == 2_000)
    #expect(opening.uncachedUnreadBoundary == nil)
    #expect(!opening.droppedSavedPlace)
    #expect(opening.messages.contains { $0.message.messageId == 1_000 })

    let state = try await fixture.prepare(saved: place)
    #expect(state.openAnchor == .saved(place))
    #expect(state.unreadBoundary == 2_000)
  }

  @Test @MainActor
  func savedPlaceNearTheUnreadLineDrawsTheLine() async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    try await fixture.setUnread(count: 1_400, readInboxMaxId: 1_010)
    let place = ChatReadingPlace(messageId: 1_000, offset: 0)
    let opening = try await fixture.resolve(saved: place)

    #expect(opening.anchor == .saved(place))
    let boundary = try #require(opening.unreadBoundary)
    #expect(ChatUnreadOpening.firstUnreadMessageId(
      in: opening.messages, boundary: boundary, reachesHistoryStart: false
    ) == 1_011)
  }

  // MARK: Unread line

  @Test @MainActor
  func cachedUnreadLineOpensAroundTheBoundary() async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    try await fixture.setUnread(count: 1_400, readInboxMaxId: 1_000)
    let opening = try await fixture.resolve(saved: nil)
    let expected = try #require(try await fixture.database.reader.read { db in
      try ChatUnreadOpening.certifiedWindow(db, peer: Self.peer, boundary: 1_000)
    })

    #expect(opening.anchor == .unread(boundary: 1_000))
    #expect(opening.unreadBoundary == 1_000)
    #expect(opening.uncachedUnreadBoundary == nil)
    #expect(!opening.droppedSavedPlace)
    #expect(opening.messages.map(\.id) == expected.map(\.id))

    let state = try await fixture.prepare(saved: nil)
    #expect(state.openAnchor == .unread(boundary: 1_000))
    #expect(state.unreadBoundary == 1_000)
    #expect(state.messages.map(\.id) == expected.map(\.id))
    #expect(state.loadedWindowMetadata == (try await fixture.metadata(expected)))
  }

  @Test @MainActor
  func unreadLineInsideTheLatestPageKeepsTheLatestPage() async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    try await fixture.setUnread(count: 20, readInboxMaxId: 2_380)
    let latest = try await fixture.latest(60)
    let opening = try await fixture.resolve(saved: nil, latest: latest)

    #expect(opening.anchor == .unread(boundary: 2_380))
    #expect(opening.messages.map(\.id) == latest.map(\.id))
  }

  @Test @MainActor
  func uncachedUnreadLineOpensOnTheLatestMessages() async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    try await fixture.database.dbWriter.write { db in
      try MessageHistoryCoverageStore.invalidate(db, chatId: 1)
      try MessageHistoryCoverageStore.subtract(
        db, chatId: 1, lowerId: 2_000, upperId: MessageHistoryHole.positiveMessageIDMax
      )
      // Dense ids prove themselves continuous; drop the stale rows so the hole is real.
      _ = try Message.filter(Column("messageId") > 1_000 && Column("messageId") < 2_000).deleteAll(db)
    }
    try await fixture.setUnread(count: 1_400, readInboxMaxId: 1_000)
    let latest = try await fixture.latest(60)
    let opening = try await fixture.resolve(saved: nil, latest: latest)

    #expect(opening.anchor == .latest)
    #expect(opening.unreadBoundary == 1_000)
    #expect(opening.uncachedUnreadBoundary == 1_000)
    #expect(!opening.droppedSavedPlace)
    #expect(opening.messages.map(\.id) == latest.map(\.id))

    let state = try await fixture.prepare(saved: nil)
    #expect(state.openAnchor == .latest)
    #expect(state.unreadBoundary == 1_000)
    // The list fetches around the line from this, as macOS does.
    #expect(state.uncachedUnreadBoundary == 1_000)
    #expect(state.messages.map(\.id) == latest.map(\.id))
  }

  // MARK: Latest

  @Test("nothing unread prepares the latest page as before", arguments: [false, true])
  @MainActor
  func nothingUnreadPreparesTheLatestPage(hasDialog: Bool) async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    if hasDialog {
      try await fixture.setUnread(count: 0, readInboxMaxId: 2_400)
    }
    let latest = try await fixture.latest(60)
    let opening = try await fixture.resolve(saved: nil, latest: latest)
    #expect(opening.anchor == .latest)
    #expect(opening.unreadBoundary == nil)
    #expect(opening.uncachedUnreadBoundary == nil)
    #expect(!opening.droppedSavedPlace)
    #expect(opening.messages.map(\.id) == latest.map(\.id))

    // The same rows and metadata the latest-page read gives without an opening decision.
    let state = try await fixture.prepare(saved: nil)
    #expect(state.openAnchor == .latest)
    #expect(state.unreadBoundary == nil)
    #expect(state.messages.map(\.id) == latest.map(\.id))
    #expect(state.loadedWindowMetadata == (try await fixture.metadata(latest)))
    #expect(state.historyCoverage.isAtCertifiedLiveEnd)
    #expect(state.threadAnchor == nil)

    let loaded = MessagesProgressiveViewModel(
      peer: Self.peer, database: fixture.database, publisher: fixture.publisher, currentUserId: 1
    )
    defer { loaded.dispose() }
    let prepared = fixture.model(try await fixture.prepare(saved: nil, limit: MessagesProgressiveViewModel.defaultInitialLimit()))
    defer { prepared.dispose() }
    #expect(prepared.messages.map(\.id) == loaded.messages.map(\.id))
    #expect(prepared.canLoadOlderFromLocal == loaded.canLoadOlderFromLocal)
    #expect(prepared.canLoadNewerFromLocal == loaded.canLoadNewerFromLocal)
  }

  // MARK: Store

  @Test @MainActor
  func storeSavesReadsAndClearsAPlace() {
    let store = ChatReadingPlaceStore(accountId: { 7 })
    let place = ChatReadingPlace(messageId: 42, offset: 18.5)
    #expect(store.place(for: Self.peer) == nil)

    store.save(place, for: Self.peer)
    #expect(store.place(for: Self.peer) == place)
    #expect(store.place(for: .user(id: 1)) == nil)

    let moved = ChatReadingPlace(messageId: 43, offset: 0)
    store.save(moved, for: Self.peer)
    #expect(store.place(for: Self.peer) == moved)

    store.clear(for: Self.peer)
    #expect(store.place(for: Self.peer) == nil)
  }

  /// A second storage on the same database stands in for the next launch.
  @Test @MainActor
  func savedPlaceSurvivesARestart() async throws {
    let database = try AppDatabase(DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123")))
    let place = ChatReadingPlace(messageId: 42, offset: 18.5)
    let store = ChatReadingPlaceStore(accountId: { 7 }, storage: DatabaseChatReadingPlaceStorage(database: database))
    store.save(place, for: Self.peer)
    store.save(ChatReadingPlace(messageId: 9, offset: 0), for: .user(id: 3))
    store.clear(for: .user(id: 3))
    // Writes are queued in order; an empty write after them waits for all three.
    try await database.dbWriter.write { _ in }

    let relaunched = ChatReadingPlaceStore(
      accountId: { 7 }, storage: DatabaseChatReadingPlaceStorage(database: database)
    )
    #expect(relaunched.place(for: Self.peer) == place)
    #expect(relaunched.place(for: .user(id: 3)) == nil)

    let otherAccount = ChatReadingPlaceStore(
      accountId: { 8 }, storage: DatabaseChatReadingPlaceStorage(database: database)
    )
    #expect(otherAccount.place(for: Self.peer) == nil)
  }

  /// Logout clears every local table; a place must not outlive it.
  @Test @MainActor
  func logoutCleanupRemovesSavedPlaces() async throws {
    let database = try AppDatabase(DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123")))
    let store = ChatReadingPlaceStore(accountId: { 7 }, storage: DatabaseChatReadingPlaceStorage(database: database))
    store.save(ChatReadingPlace(messageId: 42, offset: 0), for: Self.peer)
    try await database.dbWriter.write { db in try AppDatabase.clearTables(db) }

    let relaunched = ChatReadingPlaceStore(
      accountId: { 7 }, storage: DatabaseChatReadingPlaceStorage(database: database)
    )
    #expect(relaunched.place(for: Self.peer) == nil)
  }

  @Test @MainActor
  func storeKeepsAccountsApart() {
    var account: Int64? = 1
    let store = ChatReadingPlaceStore(accountId: { account })
    let first = ChatReadingPlace(messageId: 10, offset: 5)
    store.save(first, for: Self.peer)

    account = 2
    #expect(store.place(for: Self.peer) == nil)
    let second = ChatReadingPlace(messageId: 20, offset: 0)
    store.save(second, for: Self.peer)
    store.clear(for: .user(id: 9))

    account = nil
    #expect(store.place(for: Self.peer) == nil)
    store.save(ChatReadingPlace(messageId: 30, offset: 0), for: Self.peer)
    store.clear(for: Self.peer)

    account = 1
    #expect(store.place(for: Self.peer) == first)
    account = 2
    #expect(store.place(for: Self.peer) == second)
  }

  // MARK: Preparation

  @Test @MainActor
  func preparationClearsADroppedPlaceAndKeepsAShownOne() async throws {
    let fixture = try await Fixture(messageCount: 2_400)
    try await fixture.holeAround1_000()
    let store = ChatReadingPlaceStore(accountId: { 1 })
    let prepare: (Peer, ChatReadingPlace?) async throws -> MessagesProgressiveViewModel.InitialState = {
      try await fixture.prepare($0, saved: $1)
    }

    store.save(ChatReadingPlace(messageId: 1_000, offset: 0), for: Self.peer)
    let dropped = try await ChatOpenPreparation.readAtReadingPlace(peer: Self.peer, store: store, prepare: prepare)
    #expect(dropped.openAnchor == .latest)
    #expect(store.place(for: Self.peer) == nil)

    let shown = ChatReadingPlace(messageId: 2_200, offset: 8)
    store.save(shown, for: Self.peer)
    let state = try await ChatOpenPreparation.readAtReadingPlace(peer: Self.peer, store: store, prepare: prepare)
    #expect(state.openAnchor == .saved(shown))
    #expect(state.messages.contains { $0.message.messageId == 2_200 })
    #expect(store.place(for: Self.peer) == shown)
  }
}

private struct Fixture {
  let database: AppDatabase
  let publisher: MessagesPublisher

  @MainActor init(messageCount: Int64) async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    database = try AppDatabase(queue)
    publisher = MessagesPublisher(database: database)
    try await queue.write { db in
      try User(id: 1, email: nil, firstName: "Opening fixture").insert(db)
      try Chat(
        id: 1,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Opening",
        spaceId: nil,
        lastMsgId: messageCount
      ).insert(db)
      for id in Int64(1) ... messageCount {
        var message = Message(
          messageId: id, fromId: 1, date: Date(timeIntervalSince1970: Double(id)), text: "Fixture",
          peerUserId: nil, peerThreadId: 1, chatId: 1
        )
        try message.saveMessage(db)
      }
      try MessageHistoryCoverageStore.subtract(
        db,
        chatId: 1,
        lowerId: 1,
        upperId: MessageHistoryHole.positiveMessageIDMax
      )
    }
  }

  /// History around 1,000 is cached but a hole at 1,011 ... 1,029 cuts it off from the rest.
  func holeAround1_000() async throws {
    try await database.dbWriter.write { db in
      try MessageHistoryCoverageStore.invalidate(db, chatId: 1)
      try MessageHistoryCoverageStore.subtract(db, chatId: 1, lowerId: 1, upperId: 1_010)
      try MessageHistoryCoverageStore.subtract(
        db, chatId: 1, lowerId: 1_030, upperId: MessageHistoryHole.positiveMessageIDMax
      )
      // The rows inside the hole are stale cache, not history.
      _ = try Message.filter(Column("messageId") > 1_010 && Column("messageId") < 1_030).deleteAll(db)
    }
  }

  func setUnread(count: Int, readInboxMaxId: Int64) async throws {
    try await database.dbWriter.write { db in
      let chat = try #require(try Chat.fetchOne(db, id: 1))
      var dialog = Dialog(optimisticForChat: chat)
      dialog.unreadCount = count
      dialog.readInboxMaxId = readInboxMaxId
      try dialog.save(db)
    }
  }

  func latest(_ limit: Int) async throws -> [FullMessage] {
    try await database.reader.read { db in
      try FullMessage.queryRequest(currentUserId: 1)
        .filter(Column("chatId") == 1)
        .order(Column("messageId").desc)
        .limit(limit)
        .fetchAll(db)
        .reversed()
    }
  }

  func resolve(saved: ChatReadingPlace?, latest: [FullMessage]? = nil) async throws -> ChatOpening.Resolution {
    var page = latest ?? []
    if latest == nil { page = try await self.latest(60) }
    let latest = page
    return try await database.reader.read { db in
      let dialog = try Dialog.get(peerId: .thread(id: 1)).fetchOne(db)
      return try ChatOpening.resolve(
        db, peer: .thread(id: 1), saved: saved,
        unreadCount: dialog?.unreadCount, readInboxMaxId: dialog?.readInboxMaxId, latest: latest
      )
    }
  }

  @MainActor func prepare(
    _ peer: Peer = .thread(id: 1),
    saved: ChatReadingPlace?,
    limit: Int = 60
  ) async throws -> MessagesProgressiveViewModel.InitialState {
    try await MessagesProgressiveViewModel.prepareInitialState(
      peer: peer, limit: limit, savedPlace: saved, database: database, publisher: publisher, currentUserId: 1
    )
  }

  func metadata(_ rows: [FullMessage]) async throws -> MessagesProgressiveViewModel.LoadedWindowMetadata {
    try await database.reader.read { db in
      try MessagesProgressiveViewModel.loadedWindowMetadata(db, peer: .thread(id: 1), messages: rows)
    }
  }

  func isContinuous(_ rows: [FullMessage]) async throws -> Bool {
    try await database.reader.read { db in
      try ChatOpening.isContinuous(rows, db: db, peer: .thread(id: 1))
    }
  }

  @MainActor func model(_ state: MessagesProgressiveViewModel.InitialState) -> MessagesProgressiveViewModel {
    MessagesProgressiveViewModel(
      peer: .thread(id: 1), initialState: state, database: database, publisher: publisher, currentUserId: 1
    )
  }
}
