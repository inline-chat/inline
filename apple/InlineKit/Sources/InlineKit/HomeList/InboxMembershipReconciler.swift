import Foundation

public enum InboxMembershipIntent: Equatable, Sendable {
  case open
  case close
}

public struct InboxMembershipCanonicalState: Equatable, Sendable {
  public let isOpen: Bool
  public let isPinned: Bool
  public let isArchived: Bool
  public let isChatListHidden: Bool
  public let isUnfollowed: Bool
  public let needsReplyThreadReveal: Bool

  public init(
    isOpen: Bool,
    isPinned: Bool,
    isArchived: Bool,
    isChatListHidden: Bool,
    isUnfollowed: Bool,
    needsReplyThreadReveal: Bool
  ) {
    self.isOpen = isOpen
    self.isPinned = isPinned
    self.isArchived = isArchived
    self.isChatListHidden = isChatListHidden
    self.isUnfollowed = isUnfollowed
    self.needsReplyThreadReveal = needsReplyThreadReveal
  }
}

public enum InboxMembershipMutation: Equatable, Sendable {
  case follow
  case showInChatList
  case setOpen(Bool)
  case setPinned(Bool)
  case setArchived(Bool)
}

public enum InboxMembershipIntentOutcome: Equatable, Sendable {
  case converged(didMutate: Bool)
  case superseded(didMutate: Bool)

  public var didMutate: Bool {
    switch self {
    case let .converged(didMutate), let .superseded(didMutate):
      didMutate
    }
  }
}

public enum InboxMembershipReconcilerError: Error, Equatable, Sendable {
  case didNotConverge(peer: Peer)
}

