import Foundation
import GRDB
import InlineProtocol
import Synchronization
import Testing

@testable import InlineKit

@Suite("Chat open preparation", .serialized)
@MainActor
struct ChatOpenPreparationTests {
  @Test("a prepared window builds the message list without reading the database", arguments: [true, false])
  func preparedWindowConstructsWithoutReads(threadHasParent: Bool) async throws {
    let fixture = try ChatFixture(threadHasParent: threadHasParent)
    let state = try await fixture.prepare()

    let reads = fixture.countStatements {
      let model = MessagesSectionedViewModel(peer: fixture.thread, reversed: true, initialState: state,
                                             database: fixture.database, publisher: fixture.publisher)
      #expect(model.messages.count == 31)
      #expect(model.threadAnchor?.message.messageId == (threadHasParent ? 5 : nil))
      model.dispose()
    }
    #expect(reads.isEmpty, "construction read: \(reads)")
  }

  @Test("an unresolved anchor is still read during construction")
  func unresolvedAnchorReads() async throws {
    let fixture = try ChatFixture(threadHasParent: true)
    let prepared = try await fixture.prepare()
    let state = MessagesProgressiveViewModel.InitialState(
      messages: prepared.messages, loadedWindowMetadata: prepared.loadedWindowMetadata
    )

    let reads = fixture.countStatements {
      #expect(fixture.model(state).threadAnchor?.message.messageId == 5)
    }
    #expect(!reads.isEmpty)
  }

  @Test("a prepared window matches the window the list loads itself", arguments: [false, true])
  func preparedMatchesSynchronousLoad(directMessage: Bool) async throws {
    let fixture = try ChatFixture(threadHasParent: true)
    let peer = directMessage ? fixture.directMessage : fixture.thread
    let chatId: Int64? = directMessage ? ChatFixture.directMessageChatID : nil

    let loaded = MessagesProgressiveViewModel(peer: peer, chatId: chatId, database: fixture.database, currentUserId: 1)
    // The read resolves a direct message's chat itself when the caller doesn't know it.
    let state = try await fixture.prepare(peer, limit: MessagesProgressiveViewModel.defaultInitialLimit())
    let prepared = fixture.model(state, peer: peer, chatId: chatId)

    #expect(loaded.messages.count == (directMessage ? 21 : 31))
    #expect(prepared.messages.map(\.id) == loaded.messages.map(\.id))
    #expect(prepared.oldestLoadedMessageId == loaded.oldestLoadedMessageId)
    #expect(prepared.newestLoadedMessageId == loaded.newestLoadedMessageId)
    #expect(prepared.canLoadOlderFromLocal == loaded.canLoadOlderFromLocal)
    #expect(prepared.canLoadNewerFromLocal == loaded.canLoadNewerFromLocal)
    #expect(prepared.threadAnchor?.id == loaded.threadAnchor?.id)
  }

  @Test("opening a chat seeks its (chatId, messageId) index without sorting", arguments: [false, true])
  func latestWindowUsesChatIndex(analyzed: Bool) throws {
    let fixture = try ChatFixture(threadHasParent: true, busyChatMessages: analyzed ? 3_000 : 0)
    if analyzed {
      try fixture.queue.write { db in try db.execute(sql: "ANALYZE") }
    }
    let chats: [(InlineKit.Peer, Int64?)] = [(fixture.thread, nil), (fixture.directMessage, ChatFixture.directMessageChatID)]
    try fixture.queue.read { db in
      for (peer, chatId) in chats {
        let plan = try queryPlan(db, MessagesProgressiveViewModel.latestWindowQuery(
          peer: peer, chatId: chatId, currentUserId: 1
        ).limit(60))
        #expect(rootStep(plan)?.contains("message_chat_message_idx (chatId=?") == true, "\(peer): \(plan)")
        #expect(!plan.contains("USE TEMP B-TREE FOR ORDER BY"), "\(peer): \(plan)")
      }
      // Without its chat a direct message can only filter its peer: the plan this replaces.
      let peerOnly = try queryPlan(db, MessagesProgressiveViewModel.latestWindowQuery(
        peer: fixture.directMessage, chatId: nil, currentUserId: 1
      ).limit(60))
      #expect(rootStep(peerOnly)?.contains("message_chat_message_idx") == false, "\(peerOnly)")
    }
  }

  @Test("every opener of a chat shares one read, waits however long it takes, and keeps the window")
  func sharedSlowRead() async throws {
    let read = ControlledRead()
    let preparation = ChatOpenPreparation { _ in try await read.run() }
    let peer = InlineKit.Peer.thread(id: 2)

    #expect(!preparation.isPreparing(peer: peer))
    let openers = (0 ..< 2).map { _ in Task { @MainActor in await preparation.state(for: peer) != nil } }
    while read.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
    try await Task.sleep(for: .milliseconds(300))
    // A view opened now waits for this read instead of reading the chat again.
    #expect(preparation.isPreparing(peer: peer))
    #expect(preparation.readyState(for: peer) == nil)

    read.complete(.success(Self.emptyState))
    for opener in openers {
      #expect(await opener.value)
    }
    #expect(read.calls == 1)
    #expect(!preparation.isPreparing(peer: peer))
    #expect(preparation.readyState(for: peer) != nil)
    #expect(await preparation.state(for: peer) != nil)
    #expect(read.calls == 1)
  }

