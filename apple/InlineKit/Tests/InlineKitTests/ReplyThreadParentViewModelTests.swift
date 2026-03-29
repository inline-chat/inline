import Foundation
import GRDB
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("ReplyThreadParentViewModel")
struct ReplyThreadParentViewModelTests {
  private static let childChatId: Int64 = 41
  private static let parentChatId: Int64 = 7
  private static let parentMessageId: Int64 = 99
  private static let senderId: Int64 = 123
  private static let dmUserId: Int64 = 456

  private struct TimeoutError: Error {}

  private func makeInMemoryDB() throws -> (DatabaseQueue, AppDatabase) {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration())
    let database = try AppDatabase(queue)
    return (queue, database)
  }

  private static func seedReplyThreadContext(_ db: Database) throws {
    try User(
      id: senderId,
      email: nil,
      firstName: "Sender",
      lastName: nil,
      username: nil
    ).insert(db)

    try Chat(
      id: parentChatId,
      date: Date(timeIntervalSince1970: 1),
      type: .thread,
      title: "Parent Thread",
      spaceId: nil
    ).insert(db)

    try Chat(
      id: childChatId,
      date: Date(timeIntervalSince1970: 2),
      type: .thread,
      title: "Reply Thread",
      spaceId: nil,
      parentChatId: parentChatId,
      parentMessageId: parentMessageId
    ).insert(db)
  }

  private static func seedReplyThreadDMContext(_ db: Database) throws {
    try User(
      id: dmUserId,
      email: "maya@example.com",
      firstName: "Maya",
      lastName: nil,
      username: "maya"
    ).insert(db)

    try Chat(
      id: parentChatId,
      date: Date(timeIntervalSince1970: 1),
      type: .privateChat,
      title: nil,
      spaceId: nil,
      peerUserId: dmUserId
    ).insert(db)

    try Chat(
      id: childChatId,
      date: Date(timeIntervalSince1970: 2),
      type: .thread,
      title: "Re: Maya",
      spaceId: nil,
      parentChatId: parentChatId,
      parentMessageId: parentMessageId
    ).insert(db)
  }

  private static func makeParentMessage() -> InlineProtocol.Message {
    .with {
      $0.id = parentMessageId
      $0.chatID = parentChatId
      $0.fromID = senderId
      $0.date = 3
      $0.peerID = .with {
        $0.chat.chatID = parentChatId
      }
      $0.message = "anchor"
    }
  }

  @MainActor
  private func waitUntil(
    description: String,
    timeout: Duration = .seconds(1),
    condition: @MainActor @escaping () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout

    while clock.now < deadline {
      if condition() {
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }

    Issue.record("Timed out waiting for \(description)")
    throw TimeoutError()
  }

  @Test("ReplyThreadParentViewModel resolves parent chat and message for reply threads")
  @MainActor
  func parentViewModelResolvesParentContext() async throws {
    let (dbQueue, database) = try makeInMemoryDB()

    try await dbQueue.write { db in
      try Self.seedReplyThreadContext(db)
    }

    let viewModel = ReplyThreadParentViewModel(chatId: Self.childChatId, db: database)

    try await waitUntil(description: "parent chat") {
      viewModel.parentChat?.id == Self.parentChatId && viewModel.parentMessage == nil
    }

    try await dbQueue.write { db in
      _ = try Message.save(db, protocolMessage: Self.makeParentMessage(), publishChanges: false)
    }

    try await waitUntil(description: "parent message") {
      viewModel.parentMessage?.message.messageId == Self.parentMessageId
    }

    #expect(viewModel.parentChat?.id == Self.parentChatId)
    #expect(viewModel.parentMessage?.message.chatId == Self.parentChatId)
    #expect(viewModel.parentMessage?.message.messageId == Self.parentMessageId)
  }

  @Test("ReplyThreadParentViewModel exposes an already-cached parent message immediately")
  @MainActor
  func parentViewModelBootstrapsImmediately() async throws {
    let (dbQueue, database) = try makeInMemoryDB()

    try await dbQueue.write { db in
      try Self.seedReplyThreadContext(db)
      _ = try Message.save(db, protocolMessage: Self.makeParentMessage(), publishChanges: false)
    }

    let viewModel = ReplyThreadParentViewModel(chatId: Self.childChatId, db: database)

    #expect(viewModel.parentChat?.id == Self.parentChatId)
    #expect(viewModel.parentMessage?.message.chatId == Self.parentChatId)
    #expect(viewModel.parentMessage?.message.messageId == Self.parentMessageId)
  }

  @Test("ReplyThreadParentViewModel exposes DM parent title from the parent user")
  @MainActor
  func parentViewModelResolvesDMParentTitle() async throws {
    let (dbQueue, database) = try makeInMemoryDB()

    try await dbQueue.write { db in
      try Self.seedReplyThreadDMContext(db)
    }

    let viewModel = ReplyThreadParentViewModel(chatId: Self.childChatId, db: database)

    try await waitUntil(description: "parent DM title") {
      viewModel.parentTitle == "Maya"
    }

    #expect(viewModel.parentChat?.id == Self.parentChatId)
    #expect(viewModel.parentTitle == "Maya")
  }
}