/// Serializes each peer independently while coalescing rapid Open/Close actions
/// to the latest desired state. The worker is owned by the actor, not by the
/// submitting caller, so cancellation cannot abandon an accepted mutation.
public actor InboxMembershipReconciler {
  public typealias StateLoader = @Sendable (Peer) async throws -> InboxMembershipCanonicalState
  public typealias MutationPerformer = @Sendable (Peer, InboxMembershipMutation) async throws -> Void

  private struct DesiredRecord: Sendable {
    let intent: InboxMembershipIntent
    let revision: UInt64
  }

  private struct ReconciliationReport: Sendable {
    let revision: UInt64
    let mutationCount: Int
  }

  private struct Worker: Sendable {
    let id: UInt64
    let task: Task<Void, Never>
  }

  private enum WorkerResult: Sendable {
    case success(ReconciliationReport)
    case failure(revision: UInt64, error: any Error)
  }

  private struct ReconciliationFailure: Error {
    let revision: UInt64
    let underlying: any Error
  }

  private struct Waiter: Sendable {
    let revision: UInt64
    let continuation: CheckedContinuation<InboxMembershipIntentOutcome, any Error>
  }

  private let loadState: StateLoader
  private let performMutation: MutationPerformer
  private let maximumMutationsPerPass: Int

  private var nextRevision: UInt64 = 0
  private var nextWorkerID: UInt64 = 0
  private var desiredByPeer: [Peer: DesiredRecord] = [:]
  private var workersByPeer: [Peer: Worker] = [:]
  private var waitersByPeer: [Peer: [Waiter]] = [:]

  public init(
    maximumMutationsPerPass: Int = 16,
    loadState: @escaping StateLoader,
    performMutation: @escaping MutationPerformer
  ) {
    self.maximumMutationsPerPass = maximumMutationsPerPass
    self.loadState = loadState
    self.performMutation = performMutation
  }

  public func submit(
    peer: Peer,
    intent: InboxMembershipIntent
  ) async throws -> InboxMembershipIntentOutcome {
    try Task.checkCancellation()

    nextRevision &+= 1
    let requestRevision = nextRevision
    desiredByPeer[peer] = DesiredRecord(intent: intent, revision: requestRevision)
    // Recording the desired state is the acceptance boundary. Start the
    // caller-independent worker before any cancellation-sensitive suspension
    // so post-acceptance cancellation can only detach this caller's waiter.
    startWorkerIfNeeded(for: peer)

    let outcome = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<InboxMembershipIntentOutcome, any Error>) in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        waitersByPeer[peer, default: []].append(Waiter(
          revision: requestRevision,
          continuation: continuation
        ))
      }
    } onCancel: {
      Task { await self.cancelWaiter(peer: peer, revision: requestRevision) }
    }
    try Task.checkCancellation()
    return outcome
  }

  public static func nextMutation(
    from state: InboxMembershipCanonicalState,
    for intent: InboxMembershipIntent
  ) -> InboxMembershipMutation? {
    switch intent {
    case .open:
      if state.isUnfollowed { return .follow }
      if state.isChatListHidden || state.needsReplyThreadReveal {
        return .showInChatList
      }
      if !state.isOpen { return .setOpen(true) }
      if state.isArchived { return .setArchived(false) }
    case .close:
      if state.isOpen { return .setOpen(false) }
      if state.isPinned { return .setPinned(false) }
    }

    return nil
  }

  func pendingRevision(for peer: Peer) -> UInt64? {
    desiredByPeer[peer]?.revision
  }

  private func startWorkerIfNeeded(for peer: Peer) {
    guard workersByPeer[peer] == nil else { return }

    nextWorkerID &+= 1
    let id = nextWorkerID
    let task = Task { await runWorker(peer: peer, id: id) }
    workersByPeer[peer] = Worker(id: id, task: task)
  }

  private func runWorker(peer: Peer, id: UInt64) async {
    do {
      let report = try await reconcile(peer: peer)
      finishWorker(peer: peer, id: id, result: .success(report))
    } catch let failure as ReconciliationFailure {
      finishWorker(
        peer: peer,
        id: id,
        result: .failure(revision: failure.revision, error: failure.underlying)
      )
    } catch {
      let revision = desiredByPeer[peer]?.revision ?? 0
      finishWorker(peer: peer, id: id, result: .failure(revision: revision, error: error))
    }
  }

  private func finishWorker(
    peer: Peer,
    id: UInt64,
    result: WorkerResult
  ) {
    guard workersByPeer[peer]?.id == id else { return }
    workersByPeer.removeValue(forKey: peer)
    let waiters = waitersByPeer[peer] ?? []
    let settledRevision: UInt64 = switch result {
    case let .success(report):
      report.revision
    case let .failure(revision, _):
      revision
    }
    let settledWaiters = waiters.filter { $0.revision <= settledRevision }
    let pendingWaiters = waiters.filter { $0.revision > settledRevision }
    if pendingWaiters.isEmpty {
      waitersByPeer.removeValue(forKey: peer)
    } else {
      waitersByPeer[peer] = pendingWaiters
    }

    switch result {
    case let .success(report):
      for waiter in settledWaiters {
        let outcome: InboxMembershipIntentOutcome = waiter.revision < report.revision
          ? .superseded(didMutate: report.mutationCount > 0)
          : .converged(didMutate: report.mutationCount > 0)
        waiter.continuation.resume(returning: outcome)
      }
    case let .failure(_, error):
      for waiter in settledWaiters {
        waiter.continuation.resume(throwing: error)
      }
    }

    if desiredByPeer[peer] != nil {
      startWorkerIfNeeded(for: peer)
    }
  }

  private func cancelWaiter(peer: Peer, revision: UInt64) {
    guard var waiters = waitersByPeer[peer],
          let index = waiters.firstIndex(where: { $0.revision == revision })
    else { return }
    let waiter = waiters.remove(at: index)
    if waiters.isEmpty {
      waitersByPeer.removeValue(forKey: peer)
    } else {
      waitersByPeer[peer] = waiters
    }
    waiter.continuation.resume(throwing: CancellationError())
  }

  private func reconcile(peer: Peer) async throws -> ReconciliationReport {
    var mutationCount = 0

    while mutationCount < maximumMutationsPerPass {
      guard let desired = desiredByPeer[peer] else {
        throw InboxMembershipReconcilerError.didNotConverge(peer: peer)
      }

      let state: InboxMembershipCanonicalState
      do {
        state = try await loadState(peer)
      } catch {
        if desiredByPeer[peer]?.revision != desired.revision {
          continue
        }
        desiredByPeer.removeValue(forKey: peer)
        throw ReconciliationFailure(revision: desired.revision, underlying: error)
      }

      guard desiredByPeer[peer]?.revision == desired.revision else { continue }

      guard let mutation = Self.nextMutation(from: state, for: desired.intent) else {
        desiredByPeer.removeValue(forKey: peer)
        return ReconciliationReport(
          revision: desired.revision,
          mutationCount: mutationCount
        )
      }

      do {
        try await performMutation(peer, mutation)
        mutationCount += 1
      } catch {
        // A response may be lost after the canonical mutation committed. A
        // fresh state read distinguishes that from a mutation that must retry.
        let recoveredState: InboxMembershipCanonicalState
        do {
          recoveredState = try await loadState(peer)
        } catch {
          if desiredByPeer[peer]?.revision != desired.revision {
            continue
          }
          desiredByPeer.removeValue(forKey: peer)
          throw ReconciliationFailure(revision: desired.revision, underlying: error)
        }

        guard let latest = desiredByPeer[peer] else {
          throw ReconciliationFailure(revision: desired.revision, underlying: error)
        }
        let attemptedMutationStillNeeded = Self.nextMutation(
          from: recoveredState,
          for: desired.intent
        ) == mutation
        if !attemptedMutationStillNeeded {
          mutationCount += 1
        }
        if latest.revision != desired.revision {
          continue
        }

        if attemptedMutationStillNeeded {
          desiredByPeer.removeValue(forKey: peer)
          throw ReconciliationFailure(revision: desired.revision, underlying: error)
        }
      }
    }

    let revision = desiredByPeer.removeValue(forKey: peer)?.revision ?? nextRevision
    throw ReconciliationFailure(
      revision: revision,
      underlying: InboxMembershipReconcilerError.didNotConverge(peer: peer)
    )
  }
}
