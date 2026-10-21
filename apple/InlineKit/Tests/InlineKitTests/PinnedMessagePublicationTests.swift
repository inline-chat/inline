import Combine
import Foundation
import GRDB
import Testing

@testable import InlineKit

@MainActor
@Suite("Pinned message publication", .serialized)
struct PinnedMessagePublicationTests {
  @Test("committed pin, replacement and unpin reach loaded menu state without reads")
  func committedChangesReachSectionedMessages() async throws {
    let queue = try DatabaseQueue()
    let database = try AppDatabase(queue)
    let first = makeMessage(id: 1, chatId: 81_001)
    let second = makeMessage(id: 2, chatId: 81_001)
    try await queue.write { db in
      try User(id: 1, email: nil, firstName: "Sender").insert(db)
      try Chat(id: 81_001, date: Date(), type: .thread, title: "Pins", spaceId: nil).insert(db)
      try first.message.insert(db)
      try second.message.insert(db)
      // Warm the existing mutation's schema metadata before counting publication reads.
      try PinnedMessage(chatId: first.chatId, messageId: 1, position: 0).save(db)
      try PinnedMessage.deleteAll(db)
      try Message.filter(Message.Columns.chatId == first.chatId)
        .updateAll(db, [Message.Columns.pinned.set(to: false)])
    }
    let model = MessagesSectionedViewModel(
      peer: .thread(id: 81_001),
      initialState: .init(messages: [first, second], loadedWindowMetadata: .init(messages: [first, second], holes: [])),
      database: database
    )
    defer { model.dispose() }
    let reads = SelectCounter()
    try await queue.write { db in db.trace { reads.record($0) } }
    var changedIDs: [Int64] = []
    model.observe { update in
      if case let .messagesUpdated(_, ids, _) = update { changedIDs = ids }
    }

    try await committedPinChange(chatId: first.chatId) {
      try await queue.write { db in try PinnedMessage.pin(db, chatId: first.chatId, messageId: 1) }
    }
    #expect(model.messagesByID[first.id]?.message.pinned == true)
    #expect(model.sections.flatMap(\.messages).first { $0.id == first.id }?.message.pinned == true)
    #expect(changedIDs == [first.id])

    try await committedPinChange(chatId: first.chatId) {
      try await queue.write { db in try PinnedMessage.replaceAll(db, chatId: first.chatId, messageIds: [2, 999]) }
    }
    #expect(model.messagesByID[first.id]?.message.pinned == false)
    #expect(model.messagesByID[second.id]?.message.pinned == true)
    #expect(Set(model.messagesByID.keys) == Set([first.id, second.id]))

    try await committedPinChange(chatId: first.chatId) {
      try await queue.write { db in try PinnedMessage.unpin(db, chatId: first.chatId, messageId: 2) }
    }
    #expect(model.messagesByID[second.id]?.message.pinned == false)
    #expect(reads.count == 0, "Pin publication must not hydrate messages or reload the list")
  }

  @Test("pin changes are chat scoped and update loaded parent anchors")
  func scopesChangesAndUpdatesAnchors() throws {
    let queue = try DatabaseQueue()
    let database = try AppDatabase(queue)
    let anchor = makeMessage(id: 1, chatId: 81_002)
    let reply = makeMessage(id: 1, chatId: 81_003)
    let publisher = MessagesPublisher(database: database)
    let model = MessagesProgressiveViewModel(
      peer: .thread(id: 81_003),
      initialState: .init(messages: [reply], threadAnchor: anchor, loadedWindowMetadata: .init(messages: [reply], holes: [])),
      database: database,
      publisher: publisher
    )
    defer { model.dispose() }
    var updatedIDs: [Int64] = []
    model.observe { if case let .updated(messages, _, _) = $0 { updatedIDs = messages.map(\.id) } }
    publisher.pinnedMessagesChanged(.init(chatId: anchor.chatId, messageIds: [1, 999], pinned: true))
    #expect(model.threadAnchor?.message.pinned == true)
    #expect(model.messagesByID[reply.id]?.message.pinned != true)
    #expect(updatedIDs == [anchor.id])
    #expect(model.messages.count == 1)

    publisher.pinnedMessagesChanged(.init(chatId: reply.chatId, messageIds: [1], pinned: true))
    #expect(model.messagesByID[reply.id]?.message.pinned == true)
    publisher.pinnedMessagesChanged(.init(chatId: anchor.chatId, messageIds: [], pinned: nil))
    #expect(model.threadAnchor?.message.pinned == false)
    #expect(model.messagesByID[reply.id]?.message.pinned == true)
  }

