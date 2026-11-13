import Combine
import Foundation
import GRDB
@testable import InlineKit
import Testing

/// Every path that changes a real view model's window publishes one row
/// snapshot with its reason, alongside the existing change sets.
@Suite("Chat row feed publication")
struct ChatRowFeedPublicationTests {
  @MainActor private final class Recorder {
    var updates: [ChatRowUpdate] = []
    var changeSets: [MessagesProgressiveViewModel.MessagesChangeSet] = []
    private var cancellable: AnyCancellable?

    init(_ model: MessagesProgressiveViewModel) {
      model.rowFeed.isPublishing = true
      cancellable = model.rowFeed.updates.sink { [weak self] in self?.updates.append($0) }
      model.observe { [weak self] in self?.changeSets.append($0) }
    }

    var reasons: [ChatRowReason] { updates.map(\.snapshot.reason) }
    var last: ChatRowUpdate? { updates.last }

    func wait(for reason: ChatRowReason) async throws {
      for _ in 0 ..< 300 where !reasons.contains(reason) {
        try await Task.sleep(for: .milliseconds(10))
      }
    }
  }

  private static func messageIDs(_ snapshot: ChatRowSnapshot?) -> [Int64] {
    snapshot?.rows.compactMap { $0.content.message.map(\.message.messageId) } ?? []
  }

  @Test @MainActor
  func initialOpenPublishesTheOpeningWindow() async throws {
    let fixture = try await RowFixture()
    let model = fixture.model(rows: Array(fixture.messages[79 ... 99]), openAnchor: .unread(boundary: 85),
                              unreadBoundary: 85)
    defer { model.dispose() }
    let snapshot = try #require(model.rowFeed.snapshot)
    #expect(snapshot.reason == .initialOpen(.unread(boundary: 85)))
    #expect(snapshot.revision == 1)
    #expect(Self.messageIDs(snapshot) == Array(80 ... 100))
    #expect(snapshot.unreadLineMessageId == 86)
    #expect(snapshot.coverage.reachesNewest)
    #expect(!snapshot.coverage.reachesOldest && snapshot.coverage.canLoadOlderFromLocal)
  }

  @Test @MainActor
  func liveAddLocalSendAckEditAndDeletePublishWithTheirReasons() async throws {
    let fixture = try await RowFixture()
    let model = fixture.model(rows: Array(fixture.messages[89 ... 99]))
    defer { model.dispose() }
    let recorder = Recorder(model)

    let incoming = try fixture.insert(messageId: 101, date: 101)
    fixture.publisher.publisher.send(.add(.init(messages: [incoming], peer: fixture.peer)))
    #expect(recorder.last?.snapshot.reason == .liveAdd)
    #expect(recorder.last?.diff.insertions.map(\.id) == [.message(incoming.id)])
    // The existing change set is still delivered.
    guard case .added? = recorder.changeSets.last else { Issue.record("no .added change set"); return }

    let pending = try fixture.insert(messageId: -5, date: 102, out: true, status: .sending)
    fixture.publisher.publisher.send(.add(.init(messages: [pending], peer: fixture.peer)))
    #expect(recorder.last?.snapshot.reason == .localSend)

    let acked = try fixture.acknowledge(pending, as: 102)
    #expect(acked.id == pending.id)
    fixture.publisher.publisher.send(.update(.init(message: acked, animated: true, peer: fixture.peer)))
    let ack = try #require(recorder.last)
    #expect(ack.snapshot.reason == .sendAck)
    #expect(ack.diff.insertions.isEmpty && ack.diff.removals.isEmpty)
    #expect(ack.diff.updates.map(\.id) == [.message(pending.id)])

    var edited = incoming
    edited.message.text = "edited"
    fixture.publisher.publisher.send(.update(.init(message: edited, animated: true, peer: fixture.peer)))
    #expect(recorder.last?.snapshot.reason == .liveUpdate)
    #expect(recorder.last?.diff.updates.map(\.id) == [.message(incoming.id)])

    fixture.publisher.messagesDeleted(messageIds: [101], peer: fixture.peer)
    #expect(recorder.last?.snapshot.reason == .delete)
    #expect(recorder.last?.diff.removals.map(\.id) == [.message(incoming.id)])
    // Revisions increase by one per publication.
    #expect(recorder.updates.map(\.snapshot.revision) == Array(2 ... 6).map(UInt64.init))
  }

