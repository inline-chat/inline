import Foundation

/// Thread-safe snapshot cache so synchronous callers (DB init, HTTP headers, etc.) can read auth state
/// without `await`.
///
/// Swift can't prove thread-safety here, but all access is protected by a lock.
final class AuthSnapshotCache: @unchecked Sendable {
  private let lock = NSLock()
  private var _snapshot: AuthSnapshot

  init(initial: AuthSnapshot) {
    _snapshot = initial
  }

  func snapshot() -> AuthSnapshot {
    lock.withLock { _snapshot }
  }

  func update(_ snapshot: AuthSnapshot) {
    lock.withLock { _snapshot = snapshot }
  }
}

