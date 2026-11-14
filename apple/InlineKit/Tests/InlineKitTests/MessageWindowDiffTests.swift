import Foundation
import GRDB
@testable import InlineKit
import Testing

@Suite("Message window diff")
struct MessageWindowDiffTests {
  @Test func identicalWindowIsUnchanged() {
    let rows = (1 ... 5).map { makeMessage(id: $0) }
    #expect(MessageWindowDiff(from: rows, to: rows) == .unchanged)
    #expect(MessageWindowDiff(from: [], to: []) == .unchanged)
  }

  @Test func editedRowsAreUpdated() {
    let old = (1 ... 5).map { makeMessage(id: $0) }
    var new = old
    new[2].message.text = "edited"
    new[4].reactions = [FullReaction(reaction: Reaction(messageId: 5, userId: 1, emoji: "👍", date: .now, chatId: 1))]
    #expect(MessageWindowDiff(from: old, to: new) == .updated([3, 5]))
  }

  @Test func additionsAroundUnchangedRowsAreInserted() {
    let all = (1 ... 6).map { makeMessage(id: $0) }
    #expect(MessageWindowDiff(from: Array(all[0 ... 3]), to: all) == .inserted([5, 6]))
    #expect(MessageWindowDiff(from: Array(all[2 ... 5]), to: all) == .inserted([1, 2]))
  }

  @Test func removalsAroundUnchangedRowsAreRemoved() {
    let all = (1 ... 6).map { makeMessage(id: $0) }
    #expect(MessageWindowDiff(from: all, to: Array(all[0 ... 3])) == .removed([5, 6]))
    #expect(MessageWindowDiff(from: all, to: all.filter { $0.id != 3 }) == .removed([3]))
  }

  @Test func mixedOrReorderedChangesAreReplaced() {
    let all = (1 ... 6).map { makeMessage(id: $0) }
    // The latest window slid: older rows dropped, newer rows added.
    #expect(MessageWindowDiff(from: Array(all[0 ... 3]), to: Array(all[2 ... 5])) == .replaced)
    // An addition together with an edit of a kept row.
    var edited = all
    edited[0].message.text = "edited"
    #expect(MessageWindowDiff(from: Array(all[0 ... 3]), to: edited) == .replaced)
    // Same rows, different order.
    #expect(MessageWindowDiff(from: all, to: all.reversed()) == .replaced)
  }

  /// The history refetch after a chat opens saves the same rows again and asks for a reload.
  /// The reloaded window must compare equal to the one shown so the list can skip the update.
  @Test @MainActor
  func reloadAfterResavingIdenticalHistoryIsUnchanged() async throws {
    let fixture = try await Fixture()
    let model = fixture.latestModel()
    defer { model.dispose() }
    let shown = model.messages
    #expect(!shown.isEmpty)

    try await fixture.resave(shown)
    try await reload(model, fixture)
    #expect(MessageWindowDiff(from: shown, to: model.messages) == .unchanged)

    try await fixture.resave(shown) { $0.text = "edited" }
    try await reload(model, fixture)
    #expect(MessageWindowDiff(from: shown, to: model.messages) == .updated(Set(shown.map(\.id))))
  }

  @MainActor
  private func reload(_ model: MessagesProgressiveViewModel, _ fixture: Fixture) async throws {
    var reloaded = false
    model.observe { if case .reload = $0 { reloaded = true } }
    fixture.publisher.messagesReload(peer: .thread(id: 1), animated: false)
    for _ in 0 ..< 200 where !reloaded {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(reloaded)
  }
}

private func makeMessage(id: Int64) -> FullMessage {
  var message = Message(
    messageId: id, fromId: 1, date: Date(timeIntervalSince1970: Double(id)), text: "hi",
    peerUserId: nil, peerThreadId: 1, chatId: 1
  )
  message.globalId = id
  return FullMessage(senderInfo: nil, message: message, reactions: [], repliedToMessage: nil, attachments: [])
}

private struct Fixture {
  let database: AppDatabase
  let queue: DatabaseQueue
  let publisher: MessagesPublisher

  @MainActor init(messageCount: Int64 = 40) async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    self.queue = queue
    database = try AppDatabase(queue)
    publisher = MessagesPublisher(database: database)
    try await queue.write { db in
      try User(id: 1, email: nil, firstName: "Diff fixture").insert(db)
      try Chat(
        id: 1, date: Date(timeIntervalSince1970: 1), type: .thread, title: "Diff", spaceId: nil,
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
        db, chatId: 1, lowerId: 1, upperId: MessageHistoryHole.positiveMessageIDMax
      )
    }
  }

  /// A model on the latest window, the way a chat opens at the bottom.
  @MainActor func latestModel() -> MessagesProgressiveViewModel {
    MessagesProgressiveViewModel(peer: .thread(id: 1), database: database, publisher: publisher, currentUserId: 1)
  }

  /// Writes the rows again, as a history fetch does with what it got from the server.
  func resave(_ rows: [FullMessage], _ change: @escaping @Sendable (inout Message) -> Void = { _ in }) async throws {
    let messages = rows.map(\.message)
    try await queue.write { db in
      for var message in messages {
        change(&message)
        try message.saveMessage(db)
      }
    }
  }
}
