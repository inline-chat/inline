import Auth
import Foundation
import GRDB
import InlineProtocol
import RealtimeV2
import Testing

@testable import InlineKit

private typealias Chat = InlineKit.Chat

@Suite("Confirmed chat deletion")
struct DeleteChatTransactionTests {
  private func fixture() throws -> (DatabaseQueue, AppDatabase) {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    try queue.write { db in
      try User(id: 1, email: nil, firstName: "Human").insert(db)
      for id: Int64 in [100, 101, 102] {
        try Chat(id: id, date: Date(timeIntervalSince1970: 1), type: .thread,
          title: "Chat \(id)", spaceId: nil, parentChatId: id == 100 ? nil : 100,
          parentMessageId: id == 100 ? nil : 2).insert(db)
        var message = Message(messageId: 2, fromId: 1, date: Date(timeIntervalSince1970: 2),
          text: "Retain \(id)", peerUserId: nil, peerThreadId: id, chatId: id)
        _ = try message.saveMessage(db)
        try Chat.updateLastMsgId(db, chatId: id, lastMsgId: 2, date: message.date)
        try Dialog(from: ApiDialog(peerId: .thread(id: id), chatId: id, open: true)).insert(db)
        try DbBucketState(bucketType: 1, entityId: -id, date: 10, seq: 4).insert(db)
      }
    }
    return (queue, database)
  }

  private func snapshot(_ queue: DatabaseQueue) throws -> [Chat] {
    try queue.read { try Chat.order(Chat.Columns.id).fetchAll($0) }
  }

  @Test("refusal, unknown outcome and cancellation retain the parent and child links")
  func rejectedParentRemainsIntact() async throws {
    let (queue, _) = try fixture()
    let before = try snapshot(queue)
    let transaction = DeleteChatTransaction(peerId: .thread(id: 100))
    await transaction.optimistic()
    await transaction.failed(error: .rpcError(.with { $0.code = 400; $0.message = "Delete child chats first" }))
    await transaction.commitOutcomeUnknown()
    await transaction.cancelled()
    #expect(try snapshot(queue) == before)
    try await queue.read { (db: Database) throws in
      #expect(try Dialog.fetchCount(db) == 3)
      #expect(try Message.fetchCount(db) == 3)
      #expect(try Chat.fetchOne(db, id: 101)?.parentChatId == 100)
      #expect(try Chat.fetchOne(db, id: 102)?.parentMessageId == 2)
    }
    #expect(transaction.effectiveReconnectReplayPolicy == .neverReplay)
  }

  @Test("confirmed leaf deletion tolerates result-first, push-first and repeated confirmation", arguments: [false, true])
  func confirmedLeafDeletion(pushFirst: Bool) async throws {
    let (queue, database) = try fixture()
    let auth = Auth.mocked(authenticated: false)
    try await auth.saveCredentials(token: "1:delete-test-only", userId: 1)
    let transaction = DeleteChatTransaction(peerId: .thread(id: 101), accountToken: try auth.handle.beginAccountMutation())
    let push = InlineProtocol.UpdateDeleteChat.with { $0.peerID.chat.chatID = 101 }
    if pushFirst { try await queue.write { try push.apply($0) } }
    try await transaction.apply(.deleteChat(.init()), database: database, auth: auth.handle)
    try await queue.write { try push.apply($0) }
    try await transaction.apply(.deleteChat(.init()), database: database, auth: auth.handle)
    try await queue.read { (db: Database) throws in
      #expect(try Chat.fetchOne(db, id: 101) == nil)
      #expect(try Message.filter(Message.Columns.chatId == 101).fetchCount(db) == 0)
      #expect(try Dialog.filter(Dialog.Columns.peerThreadId == 101).fetchCount(db) == 0)
      #expect(try DbBucketState.filter(DbBucketState.Columns.entityId == -101).fetchCount(db) == 0)
      #expect(try Chat.fetchOne(db, id: 100)?.lastMsgId == 2)
      #expect(try Chat.fetchOne(db, id: 102)?.parentChatId == 100)
      #expect(try Message.fetchCount(db) == 2)
      #expect(try Dialog.fetchCount(db) == 2)
    }
  }

  @Test("a confirmation queued behind a writer cannot delete after the account changes")
  func staleQueuedConfirmation() async throws {
    let (queue, database) = try fixture()
    let before = try snapshot(queue)
    let auth = Auth.mocked(authenticated: false)
    try await auth.saveCredentials(token: "1:delete-test-only", userId: 1)
    let transaction = DeleteChatTransaction(peerId: .thread(id: 101), accountToken: try auth.handle.beginAccountMutation())
    let (writerStarted, writerContinuation) = AsyncStream<Void>.makeStream()
    let (admitted, admissionContinuation) = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    let holder = Task.detached {
      try Self.holdWriter(queue, started: writerContinuation, release: release)
    }
    defer { release.signal() }
    var writer = writerStarted.makeAsyncIterator()
    _ = await writer.next()
    let confirmation = Task {
      try await transaction.apply(.deleteChat(.init()), database: database, auth: auth.handle,
        beforeWrite: { admissionContinuation.yield(()); admissionContinuation.finish() })
    }
    var admissions = admitted.makeAsyncIterator()
    _ = await admissions.next()
    try await auth.saveCredentials(token: "2:changed-test-only", userId: 2)
    release.signal()
    try await holder.value
    await #expect(throws: TransactionExecutionError.self) { try await confirmation.value }
    #expect(try snapshot(queue) == before)
  }

  private static func holdWriter(_ queue: DatabaseQueue, started: AsyncStream<Void>.Continuation,
                                 release: DispatchSemaphore) throws {
    try queue.write { _ in
      started.yield(())
      started.finish()
      guard release.wait(timeout: .now() + 5) == .success else {
        throw WriterHoldError.timeout
      }
    }
  }

  private enum WriterHoldError: Error { case timeout }
}
