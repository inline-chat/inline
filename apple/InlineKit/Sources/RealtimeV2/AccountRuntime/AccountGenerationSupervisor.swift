import Foundation

/// A session fence for work that must not outlive the authenticated account that created it.
///
/// This is an exploration seam, not a wired production runtime. It makes the two missing
/// invariants concrete: every long-lived child has an owner, and account replacement does not
/// return until the previous generation has been cancelled and joined.
public struct AccountGeneration: Hashable, Sendable {
  public let accountID: Int64
  public let epoch: UInt64

  public init(accountID: Int64, epoch: UInt64) {
    self.accountID = accountID
    self.epoch = epoch
  }
}

public struct AccountRuntimeSnapshot: Equatable, Sendable {
  public let generation: AccountGeneration?
  public let ownedChildCount: Int
  public let cleanupCount: Int
}

public actor AccountGenerationSupervisor {
  private struct OwnedChild: Sendable {
    let generation: AccountGeneration
    let task: Task<Void, Never>
  }

  private struct Cleanup: Sendable {
    let generation: AccountGeneration
    let label: String
    let operation: @Sendable () async -> Void
  }

  private var nextEpoch: UInt64 = 0
  private var currentGeneration: AccountGeneration?
  private var children: [UUID: OwnedChild] = [:]
  private var cleanups: [(UUID, Cleanup)] = []
  private var transitionInProgress = false
  private var transitionWaiters: [CheckedContinuation<Void, Never>] = []

  public init() {}

  /// Starts a fresh generation, even when the account ID is unchanged.
  /// The old generation is fully drained before the new token becomes observable.
  public func begin(accountID: Int64) async -> AccountGeneration {
    await acquireTransition()
    defer { releaseTransition() }
    await endCurrentGeneration()
    nextEpoch &+= 1
    let generation = AccountGeneration(accountID: accountID, epoch: nextEpoch)
    currentGeneration = generation
    return generation
  }

  /// Adds a task to the generation's cancellation/join set.
  /// A stale caller is rejected before its operation is started.
  @discardableResult
  public func startChild(
    for generation: AccountGeneration,
    operation: @escaping @Sendable () async -> Void
  ) -> Bool {
    guard currentGeneration == generation else { return false }
    children[UUID()] = OwnedChild(
      generation: generation,
      task: Task(operation: operation)
    )
    return true
  }

  /// Registers teardown after child cancellation. LIFO order mirrors nested resource acquisition.
  @discardableResult
  public func registerCleanup(
    for generation: AccountGeneration,
    label: String,
    operation: @escaping @Sendable () async -> Void
  ) -> Bool {
    guard currentGeneration == generation else { return false }
    cleanups.append((UUID(), Cleanup(generation: generation, label: label, operation: operation)))
    return true
  }

  /// Runs a non-suspending commit only while the token is current, avoiding a check/use await gap.
  public func commitIfCurrent<Result: Sendable>(
    _ generation: AccountGeneration,
    _ operation: @Sendable () throws -> Result
  ) rethrows -> Result? {
    guard currentGeneration == generation else { return nil }
    return try operation()
  }

  public func isCurrent(_ generation: AccountGeneration) -> Bool {
    currentGeneration == generation
  }

  public func snapshot() -> AccountRuntimeSnapshot {
    AccountRuntimeSnapshot(
      generation: currentGeneration,
      ownedChildCount: children.values.count { $0.generation == currentGeneration },
      cleanupCount: cleanups.count { $0.1.generation == currentGeneration }
    )
  }

  public func logout() async {
    await acquireTransition()
    defer { releaseTransition() }
    await endCurrentGeneration()
  }

  private func acquireTransition() async {
    while transitionInProgress {
      await withCheckedContinuation { continuation in
        transitionWaiters.append(continuation)
      }
    }
    transitionInProgress = true
  }

  private func releaseTransition() {
    transitionInProgress = false
    guard !transitionWaiters.isEmpty else { return }
    transitionWaiters.removeFirst().resume()
  }

  private func endCurrentGeneration() async {
    guard let ending = currentGeneration else { return }

    // Fence stale callbacks before cancellation can suspend and allow actor reentrancy.
    currentGeneration = nil

    let endingChildren = children.filter { $0.value.generation == ending }
    for (_, child) in endingChildren {
      child.task.cancel()
    }
    for (_, child) in endingChildren {
      await child.task.value
    }
    for (id, _) in endingChildren {
      children[id] = nil
    }

    let endingCleanups = cleanups.filter { $0.1.generation == ending }
    cleanups.removeAll { $0.1.generation == ending }
    for (_, cleanup) in endingCleanups.reversed() {
      await cleanup.operation()
    }
  }
}

/// Persistence is scoped to account identity, while generation tokens fence in-memory work.
/// Keeping the two concepts separate permits safe relaunch recovery without cross-account replay.
public struct AccountPersistenceScope: Equatable, Sendable {
  public let accountID: Int64

  public init(accountID: Int64) {
    self.accountID = accountID
  }

  public var relativeDirectory: String {
    "accounts/\(accountID)"
  }
}
