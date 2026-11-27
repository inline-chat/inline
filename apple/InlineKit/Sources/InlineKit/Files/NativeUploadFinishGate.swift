import Foundation
import os

/// A one-way latch an upload awaits before its finish. Open it at Send; cancel the waiting upload
/// (its task) to discard it instead.
public final class NativeUploadFinishGate: Sendable {
  private struct State {
    var isOpen = false
    var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  public init() {}

  public var isOpen: Bool { state.withLock { $0.isOpen } }

  public func open() {
    let waiters = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
      guard !state.isOpen else { return [] }
      state.isOpen = true
      defer { state.waiters.removeAll() }
      return Array(state.waiters.values)
    }
    for waiter in waiters { waiter.resume() }
  }

  /// Returns once the gate is open; throws `CancellationError` when the waiting task is canceled.
  public func wait() async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let resumeNow: Bool? = state.withLock { state in
          if state.isOpen { return true }
          if Task.isCancelled { return false }
          state.waiters[id] = continuation
          return nil
        }
        switch resumeNow {
        case true?: continuation.resume()
        case false?: continuation.resume(throwing: CancellationError())
        case nil: break
        }
      }
    } onCancel: {
      let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
      waiter?.resume(throwing: CancellationError())
    }
  }
}