  @Test @MainActor
  func anAddOutOfOrderIsSortedInTheRows() async throws {
    let fixture = try await RowFixture()
    let model = fixture.model(rows: Array(fixture.messages[89 ... 99]))
    defer { model.dispose() }
    let recorder = Recorder(model)
    // Arrives after newer messages; the view model appends it at the end.
    let late = try fixture.insert(messageId: 102, date: 95.5)
    fixture.publisher.publisher.send(.add(.init(messages: [late], peer: fixture.peer)))
    #expect(model.messages.last?.id == late.id)
    let ids = Self.messageIDs(recorder.last?.snapshot)
    #expect(ids.firstIndex(of: 102) == ids.firstIndex(of: 95)! + 1)
  }

  @Test @MainActor
  func reloadPublishesARefreshWithAnEmptyDiffWhenNothingChanged() async throws {
    let fixture = try await RowFixture()
    // The latest window a reload reads at the bottom.
    let latest = Array(fixture.messages.suffix(MessagesProgressiveViewModel.defaultInitialLimit()))
    let model = fixture.model(rows: latest)
    defer { model.dispose() }
    let recorder = Recorder(model)
    fixture.publisher.messagesReload(peer: fixture.peer, animated: false)
    try await recorder.wait(for: .refresh)
    let refresh = try #require(recorder.updates.first { $0.snapshot.reason == .refresh })
    #expect(refresh.diff.isEmpty)
    guard case .reload? = recorder.changeSets.last else { Issue.record("no .reload change set"); return }
  }

  @Test @MainActor
  func pagesPublishOlderAndNewer() async throws {
    let fixture = try await RowFixture()
    let model = fixture.model(rows: Array(fixture.messages[49 ... 59]))
    defer { model.dispose() }
    let recorder = Recorder(model)
    #expect(await model.loadBatchAsync(at: .older))
    let older = try #require(recorder.updates.first { $0.snapshot.reason == .olderPage })
    #expect(!older.diff.insertions.isEmpty && older.diff.removals.isEmpty)
    // Above the existing rows, under the day separator they share.
    #expect(older.diff.insertions.map(\.index) == Array(1 ... older.diff.insertions.count))
    #expect(await model.loadBatchAsync(at: .newer))
    let newer = try #require(recorder.updates.first { $0.snapshot.reason == .newerPage })
    #expect(!newer.diff.insertions.isEmpty && newer.diff.removals.isEmpty)
    #expect(Self.messageIDs(newer.snapshot) == model.messages.map(\.message.messageId).sorted())
    model.loadBatch(at: .older)
    #expect(recorder.last?.snapshot.reason == .olderPage)
  }

  @Test @MainActor
  func jumpsPublishTheirTargets() async throws {
    let fixture = try await RowFixture()
    let model = fixture.model(rows: Array(fixture.messages[89 ... 99]))
    defer { model.dispose() }
    let recorder = Recorder(model)
    #expect(model.loadLocalWindowAroundMessage(messageId: 30))
    #expect(recorder.last?.snapshot.reason == .jump(.message(30)))
    let around = Self.messageIDs(recorder.last?.snapshot)
    #expect(around.contains(30))
    #expect(try await model.loadLatestWindowAsync())
    #expect(recorder.last?.snapshot.reason == .jump(.latest))
    let latest = Self.messageIDs(recorder.last?.snapshot)
    #expect(latest.last == 100)
  }

  @Test @MainActor
  func unreadWindowPublishesAJumpAndPlacesTheLine() async throws {
    let fixture = try await RowFixture()
    let model = fixture.model(rows: Array(fixture.messages[89 ... 99]))
    defer { model.dispose() }
    let recorder = Recorder(model)
    guard try await model.loadUnreadOpeningWindowAsync(boundary: 40) else {
      Issue.record("the fixture cache could not open at the unread line")
      return
    }
    let jump = try #require(recorder.last)
    #expect(jump.snapshot.reason == .jump(.unreadLine(boundary: 40)))
    #expect(jump.snapshot.unreadLineMessageId == 41)
    #expect(model.rowFeed.unreadLine?.pinnedMessageId == 41)
  }

