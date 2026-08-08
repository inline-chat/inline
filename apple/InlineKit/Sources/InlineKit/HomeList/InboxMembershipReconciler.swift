import Foundation

public enum InboxMembershipIntent: Equatable, Sendable {
  case open
  case close
  case setPinned(Bool)
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

  public var didConvergeRequestedIntent: Bool {
    if case .converged = self { true } else { false }
  }

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

/// Coalesces every peer's Open/Close/Pin requests into one desired state and
/// reconciles one idempotent operation at a time from the latest durable state.
///
/// The closures keep transport and persistence policy at the app boundary while
/// making lost-response and rapid-intent behavior independently testable.
public actor InboxMembershipReconciler {
  public typealias StateLoader = @Sendable (Peer) async throws -> InboxMembershipCanonicalState
  public typealias MutationPerformer = @Sendable (Peer, InboxMembershipMutation) async throws -> Void

  private struct DesiredState: Sendable {
    var isOpen: Bool?
    var isPinned: Bool?

    @discardableResult
    mutating func apply(_ intent: InboxMembershipIntent) -> Bool {
      switch intent {
      case .open:
        isOpen = true
        return true
      case .close:
        isOpen = false
        isPinned = false
        return true
      case .setPinned(true):
        // Pin never creates Inbox membership. If Close is already the desired
        // state, ignore a stale late Pin from a dismissing row.
        if isOpen != false {
          isPinned = true
          return true
        }
        return false
      case .setPinned(false):
        isPinned = false
        return true
      }
    }
  }

  private struct DesiredRecord: Sendable {
    var state: DesiredState
    let generation: UInt64
  }

  private struct ReconciliationReport: Sendable {
    let generation: UInt64
    let mutationCount: Int
    let rejectedDesiredState: Bool
  }

  private struct Worker: Sendable {
    let id: UInt64
    let task: Task<ReconciliationReport, Error>
  }

  private let loadState: StateLoader
  private let performMutation: MutationPerformer
  private let maximumMutationsPerPass: Int

  private var nextGeneration: UInt64 = 0
  private var nextWorkerID: UInt64 = 0
  private var desiredByPeer: [Peer: DesiredRecord] = [:]
  private var workersByPeer: [Peer: Worker] = [:]

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
    nextGeneration &+= 1
    let requestGeneration = nextGeneration
    var desired = desiredByPeer[peer]?.state ?? DesiredState()
    let requestWasAccepted = desired.apply(intent)
    desiredByPeer[peer] = DesiredRecord(state: desired, generation: requestGeneration)

    while true {
      try Task.checkCancellation()
      let worker = worker(for: peer)

      do {
        let report = try await worker.task.value
        clearWorker(peer: peer, id: worker.id)

        if let latest = desiredByPeer[peer], latest.generation > report.generation {
          continue
        }

        try Task.checkCancellation()
        if !requestWasAccepted
          || report.rejectedDesiredState
          || requestGeneration < report.generation {
          return .superseded(didMutate: report.mutationCount > 0)
        }
        return .converged(didMutate: report.mutationCount > 0)
      } catch {
        clearWorker(peer: peer, id: worker.id)

        // A newer request may make the failed operation irrelevant. Give that
        // desired state its own canonical reconciliation before surfacing error.
        if let latest = desiredByPeer[peer], latest.generation > requestGeneration {
          continue
        }
        throw error
      }
    }
  }

  public static func nextMutation(
    from state: InboxMembershipCanonicalState,
    for intent: InboxMembershipIntent
  ) -> InboxMembershipMutation? {
    var desired = DesiredState()
    desired.apply(intent)
    return nextMutation(from: state, for: desired)
  }

  private func worker(for peer: Peer) -> Worker {
    if let existing = workersByPeer[peer] {
      return existing
    }

    nextWorkerID &+= 1
    let id = nextWorkerID
    let task = Task { try await reconcile(peer: peer) }
    let worker = Worker(id: id, task: task)
    workersByPeer[peer] = worker
    return worker
  }

  private func clearWorker(peer: Peer, id: UInt64) {
    guard workersByPeer[peer]?.id == id else { return }
    workersByPeer.removeValue(forKey: peer)
  }

  private func reconcile(peer: Peer) async throws -> ReconciliationReport {
    var mutationCount = 0

    while mutationCount < maximumMutationsPerPass {
      guard let desired = desiredByPeer[peer] else {
        return ReconciliationReport(
          generation: nextGeneration,
          mutationCount: mutationCount,
          rejectedDesiredState: false
        )
      }

      let state = try await loadState(peer)
      guard desiredByPeer[peer]?.generation == desired.generation else { continue }

      if Self.isInvalid(state: state, desired: desired.state) {
        desiredByPeer.removeValue(forKey: peer)
        return ReconciliationReport(
          generation: desired.generation,
          mutationCount: mutationCount,
          rejectedDesiredState: true
        )
      }

      guard let mutation = Self.nextMutation(from: state, for: desired.state) else {
        desiredByPeer.removeValue(forKey: peer)
        return ReconciliationReport(
          generation: desired.generation,
          mutationCount: mutationCount,
          rejectedDesiredState: false
        )
      }

      do {
        try await performMutation(peer, mutation)
        mutationCount += 1
      } catch {
        // A reply can be lost after the canonical mutation committed. Reload
        // before deciding whether this is a true failure or partial progress.
        let recoveredState = try await loadState(peer)
        guard let latest = desiredByPeer[peer] else { throw error }
        guard latest.generation == desired.generation else { continue }

        let recoveredMutation = Self.nextMutation(from: recoveredState, for: latest.state)
        guard recoveredMutation != mutation else { throw error }
        mutationCount += 1
      }
    }

    throw InboxMembershipReconcilerError.didNotConverge(peer: peer)
  }

  private static func nextMutation(
    from state: InboxMembershipCanonicalState,
    for desired: DesiredState
  ) -> InboxMembershipMutation? {
    if desired.isOpen == true {
      if state.isUnfollowed { return .follow }
      if state.isChatListHidden || state.needsReplyThreadReveal {
        return .showInChatList
      }
      if !state.isOpen { return .setOpen(true) }
      if state.isArchived { return .setArchived(false) }
    } else if desired.isOpen == false, state.isOpen {
      return .setOpen(false)
    }

    if let isPinned = desired.isPinned, state.isPinned != isPinned {
      return .setPinned(isPinned)
    }

    return nil
  }

  private static func isInvalid(
    state: InboxMembershipCanonicalState,
    desired: DesiredState
  ) -> Bool {
    // Pin is available only while the chat belongs to Inbox. A delayed task
    // arriving after Close convergence must not recreate a closed pinned row.
    desired.isPinned == true && desired.isOpen == nil && !state.isOpen
  }
}
