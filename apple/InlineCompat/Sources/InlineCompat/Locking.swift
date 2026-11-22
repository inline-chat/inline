import Foundation
import os

// MARK: - Mutex

/// Drop-in for `Synchronization.Mutex` (iOS 18, macOS 15).
///
/// Same spelling at call sites (`Mutex(value)`, `withLock`, `withLockIfAvailable`), so adopting
/// the native type later means swapping `import InlineCompat` for `import Synchronization`.
/// It is a class rather than a `~Copyable` struct, so it can be stored with `let` and shared the
/// same way. Backed by `os_unfair_lock`, which is what the native Mutex uses on Darwin.
///
/// Removable when the deployment target reaches iOS 18.
public final class Mutex<Value>: @unchecked Sendable {
  private let lock: UnsafeMutablePointer<os_unfair_lock>
  private var value: Value

  public init(_ initialValue: Value) {
    lock = .allocate(capacity: 1)
    lock.initialize(to: os_unfair_lock())
    value = initialValue
  }

  deinit {
    lock.deinitialize(count: 1)
    lock.deallocate()
  }

  @inlinable
  public func withLock<Result, E: Error>(_ body: (inout Value) throws(E) -> Result) throws(E) -> Result {
    _lock()
    defer { _unlock() }
    return try body(&_value)
  }

  /// Runs `body` only if the lock is free right now; returns nil otherwise.
  @inlinable
  public func withLockIfAvailable<Result, E: Error>(
    _ body: (inout Value) throws(E) -> Result
  ) throws(E) -> Result? {
    guard _tryLock() else { return nil }
    defer { _unlock() }
    return try body(&_value)
  }

  @usableFromInline func _lock() { os_unfair_lock_lock(lock) }
  @usableFromInline func _unlock() { os_unfair_lock_unlock(lock) }
  @usableFromInline func _tryLock() -> Bool { os_unfair_lock_trylock(lock) }
  @usableFromInline var _value: Value {
    _read { yield value }
    _modify { yield &value }
  }
}

// MARK: - Atomic

/// Memory orderings accepted by the `Atomic` backport. The backport is lock-based, so every
/// ordering is at least as strong as requested; the parameter exists for call-site parity with
/// `Synchronization.Atomic`.
public struct CompatAtomicLoadOrdering: Sendable {
  public static let relaxed = Self()
  public static let acquiring = Self()
  public static let sequentiallyConsistent = Self()
}

public struct CompatAtomicStoreOrdering: Sendable {
  public static let relaxed = Self()
  public static let releasing = Self()
  public static let sequentiallyConsistent = Self()
}

public struct CompatAtomicUpdateOrdering: Sendable {
  public static let relaxed = Self()
  public static let acquiring = Self()
  public static let releasing = Self()
  public static let acquiringAndReleasing = Self()
  public static let sequentiallyConsistent = Self()
}

/// Drop-in for `Synchronization.Atomic` (iOS 18, macOS 15) for the operations Inline uses.
/// Removable when the deployment target reaches iOS 18.
public final class Atomic<Value>: @unchecked Sendable {
  private let storage: Mutex<Value>

  public init(_ initialValue: Value) {
    storage = Mutex(initialValue)
  }

  public func load(ordering: CompatAtomicLoadOrdering = .sequentiallyConsistent) -> Value {
    storage.withLock { $0 }
  }

  public func store(_ desired: Value, ordering: CompatAtomicStoreOrdering = .sequentiallyConsistent) {
    storage.withLock { $0 = desired }
  }

  @discardableResult
  public func exchange(
    _ desired: Value,
    ordering: CompatAtomicUpdateOrdering = .sequentiallyConsistent
  ) -> Value {
    storage.withLock { value in
      let old = value
      value = desired
      return old
    }
  }
}

extension Atomic where Value: Equatable {
  public func compareExchange(
    expected: Value,
    desired: Value,
    ordering: CompatAtomicUpdateOrdering = .sequentiallyConsistent
  ) -> (exchanged: Bool, original: Value) {
    storage.withLock { value in
      let original = value
      guard original == expected else { return (false, original) }
      value = desired
      return (true, original)
    }
  }
}

extension Atomic where Value: FixedWidthInteger {
  @discardableResult
  public func wrappingAdd(
    _ operand: Value,
    ordering: CompatAtomicUpdateOrdering = .sequentiallyConsistent
  ) -> (oldValue: Value, newValue: Value) {
    storage.withLock { value in
      let old = value
      value = value &+ operand
      return (old, value)
    }
  }

  @discardableResult
  public func wrappingSubtract(
    _ operand: Value,
    ordering: CompatAtomicUpdateOrdering = .sequentiallyConsistent
  ) -> (oldValue: Value, newValue: Value) {
    storage.withLock { value in
      let old = value
      value = value &- operand
      return (old, value)
    }
  }
}

extension Atomic where Value == Bool {
  @discardableResult
  public func logicalOr(
    _ operand: Bool,
    ordering: CompatAtomicUpdateOrdering = .sequentiallyConsistent
  ) -> (oldValue: Bool, newValue: Bool) {
    storage.withLock { value in
      let old = value
      value = value || operand
      return (old, value)
    }
  }
}