  @Test @MainActor
  func collapsedHistoryThroughTheSectionedModelIsAPresentationChange() async throws {
    let fixture = try await RowFixture()
    let sectioned = MessagesSectionedViewModel(
      peer: fixture.peer, initialState: fixture.initialState(rows: Array(fixture.messages[89 ... 99])),
      collapsedMaxId: 92, database: fixture.database, publisher: fixture.publisher
    )
    defer { sectioned.dispose() }
    let initial = try #require(sectioned.rowFeed.snapshot)
    #expect(initial.rows.contains { $0.id == .collapsedHistory })
    #expect(Self.messageIDs(initial).first == 93)
    sectioned.setCollapsedMaxId(nil)
    let after = try #require(sectioned.rowFeed.snapshot)
    #expect(after.reason == .presentation)
    #expect(Self.messageIDs(after).first == 90)
    #expect(!after.rows.contains { $0.id == .collapsedHistory })
  }

  /// The view model replaces only the edited row; rows quoting it keep their
  /// embedded copy. The change hint therefore skips nothing a full comparison
  /// would find.
  @Test @MainActor
  func editingARepliedToMessageGivesTheSameRowsAsAFullComparison() async throws {
    let fixture = try await RowFixture()
    let reply = try fixture.insertReply(messageId: 101, date: 101, to: 95)
    #expect(reply.repliedToMessage?.message.messageId == 95)
    let model = fixture.model(rows: Array(fixture.messages[89 ... 99]) + [reply])
    defer { model.dispose() }
    let recorder = Recorder(model)
    let before = try #require(model.rowFeed.snapshot)
    var edited = fixture.messages[94]
    edited.message.text = "edited original"
    fixture.publisher.publisher.send(.update(.init(message: edited, animated: true, peer: fixture.peer)))
    let hinted = try #require(recorder.last?.snapshot)
    let output = ChatRowBuilder.build(.init(
      messages: model.messages, chatKind: .group, reachesOldest: hinted.coverage.reachesOldest,
      calendar: model.rowFeed.calendar
    ))
    let full = ChatRowSnapshot.next(after: before, rows: output.rows, reason: .liveUpdate, coverage: hinted.coverage)
    #expect(hinted.rows == full.rows)
    #expect(recorder.last?.diff.updates.map(\.id) == [.message(edited.id)])
    // The quoting row still carries the original text: the view model's data, not the projection.
    let quoting = model.messages.first { $0.id == reply.id }
    #expect(quoting?.repliedToMessage?.message.text == "Fixture")
  }

  @Test @MainActor
  func aFeedNobodyTurnedOnBuildsOnlyWhenRead() async throws {
    let fixture = try await RowFixture()
    let model = fixture.model(rows: Array(fixture.messages[89 ... 99]))
    defer { model.dispose() }
    var sent = 0
    let cancellable = model.rowFeed.updates.sink { _ in sent += 1 }
    defer { cancellable.cancel() }
    let incoming = try fixture.insert(messageId: 101, date: 101)
    fixture.publisher.publisher.send(.add(.init(messages: [incoming], peer: fixture.peer)))
    #expect(sent == 0)
    // The first read builds once, as the opening, with the rows as they are now.
    let first = try #require(model.rowFeed.snapshot)
    #expect(first.revision == 1 && first.reason == .initialOpen(.latest))
    #expect(Self.messageIDs(first).last == 101)
    fixture.publisher.messagesDeleted(messageIds: [101], peer: fixture.peer)
    let second = try #require(model.rowFeed.snapshot)
    #expect(second.revision == 2 && second.reason == .delete)
    #expect(sent == 2)
  }

  @Test @MainActor
  func updatesForAnotherChatPublishNothing() async throws {
    let fixture = try await RowFixture()
    let model = fixture.model(rows: Array(fixture.messages[89 ... 99]))
    defer { model.dispose() }
    let recorder = Recorder(model)
    fixture.publisher.publisher.send(.add(.init(messages: [fixture.messages[0]], peer: .thread(id: 2))))
    #expect(recorder.updates.isEmpty)
  }
}

