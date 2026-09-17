@testable import InlineKit
import Synchronization
import Testing

@Suite("WebSocket ping lifetime", .timeLimit(.minutes(1)))
struct WebSocketPingTests {
  private enum Failure: Error, Equatable {
    case timeout
    case pong
  }

  @Test("A synchronous pong and duplicate callbacks complete once")
  func synchronousPong() async throws {
    try await WebSocketPing.perform(timeout: .seconds(30), timeoutError: Failure.timeout) { callback in
      callback(nil)
      callback(Failure.pong)
      callback(nil)
    }
  }

  @Test("Pong failures retain their original error")
  func pongFailure() async {
    await #expect(throws: Failure.pong) {
      try await WebSocketPing.perform(timeout: .seconds(30), timeoutError: Failure.timeout) { callback in
        callback(Failure.pong)
      }
    }
  }

  @Test("A missing pong cannot keep the timeout task group alive")
  func timeoutWithoutCallback() async {
    await #expect(throws: Failure.timeout) {
      try await WebSocketPing.perform(timeout: .milliseconds(20), timeoutError: Failure.timeout) { _ in }
    }
  }

  @Test("Callbacks after timeout are harmless")
  func latePong() async {
    let pending = PendingPong()
    await #expect(throws: Failure.timeout) {
      try await WebSocketPing.perform(timeout: .milliseconds(20), timeoutError: Failure.timeout, send: pending.send)
    }
    pending.reply(nil)
    pending.reply(Failure.pong)
  }

  @Test("Cancellation releases a registered ping without a pong")
  func cancellation() async {
    let pending = PendingPong()
    let task = Task {
      try await WebSocketPing.perform(timeout: .seconds(30), timeoutError: Failure.timeout, send: pending.send)
    }
    for await _ in pending.started { break }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    pending.reply(nil)
  }

  @Test("Cancellation before registration still resumes the waiter")
  func alreadyCancelled() async {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await WebSocketPing.perform(timeout: .seconds(30), timeoutError: Failure.timeout) { _ in }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test("Concurrent pong and cancellation never double resume", arguments: 0 ..< 100)
  func concurrentCompletion(_ iteration: Int) async {
    let pending = PendingPong()
    let task = Task {
      try await WebSocketPing.perform(timeout: .seconds(30), timeoutError: Failure.timeout, send: pending.send)
    }
    for await _ in pending.started { break }
    await withTaskGroup(of: Void.self) { group in
      group.addTask { task.cancel() }
      group.addTask { pending.reply(nil) }
      group.addTask { pending.reply(nil) }
    }
    do { try await task.value } catch {
      #expect(error is CancellationError)
    }
  }

  private final class PendingPong: Sendable {
    private let callback = Mutex<(@Sendable ((any Error)?) -> Void)?>(nil)
    private let signal = AsyncStream<Void>.makeStream()
    var started: AsyncStream<Void> { signal.stream }

    func send(_ callback: @escaping @Sendable ((any Error)?) -> Void) {
      self.callback.withLock { $0 = callback }
      signal.continuation.yield(())
      signal.continuation.finish()
    }

    func reply(_ error: (any Error)?) {
      let reply = callback.withLock { $0 }
      reply?(error)
    }
  }
}
