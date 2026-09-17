import Foundation
import Synchronization

/// Bounds the lifetime of a callback-based ping even if URLSession never calls back.
enum WebSocketPing {
  static func perform(
    timeout: Duration,
    timeoutError: any Error,
    send: @escaping @Sendable (@escaping @Sendable ((any Error)?) -> Void) -> Void
  ) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      defer { group.cancelAll() }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw timeoutError
      }
      group.addTask {
        let completion = Completion()
        try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { continuation in
            guard completion.install(continuation) else { return }
            send { error in
              completion.finish(error.map { .failure($0) } ?? .success(()))
            }
          }
        } onCancel: {
          completion.finish(.failure(CancellationError()))
        }
      }
      try await group.next()
      try Task.checkCancellation()
    }
  }

  // Cancellation may happen before registration or race a late pong. Every
  // path owns the same state; resume outside the lock, exactly once.
  private final class Completion: Sendable {
    private enum State {
      case waiting
      case installed(CheckedContinuation<Void, any Error>)
      case finished(Result<Void, any Error>)
    }

    private let state = Mutex<State>(.waiting)

    func install(_ continuation: CheckedContinuation<Void, any Error>) -> Bool {
      let result: Result<Void, any Error>? = state.withLock { state in
        switch state {
        case .waiting:
          state = .installed(continuation)
          return nil
        case let .finished(result):
          return result
        case .installed:
          preconditionFailure("A ping has only one waiter")
        }
      }
      if let result {
        continuation.resume(with: result)
        return false
      }
      return true
    }

    func finish(_ result: Result<Void, any Error>) {
      let continuation: CheckedContinuation<Void, any Error>? = state.withLock { state in
        switch state {
        case .waiting:
          state = .finished(result)
          return nil
        case let .installed(continuation):
          state = .finished(result)
          return continuation
        case .finished:
          return nil
        }
      }
      continuation?.resume(with: result)
    }
  }
}