private struct RowFixture {
  let database: AppDatabase
  let publisher: MessagesPublisher
  let messages: [FullMessage]
  let peer = Peer.thread(id: 1)

  @MainActor init(messageCount: Int64 = 100) async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    database = try AppDatabase(queue)
    publisher = MessagesPublisher(database: database)
    messages = try await queue.write { db in
      try User(id: 1, email: nil, firstName: "Row fixture").insert(db)
      try User(id: 2, email: nil, firstName: "Other").insert(db)
      try Chat(
        id: 1, date: Date(timeIntervalSince1970: 1), type: .thread, title: "Rows", spaceId: nil,
        lastMsgId: messageCount
      ).insert(db)
      for id in Int64(1) ... messageCount {
        var message = Message(
          messageId: id, fromId: 2, date: Date(timeIntervalSince1970: Double(id)), text: "Fixture",
          peerUserId: nil, peerThreadId: 1, chatId: 1
        )
        try message.saveMessage(db)
      }
      try MessageHistoryCoverageStore.subtract(
        db, chatId: 1, lowerId: 1, upperId: MessageHistoryHole.positiveMessageIDMax
      )
      return try FullMessage.queryRequest(currentUserId: 1).order(Column("messageId").asc).fetchAll(db)
    }
  }

  func insert(
    messageId: Int64, date: Double, out: Bool = false, status: MessageSendingStatus? = nil
  ) throws -> FullMessage {
    try database.dbWriter.write { db in
      var message = Message(
        messageId: messageId, randomId: messageId < 0 ? -messageId : nil, fromId: out ? 1 : 2,
        date: Date(timeIntervalSince1970: date), text: "Live", peerUserId: nil, peerThreadId: 1, chatId: 1,
        out: out, status: status
      )
      try message.saveMessage(db)
      return try #require(
        try FullMessage.queryRequest(currentUserId: 1).filter(Column("messageId") == messageId).fetchOne(db)
      )
    }
  }

  func insertReply(messageId: Int64, date: Double, to repliedTo: Int64) throws -> FullMessage {
    try database.dbWriter.write { db in
      var message = Message(
        messageId: messageId, fromId: 2, date: Date(timeIntervalSince1970: date), text: "Reply",
        peerUserId: nil, peerThreadId: 1, chatId: 1, repliedToMessageId: repliedTo
      )
      try message.saveMessage(db)
      return try #require(
        try FullMessage.queryRequest(currentUserId: 1).filter(Column("messageId") == messageId).fetchOne(db)
      )
    }
  }

  /// The server confirms a send: the same local row gains its server id.
  func acknowledge(_ pending: FullMessage, as messageId: Int64) throws -> FullMessage {
    try database.dbWriter.write { db in
      try Message.filter(Column("globalId") == pending.id).updateAll(
        db, Column("messageId").set(to: messageId), Column("status").set(to: MessageSendingStatus.sent.rawValue)
      )
      return try #require(try FullMessage.queryRequest(currentUserId: 1).filter(id: pending.id).fetchOne(db))
    }
  }

  @MainActor func initialState(
    rows: [FullMessage], openAnchor: ChatOpenAnchor = .latest, unreadBoundary: Int64? = nil
  ) -> MessagesProgressiveViewModel.InitialState {
    let metadata = (try? database.reader.read { db in
      try MessagesProgressiveViewModel.loadedWindowMetadata(db, peer: peer, messages: rows)
    }) ?? .init(messages: rows, holes: [])
    return .init(
      messages: rows, threadAnchor: .resolved(nil), loadedWindowMetadata: metadata,
      publicationRevision: publisher.publicationRevision(for: peer),
      openAnchor: openAnchor, unreadBoundary: unreadBoundary
    )
  }

  @MainActor func model(
    rows: [FullMessage], openAnchor: ChatOpenAnchor = .latest, unreadBoundary: Int64? = nil
  ) -> MessagesProgressiveViewModel {
    MessagesProgressiveViewModel(
      peer: peer,
      initialState: initialState(rows: rows, openAnchor: openAnchor, unreadBoundary: unreadBoundary),
      database: database, publisher: publisher, currentUserId: 1
    )
  }
}
