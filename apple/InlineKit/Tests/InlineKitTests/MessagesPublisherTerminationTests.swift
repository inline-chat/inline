import Foundation
import GRDB
import Testing

@testable import InlineKit

@Suite("MessagesPublisher termination")
@MainActor
struct MessagesPublisherTerminationTests {
  @Test("termination closes hydration admission and drains a read already in flight")
  func closesAdmissionAndDrains() async throws {
    let queue = try DatabaseQueue()
    let database = try AppDatabase(queue)
    let (started, startedContinuation) = AsyncStream<Void>.makeStream()
    let blocker = AdmittedReadGate(started: startedContinuation)

    let publisher = MessagesPublisher(database: database)
    #if os(iOS)
    let activeChat = publisher.activateChat(peer: .thread(id: 1))
    defer { publisher.deactivateChat(activeChat) }
    #endif
    let message = Message(
      messageId: 1,
      fromId: 1,
      date: Date(),
      text: "test",
      peerUserId: nil,
      peerThreadId: 1,
      chatId: 1
    )
    let hydration = Task { @MainActor in
      await publisher.messageAdded(message: message, peer: .thread(id: 1), read: {
        let snapshot = try await queue.read { db in
          try FullMessage.queryRequest().filter(Message.Columns.chatId == 1 && Message.Columns.messageId == 1).fetchOne(db)
        }
        await blocker.hold()
        return snapshot
      })
    }

    var startedIterator = started.makeAsyncIterator()
    let startDeadline = Task {
      try? await Task.sleep(for: .seconds(3))
      startedContinuation.finish()
      await blocker.release()
    }
    defer { startDeadline.cancel() }
    try #require(await startedIterator.next() != nil, "Hydration must start a database read")
    publisher.closeAdmissionForTermination()

    let drainState = CompletionState()
    let drain = Task { @MainActor in
      await publisher.waitForAdmittedDatabaseReadsForTermination()
      await drainState.finish()
    }
    await Task.yield()
    #expect(await drainState.isFinished == false)

    await publisher.messageUpdated(message: message, peer: .thread(id: 1), animated: false, read: {
      Issue.record("Closed admission must not start another projection read")
      return nil
    })
    #expect(await blocker.readCount == 1)

    await blocker.release()
    await hydration.value
    await drain.value
    #expect(await drainState.isFinished)
  }
}

private actor CompletionState {
  private(set) var isFinished = false
  func finish() { isFinished = true }
}

// Holds the actual SQL result after GRDB releases its transaction. No SQL
// semaphore/timeout can silently admit extra work under unrelated test load.
private actor AdmittedReadGate {
  private let started: AsyncStream<Void>.Continuation
  private var waiter: CheckedContinuation<Void, Never>?
  private(set) var readCount = 0
  init(started: AsyncStream<Void>.Continuation) { self.started = started }
  func hold() async {
    readCount += 1
    await withCheckedContinuation { continuation in
      waiter = continuation
      started.yield(())
      started.finish()
    }
  }
  func release() { waiter?.resume(); waiter = nil }
}