  @Test("a failed read leaves the list to read its own window")
  func failedRead() async {
    let preparation = ChatOpenPreparation { _ in throw CancellationError() }
    let peer = InlineKit.Peer.user(id: 3)

    #expect(await preparation.state(for: peer) == nil)
    #expect(preparation.readyState(for: peer) == nil)
  }

  @Test("a send confirmed during the read is shown confirmed once the list subscribes")
  func reconcilesSendConfirmedDuringRead() async throws {
    let fixture = try ChatFixture(threadHasParent: false)
    let state = try await fixture.prepare()
    let pending = try #require(state.messages.first { $0.message.messageId == -1 })
    #expect(pending.message.status == .sending)

    // The send's response lands after the read and before any list subscribes.
    let confirmed = try await fixture.database.dbWriter.write { db -> FullMessage in
      var update = InlineProtocol.UpdateMessageId()
      update.randomID = ChatFixture.pendingRandomID(chat: 2)
      update.messageID = 31
      try update.apply(db, currentUserId: 1)
      let row = try FullMessage.queryRequest(currentUserId: 1)
        .filter(Column("globalId") == pending.id).fetchOne(db)
      return try #require(row)
    }
    fixture.publisher.publisher.send(.update(.init(message: confirmed, animated: false, peer: fixture.thread)))

    let model = fixture.model(state)
    #expect(model.messages.first { $0.id == pending.id }?.message.messageId == -1)
    #expect(model.hasPendingReload)
    try await waitForReload(model)

    let row = try #require(model.messages.first { $0.id == pending.id })
    #expect(row.message.messageId == 31)
    #expect(row.message.status == .sent)
    #expect(model.messages.filter { $0.id == pending.id }.count == 1)
  }

  @Test("a message added and one deleted during the read are reconciled")
  func reconcilesAddAndDeleteDuringRead() async throws {
    let fixture = try ChatFixture(threadHasParent: false)
    let state = try await fixture.prepare()

    let added = try await fixture.database.dbWriter.write { db -> FullMessage in
      try Message(
        messageId: 40, fromId: 3, date: Date(timeIntervalSince1970: 1_700_000_100), text: "late",
        peerUserId: nil, peerThreadId: 2, chatId: 2
      ).insert(db)
      try Message.deleteMessages(db, messageIds: [30], chatId: 2)
      let row = try FullMessage.queryRequest(currentUserId: 1)
        .filter(Column("chatId") == 2 && Column("messageId") == 40).fetchOne(db)
      return try #require(row)
    }
    fixture.publisher.publisher.send(.add(.init(messages: [added], peer: fixture.thread)))
    fixture.publisher.publisher.send(.delete(.init(messageIds: [30], peer: fixture.thread)))

    let model = fixture.model(state)
    try await waitForReload(model)

    let ids = model.messages.map(\.message.messageId)
    #expect(ids.contains(40))
    #expect(!ids.contains(30))
  }

  @Test("a window with nothing for its chat published after its read is not read again")
  func noReconcileWithoutPublications() async throws {
    let fixture = try ChatFixture(threadHasParent: false)
    let state = try await fixture.prepare()
    // Another chat's update doesn't concern this one.
    fixture.publisher.publisher.send(.reload(peer: fixture.directMessage, animated: false))

    #expect(!fixture.model(state).hasPendingReload)
    // Pin changes name only a chat, so they concern every peer.
    fixture.publisher.publisher.send(.pinnedMessages(.init(chatId: 99, messageIds: [], pinned: nil)))
    #expect(fixture.model(state).hasPendingReload)
  }

  private func waitForReload(_ model: MessagesProgressiveViewModel) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while model.hasPendingReload, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!model.hasPendingReload)
  }

  private static let emptyState = MessagesProgressiveViewModel.InitialState(
    messages: [], threadAnchor: .resolved(nil), loadedWindowMetadata: .init(messages: [], holes: [])
  )
}

/// The plan step reading the opened chat's rows; later `message` aliases are joined replies.
private func rootStep(_ plan: [String]) -> String? {
  plan.first { $0.hasPrefix("SEARCH message1 ") || $0.hasPrefix("SCAN message1") }
}

private func queryPlan(_ db: Database, _ request: QueryInterfaceRequest<FullMessage>) throws -> [String] {
  let statement = try request.makePreparedRequest(db, forSingleResult: false).statement
  return try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(statement.sql)", arguments: statement.arguments)
    .map { $0["detail"] as String }
}

