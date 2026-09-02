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
    let blocker = StatementBlocker(started: startedContinuation)
    try await queue.write { db in
      db.trace { event in
        guard case let .statement(statement) = event else { return }
        blocker.record(statement.sql)
      }
    }

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
      await publisher.messageAdded(message: message, peer: .thread(id: 1))
    }

    var startedIterator = started.makeAsyncIterator()
    let startDeadline = Task {
      try? await Task.sleep(for: .seconds(3))
      startedContinuation.finish()
    }
    defer { startDeadline.cancel(); blocker.release() }
    try #require(await startedIterator.next() != nil, "Hydration must start a database read")
    publisher.closeAdmissionForTermination()

    let drainState = CompletionState()
    let drain = Task { @MainActor in
      await publisher.waitForAdmittedDatabaseReadsForTermination()
      await drainState.finish()
    }
    await Task.yield()
    #expect(await drainState.isFinished == false)

    await publisher.messageUpdated(message: message, peer: .thread(id: 1), animated: false)
    #expect(blocker.statementCount == 1)

    blocker.release()
    await hydration.value
    await drain.value
    #expect(await drainState.isFinished)
  }
}

private actor CompletionState {
  private(set) var isFinished = false
  func finish() { isFinished = true }
}

private final class StatementBlocker: @unchecked Sendable {
  private let lock = NSLock()
  private let releaseSemaphore = DispatchSemaphore(value: 0)
  private let started: AsyncStream<Void>.Continuation
  private var didBlock = false
  private var count = 0

  init(started: AsyncStream<Void>.Continuation) {
    self.started = started
  }

  var statementCount: Int { lock.withLock { count } }

  func record(_ sql: String) {
    guard sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("SELECT") else { return }
    let shouldBlock = lock.withLock { () -> Bool in
      count += 1
      guard !didBlock else { return false }
      didBlock = true
      return true
    }
    guard shouldBlock else { return }
    started.yield(())
    started.finish()
    _ = releaseSemaphore.wait(timeout: .now() + 5)
  }

  func release() {
    releaseSemaphore.signal()
  }
}
