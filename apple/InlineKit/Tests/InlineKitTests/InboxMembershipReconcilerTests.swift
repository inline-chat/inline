@testable import InlineKit
import Testing

@Suite("Inbox membership reconciliation")
struct InboxMembershipReconcilerTests {
  private let peer = Peer.thread(id: 42)

  @Test("Open plans the existing canonical membership steps")
  func openPlan() {
    var state = InboxMembershipCanonicalState(
      isOpen: false,
      isPinned: false,
      isArchived: true,
      isChatListHidden: true,
      isUnfollowed: true,
      needsReplyThreadReveal: false
    )

    #expect(InboxMembershipReconciler.nextMutation(from: state, for: .open) == .follow)
    state = state.applying(.follow)
    #expect(InboxMembershipReconciler.nextMutation(from: state, for: .open) == .showInChatList)
    state = state.applying(.showInChatList)
    #expect(InboxMembershipReconciler.nextMutation(from: state, for: .open) == .setOpen(true))
    state = state.applying(.setOpen(true))
    #expect(InboxMembershipReconciler.nextMutation(from: state, for: .open) == .setArchived(false))
    state = state.applying(.setArchived(false))
    #expect(InboxMembershipReconciler.nextMutation(from: state, for: .open) == nil)
  }

  @Test("Rapid Open then Close converges to Close")
  func rapidOpenThenClose() async throws {
    let store = InboxTestStore(state: .closed, suspendFirstMutation: true)
    let reconciler = makeReconciler(store: store)

    let open = Task { try await reconciler.submit(peer: peer, intent: .open) }
    await store.waitUntilFirstMutationStarts()
    let close = Task { try await reconciler.submit(peer: peer, intent: .close) }
    await waitUntilRevision(2, in: reconciler)
    await store.releaseFirstMutation()

    #expect(try await open.value == .superseded(didMutate: true))
    #expect(try await close.value == .converged(didMutate: true))
    #expect(await store.currentState() == .closed)
    #expect(await store.performedMutations() == [.setOpen(true), .setOpen(false)])
  }

  @Test("Rapid Close then Open converges to Open")
  func rapidCloseThenOpen() async throws {
    let store = InboxTestStore(state: .open, suspendFirstMutation: true)
    let reconciler = makeReconciler(store: store)

    let close = Task { try await reconciler.submit(peer: peer, intent: .close) }
    await store.waitUntilFirstMutationStarts()
    let open = Task { try await reconciler.submit(peer: peer, intent: .open) }
    await waitUntilRevision(2, in: reconciler)
    await store.releaseFirstMutation()

    #expect(try await close.value == .superseded(didMutate: true))
    #expect(try await open.value == .converged(didMutate: true))
    #expect(await store.currentState() == .open)
    #expect(await store.performedMutations() == [.setOpen(false), .setOpen(true)])
  }

  @Test("Open Close Open coalesces the unstarted Close")
  func latestMatchingIntentCoalescesIntermediateOpposite() async throws {
    let store = InboxTestStore(state: .closed, suspendFirstMutation: true)
    let reconciler = makeReconciler(store: store)

    let firstOpen = Task { try await reconciler.submit(peer: peer, intent: .open) }
    await store.waitUntilFirstMutationStarts()
    let close = Task { try await reconciler.submit(peer: peer, intent: .close) }
    await waitUntilRevision(2, in: reconciler)
    let latestOpen = Task { try await reconciler.submit(peer: peer, intent: .open) }
    await waitUntilRevision(3, in: reconciler)
    await store.releaseFirstMutation()

    #expect(try await firstOpen.value == .superseded(didMutate: true))
    #expect(try await close.value == .superseded(didMutate: true))
    #expect(try await latestOpen.value == .converged(didMutate: true))
    #expect(await store.currentState() == .open)
    #expect(await store.performedMutations() == [.setOpen(true)])
  }

  @Test("A failed old intent does not block a newer opposite intent")
  func failureContinuesTowardNewerIntent() async throws {
    let store = InboxTestStore(
      state: .closed,
      suspendFirstMutation: true,
      failBeforeApplying: .setOpen(true)
    )
    let reconciler = makeReconciler(store: store)

    let open = Task { try await reconciler.submit(peer: peer, intent: .open) }
    await store.waitUntilFirstMutationStarts()
    let close = Task { try await reconciler.submit(peer: peer, intent: .close) }
    await waitUntilRevision(2, in: reconciler)
    await store.releaseFirstMutation()

    #expect(try await open.value == .superseded(didMutate: false))
    #expect(try await close.value == .converged(didMutate: false))
    #expect(await store.currentState() == .closed)
  }