  @Test("a rolled-back pin does not publish")
  func rollbackDoesNotPublish() async throws {
    let queue = try DatabaseQueue()
    let database = try AppDatabase(queue)
    let message = makeMessage(id: 1, chatId: 81_004)
    try await queue.write { db in
      try User(id: 1, email: nil, firstName: "Sender").insert(db)
      try Chat(id: message.chatId, date: Date(), type: .thread, title: "Pins", spaceId: nil).insert(db)
      try message.message.insert(db)
    }
    let model = MessagesSectionedViewModel(
      peer: .thread(id: message.chatId),
      initialState: .init(messages: [message], loadedWindowMetadata: .init(messages: [message], holes: [])),
      database: database
    )
    defer { model.dispose() }
    var publications = 0
    let subscription = MessagesPublisher.shared.publisher.sink {
      if case let .pinnedMessages(change) = $0, change.chatId == message.chatId { publications += 1 }
    }
    defer { subscription.cancel() }
    enum Rollback: Error { case requested }
    do {
      try await queue.write { db in
        try PinnedMessage.pin(db, chatId: message.chatId, messageId: 1)
        throw Rollback.requested
      }
      Issue.record("Expected the write to roll back")
    } catch Rollback.requested {}
    // Drain a later committed publication from the same writer/MainActor path.
    try await committedPinChange(chatId: message.chatId) {
      try await queue.write { db in try PinnedMessage.replaceAll(db, chatId: message.chatId, messageIds: []) }
    }
    #expect(publications == 1)
    #expect(model.messagesByID[message.id]?.message.pinned != true)
  }

  @Test("an in-flight reload replays pins even when its loaded list was empty")
  func reloadRetainsNewerPinPublication() async throws {
    let queue = try DatabaseQueue()
    let database = try AppDatabase(queue)
    var message = makeMessage(id: 1, chatId: 81_005)
    message.message.peerUserId = nil
    message.message.peerThreadId = message.chatId
    let saved = message
    try await queue.write { db in
      try User(id: 1, email: nil, firstName: "Sender").insert(db)
      try Chat(
        id: saved.chatId, date: Date(), type: .thread, title: "Pins", spaceId: nil, lastMsgId: 1
      ).insert(db)
      try saved.message.insert(db)
      try MessageHistoryCoverageStore.subtract(
        db, chatId: saved.chatId, lowerId: 1, upperId: MessageHistoryHole.positiveMessageIDMax
      )
    }
    let publisher = MessagesPublisher(database: database)
    let peer = Peer.thread(id: saved.chatId)
    #if os(iOS)
    let token = publisher.activateChat(peer: peer)
    defer { publisher.deactivateChat(token) }
    #endif
    let model = MessagesProgressiveViewModel(
      peer: peer,
      initialState: .init(messages: [], loadedWindowMetadata: .init(messages: [], holes: [])),
      database: database, publisher: publisher, currentUserId: 1
    )
    defer { model.dispose() }
    var reloads = 0
    model.observe { if case .reload = $0 { reloads += 1 } }
    publisher.messagesReload(peer: peer, animated: false)
    // Deliberately leave the database snapshot stale to model a read that began before commit.
    publisher.pinnedMessagesChanged(.init(chatId: saved.chatId, messageIds: [1], pinned: true))
    publisher.pinnedMessagesChanged(.init(chatId: saved.chatId + 1, messageIds: [1], pinned: false))
    #expect(model.messages.isEmpty)
    for _ in 0 ..< 100 where reloads == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(reloads == 1, "The existing reload should finish without being restarted")
    #expect(model.messagesByID[saved.id]?.message.pinned == true)
    #expect(model.messages.count == 1)
  }

  private func committedPinChange(chatId: Int64, perform: () async throws -> Void) async throws {
    let (events, continuation) = AsyncStream<Void>.makeStream()
    let subscription = MessagesPublisher.shared.publisher.sink {
      if case let .pinnedMessages(change) = $0, change.chatId == chatId { continuation.yield(()) }
    }
    defer { subscription.cancel(); continuation.finish() }
    let deadline = Task {
      try? await Task.sleep(for: .seconds(2))
      continuation.finish()
    }
    defer { deadline.cancel() }
    try await perform()
    var iterator = events.makeAsyncIterator()
    #expect(await iterator.next() != nil, "Expected a pin publication after commit")
  }

  private func makeMessage(id: Int64, chatId: Int64) -> FullMessage {
    var message = Message(
      messageId: id, fromId: 1, date: Date(timeIntervalSince1970: 1_700_000_000), text: "Pinned",
      peerUserId: nil, peerThreadId: chatId, chatId: chatId
    )
    message.globalId = chatId * 10 + id
    return FullMessage(senderInfo: nil, message: message, reactions: [], repliedToMessage: nil, attachments: [])
  }
}

private final class SelectCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  var count: Int { lock.withLock { value } }
  func record(_ event: Database.TraceEvent) {
    guard case let .statement(statement) = event,
          statement.sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("SELECT") else { return }
    lock.withLock { value += 1 }
  }
}