/// A thread (chat 2, optionally replying to message 5 in chat 1) with 30 saved messages and one
/// pending send, and a direct message with user 3 (chat 4) with 20 saved messages and one pending.
@MainActor
private final class ChatFixture {
  nonisolated static let directMessageChatID: Int64 = 4
  /// Random ids are unique per sender, so each chat's pending send has its own.
  nonisolated static func pendingRandomID(chat: Int64) -> Int64 { 1_000 + chat }

  let thread = InlineKit.Peer.thread(id: 2)
  let directMessage = InlineKit.Peer.user(id: 3)
  let queue: DatabaseQueue
  let database: AppDatabase
  let publisher: MessagesPublisher
  private let statements = StatementLog()

  init(threadHasParent: Bool, busyChatMessages: Int = 0) throws {
    var configuration = AppDatabase.makeConfiguration(passphrase: "123")
    configuration.prepareDatabase { [statements] db in
      db.trace(options: .statement) { statements.record($0.expandedDescription) }
    }
    queue = try DatabaseQueue(configuration: configuration)
    database = try AppDatabase(queue)
    publisher = MessagesPublisher(database: database)

    let start = Date(timeIntervalSince1970: 1_700_000_000)
    try queue.write { db in
      try User(id: 1, email: nil, firstName: "Me").insert(db)
      try User(id: 3, email: nil, firstName: "Peer").insert(db)
      try Chat(id: 1, date: start, type: .thread, title: "Parent", spaceId: nil).insert(db)
      try Chat(
        id: 2, date: start, type: .thread, title: "Replies", spaceId: nil,
        parentChatId: threadHasParent ? 1 : nil, parentMessageId: threadHasParent ? 5 : nil
      ).insert(db)
      try Chat(id: 4, date: start, type: .privateChat, title: nil, spaceId: nil, peerUserId: 3).insert(db)
      try Chat(id: 5, date: start, type: .thread, title: "Busy", spaceId: nil).insert(db)

      func insert(_ id: Int64, chat: Int64, peerUserId: Int64? = nil) throws {
        // Negative ids are sends still waiting for the server.
        try Message(
          messageId: id, randomId: id < 0 ? Self.pendingRandomID(chat: chat) : nil, fromId: 1,
          date: start.addingTimeInterval(TimeInterval(abs(id))), text: "m\(id)",
          peerUserId: peerUserId, peerThreadId: peerUserId == nil ? chat : nil, chatId: chat,
          out: id < 0 ? true : nil, status: id < 0 ? .sending : nil
        ).insert(db)
      }
      try insert(5, chat: 1)
      for id in Int64(1) ... 30 { try insert(id, chat: 2) }
      try insert(-1, chat: 2)
      for id in Int64(1) ... 20 { try insert(id, chat: 4, peerUserId: 3) }
      try insert(-1, chat: 4, peerUserId: 3)
      for id in Int64(1) ... Int64(max(busyChatMessages, 1)) { try insert(id, chat: 5) }
    }
  }

  func prepare(_ peer: InlineKit.Peer? = nil, limit: Int = 60) async throws -> MessagesProgressiveViewModel.InitialState {
    try await MessagesProgressiveViewModel.prepareInitialState(
      peer: peer ?? thread, limit: limit, database: database, publisher: publisher, currentUserId: 1
    )
  }

  func model(
    _ state: MessagesProgressiveViewModel.InitialState, peer: InlineKit.Peer? = nil, chatId: Int64? = nil
  ) -> MessagesProgressiveViewModel {
    MessagesProgressiveViewModel(
      peer: peer ?? thread, chatId: chatId, initialState: state, database: database, publisher: publisher,
      currentUserId: 1
    )
  }

  /// SQL statements run while `body` executes.
  func countStatements(_ body: () throws -> Void) rethrows -> [String] {
    statements.reset()
    try body()
    return statements.reset()
  }
}

private final class StatementLog: Sendable {
  private let statements = Mutex<[String]>([])

  func record(_ statement: String) {
    statements.withLock { $0.append(statement) }
  }

  @discardableResult
  func reset() -> [String] {
    statements.withLock { statements in
      defer { statements = [] }
      return statements
    }
  }
}

/// A read that finishes only when the test completes it.
private final class ControlledRead: Sendable {
  private struct State {
    var calls = 0
    var result: Result<MessagesProgressiveViewModel.InitialState, any Error>?
    var waiters: [CheckedContinuation<MessagesProgressiveViewModel.InitialState, any Error>] = []
  }

  private let state = Mutex(State())

  var calls: Int { state.withLock { $0.calls } }

  func run() async throws -> MessagesProgressiveViewModel.InitialState {
    try await withCheckedThrowingContinuation { continuation in
      let result = state.withLock { state in
        state.calls += 1
        if state.result == nil { state.waiters.append(continuation) }
        return state.result
      }
      if let result { continuation.resume(with: result) }
    }
  }

  func complete(_ result: Result<MessagesProgressiveViewModel.InitialState, any Error>) {
    let waiters = state.withLock { state in
      state.result = result
      defer { state.waiters = [] }
      return state.waiters
    }
    for waiter in waiters {
      waiter.resume(with: result)
    }
  }
}