  @Test("A failed old intent retries when the newer intent matches")
  func failureRetriesNewerMatchingIntent() async throws {
    let store = InboxTestStore(
      state: .closed,
      suspendFirstMutation: true,
      failBeforeApplying: .setOpen(true)
    )
    let reconciler = makeReconciler(store: store)

    let first = Task { try await reconciler.submit(peer: peer, intent: .open) }
    await store.waitUntilFirstMutationStarts()
    let second = Task { try await reconciler.submit(peer: peer, intent: .open) }
    await waitUntilRevision(2, in: reconciler)
    await store.releaseFirstMutation()

    #expect(try await first.value == .superseded(didMutate: true))
    #expect(try await second.value == .converged(didMutate: true))
    #expect(await store.currentState() == .open)
    #expect(await store.performedMutations() == [.setOpen(true), .setOpen(true)])
  }

  @Test("Terminal failure clears the lane for a later retry")
  func terminalFailureAllowsLaterSubmission() async throws {
    let store = InboxTestStore(state: .closed, failBeforeApplying: .setOpen(true))
    let reconciler = makeReconciler(store: store)

    await #expect(throws: InboxTestError.simulatedFailure) {
      try await reconciler.submit(peer: peer, intent: .open)
    }

    #expect(try await reconciler.submit(peer: peer, intent: .open) == .converged(didMutate: true))
    #expect(await store.currentState() == .open)
  }

  @Test("A lost response is recovered from canonical state")
  func lostResponseRecovery() async throws {
    let store = InboxTestStore(
      state: .closed,
      failAfterApplying: .setOpen(true)
    )
    let reconciler = makeReconciler(store: store)

    #expect(try await reconciler.submit(peer: peer, intent: .open) == .converged(didMutate: true))
    #expect(await store.currentState() == .open)
    #expect(await store.performedMutations() == [.setOpen(true)])
  }

  @Test("Cancelling the waiter does not cancel accepted reconciliation")
  func callerCancellationDoesNotAbandonIntent() async throws {
    let store = InboxTestStore(state: .closed, suspendFirstMutation: true)
    let reconciler = makeReconciler(store: store)

    let waiter = Task { try await reconciler.submit(peer: peer, intent: .open) }
    await store.waitUntilFirstMutationStarts()
    waiter.cancel()
    await store.releaseFirstMutation()

    await #expect(throws: CancellationError.self) {
      try await waiter.value
    }
    _ = try await reconciler.submit(peer: peer, intent: .open)
    #expect(await store.currentState() == .open)
    #expect(await store.performedMutations() == [.setOpen(true)])
  }

  @Test("Different peers reconcile concurrently")
  func peersDoNotShareALane() async throws {
    let firstPeer = Peer.thread(id: 1)
    let secondPeer = Peer.thread(id: 2)
    let store = InboxTestStore(
      states: [firstPeer: .closed, secondPeer: .closed],
      suspendedPeers: [firstPeer, secondPeer]
    )
    let reconciler = makeReconciler(store: store)

    let first = Task { try await reconciler.submit(peer: firstPeer, intent: .open) }
    let second = Task { try await reconciler.submit(peer: secondPeer, intent: .open) }
    await store.waitUntilMutationStarts(for: firstPeer)
    await store.waitUntilMutationStarts(for: secondPeer)
    await store.releaseMutation(for: firstPeer)
    await store.releaseMutation(for: secondPeer)

    _ = try await (first.value, second.value)
    #expect(await store.currentState(for: firstPeer) == .open)
    #expect(await store.currentState(for: secondPeer) == .open)
  }

  private func makeReconciler(store: InboxTestStore) -> InboxMembershipReconciler {
    InboxMembershipReconciler(
      loadState: { peer in await store.currentState(for: peer) },
      performMutation: { peer, mutation in try await store.perform(mutation, for: peer) }
    )
  }

  private func waitUntilRevision(
    _ revision: UInt64,
    in reconciler: InboxMembershipReconciler
  ) async {
    while (await reconciler.pendingRevision(for: peer) ?? 0) < revision {
      await Task.yield()
    }
  }
}

private enum InboxTestError: Error, Equatable {
  case simulatedFailure
}

private actor InboxTestStore {
  private static let defaultPeer = Peer.thread(id: 42)
  private var states: [Peer: InboxMembershipCanonicalState]
  private var mutations: [Peer: [InboxMembershipMutation]] = [:]
  private var suspendedPeers: Set<Peer>
  private var failBeforeApplying: InboxMembershipMutation?
  private var failAfterApplying: InboxMembershipMutation?
  private var startedPeers = Set<Peer>()
  private var startWaiters: [Peer: [CheckedContinuation<Void, Never>]] = [:]
  private var releaseContinuations: [Peer: CheckedContinuation<Void, Never>] = [:]

  init(
    state: InboxMembershipCanonicalState,
    suspendFirstMutation: Bool = false,
    failBeforeApplying: InboxMembershipMutation? = nil,
    failAfterApplying: InboxMembershipMutation? = nil
  ) {
    states = [Self.defaultPeer: state]
    suspendedPeers = suspendFirstMutation ? [Self.defaultPeer] : []
    self.failBeforeApplying = failBeforeApplying
    self.failAfterApplying = failAfterApplying
  }

  init(
    states: [Peer: InboxMembershipCanonicalState],
    suspendedPeers: Set<Peer>
  ) {
    self.states = states
    self.suspendedPeers = suspendedPeers
  }

  func currentState() -> InboxMembershipCanonicalState {
    currentState(for: Self.defaultPeer)
  }

  func currentState(for peer: Peer) -> InboxMembershipCanonicalState {
    states[peer] ?? .closed
  }

  func performedMutations() -> [InboxMembershipMutation] {
    mutations[Self.defaultPeer] ?? []
  }

  func waitUntilFirstMutationStarts() async {
    await waitUntilMutationStarts(for: Self.defaultPeer)
  }

  func waitUntilMutationStarts(for peer: Peer) async {
    guard !startedPeers.contains(peer) else { return }
    await withCheckedContinuation { continuation in
      startWaiters[peer, default: []].append(continuation)
    }
  }

  func releaseFirstMutation() {
    releaseMutation(for: Self.defaultPeer)
  }

  func releaseMutation(for peer: Peer) {
    releaseContinuations.removeValue(forKey: peer)?.resume()
  }

  func perform(_ mutation: InboxMembershipMutation, for peer: Peer) async throws {
    mutations[peer, default: []].append(mutation)

    if suspendedPeers.remove(peer) != nil {
      startedPeers.insert(peer)
      let waiters = startWaiters.removeValue(forKey: peer) ?? []
      for waiter in waiters { waiter.resume() }
      await withCheckedContinuation { continuation in
        releaseContinuations[peer] = continuation
      }
    }

    if failBeforeApplying == mutation {
      failBeforeApplying = nil
      throw InboxTestError.simulatedFailure
    }

    states[peer] = currentState(for: peer).applying(mutation)
    if failAfterApplying == mutation {
      failAfterApplying = nil
      throw InboxTestError.simulatedFailure
    }
  }
}

private extension InboxMembershipCanonicalState {
  static let closed = Self(
    isOpen: false,
    isPinned: false,
    isArchived: false,
    isChatListHidden: false,
    isUnfollowed: false,
    needsReplyThreadReveal: false
  )

  static let open = Self(
    isOpen: true,
    isPinned: false,
    isArchived: false,
    isChatListHidden: false,
    isUnfollowed: false,
    needsReplyThreadReveal: false
  )

  func applying(_ mutation: InboxMembershipMutation) -> Self {
    var isOpen = isOpen
    var isPinned = isPinned
    var isArchived = isArchived
    var isChatListHidden = isChatListHidden
    var isUnfollowed = isUnfollowed
    var needsReplyThreadReveal = needsReplyThreadReveal

    switch mutation {
    case .follow:
      isUnfollowed = false
    case .showInChatList:
      isChatListHidden = false
      needsReplyThreadReveal = false
    case let .setOpen(value):
      isOpen = value
    case let .setPinned(value):
      isPinned = value
    case let .setArchived(value):
      isArchived = value
    }

    return Self(
      isOpen: isOpen,
      isPinned: isPinned,
      isArchived: isArchived,
      isChatListHidden: isChatListHidden,
      isUnfollowed: isUnfollowed,
      needsReplyThreadReveal: needsReplyThreadReveal
    )
  }
}
