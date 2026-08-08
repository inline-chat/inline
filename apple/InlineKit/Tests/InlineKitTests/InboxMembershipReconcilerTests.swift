@testable import InlineKit
import Testing

@Suite("Inbox membership reconciliation")
struct InboxMembershipReconcilerTests {
  private let peer = Peer.thread(id: 42)

  @Test("Open plans idempotent steps from canonical state")
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

  @Test("Rapid Open then Close converges to the latest intent")
  func rapidOpenThenClose() async throws {
    let store = InboxTestStore(state: .closed, suspendFirstMutation: true)
    let reconciler = makeReconciler(store: store)

    let open = Task { try await reconciler.submit(peer: peer, intent: .open) }
    await store.waitUntilFirstMutationStarts()
    let close = Task { try await reconciler.submit(peer: peer, intent: .close) }
    try await Task.sleep(for: .milliseconds(20))
    await store.releaseFirstMutation()

    #expect(try await open.value == .superseded(didMutate: true))
    #expect(try await close.value == .converged(didMutate: true))
    #expect(await store.currentState() == .closed)
    #expect(await store.performedMutations() == [.setOpen(true), .setOpen(false)])
  }

  @Test("Rapid Pin then Close clears both Open and Pin")
  func rapidPinThenClose() async throws {
    let store = InboxTestStore(state: .open, suspendFirstMutation: true)
    let reconciler = makeReconciler(store: store)

    let pin = Task { try await reconciler.submit(peer: peer, intent: .setPinned(true)) }
    await store.waitUntilFirstMutationStarts()
    let close = Task { try await reconciler.submit(peer: peer, intent: .close) }
    try await Task.sleep(for: .milliseconds(20))
    await store.releaseFirstMutation()

    #expect(try await pin.value == .superseded(didMutate: true))
    #expect(try await close.value == .converged(didMutate: true))
    #expect(await store.currentState() == .closed)
    #expect(await store.performedMutations() == [
      .setPinned(true),
      .setOpen(false),
      .setPinned(false),
    ])
  }

  @Test("A stale Pin cannot reverse an in-flight Close")
  func closeThenStalePin() async throws {
    let store = InboxTestStore(state: .open, suspendFirstMutation: true)
    let reconciler = makeReconciler(store: store)

    let close = Task { try await reconciler.submit(peer: peer, intent: .close) }
    await store.waitUntilFirstMutationStarts()
    let stalePin = Task { try await reconciler.submit(peer: peer, intent: .setPinned(true)) }
    try await Task.sleep(for: .milliseconds(20))
    await store.releaseFirstMutation()

    #expect(try await close.value == .superseded(didMutate: true))
    #expect(try await stalePin.value == .superseded(didMutate: true))
    #expect(await store.currentState() == .closed)
    #expect(await store.performedMutations() == [.setOpen(false)])
  }

  @Test("A lost response is recovered from canonical state")
  func lostResponseRecovery() async throws {
    let store = InboxTestStore(
      state: .closed,
      failAfterApplying: .setOpen(true)
    )
    let reconciler = makeReconciler(store: store)

    let outcome = try await reconciler.submit(peer: peer, intent: .open)

    #expect(outcome == .converged(didMutate: true))
    #expect(await store.currentState() == .open)
    #expect(await store.performedMutations() == [.setOpen(true)])
  }

  @Test("Pin never creates Inbox membership on a closed canonical chat")
  func pinDoesNotOpenClosedChat() async throws {
    let store = InboxTestStore(state: .closed)
    let reconciler = makeReconciler(store: store)

    let outcome = try await reconciler.submit(peer: peer, intent: .setPinned(true))

    #expect(outcome == .superseded(didMutate: false))
    #expect(await store.currentState() == .closed)
    #expect(await store.performedMutations().isEmpty)
  }

  private func makeReconciler(store: InboxTestStore) -> InboxMembershipReconciler {
    InboxMembershipReconciler(
      loadState: { _ in await store.currentState() },
      performMutation: { _, mutation in try await store.perform(mutation) }
    )
  }
}

private enum InboxTestError: Error {
  case simulatedLostResponse
}

private actor InboxTestStore {
  private var state: InboxMembershipCanonicalState
  private var mutations: [InboxMembershipMutation] = []
  private var shouldSuspendFirstMutation: Bool
  private var failAfterApplying: InboxMembershipMutation?
  private var firstMutationStarted = false
  private var firstMutationStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseFirstMutationContinuation: CheckedContinuation<Void, Never>?

  init(
    state: InboxMembershipCanonicalState,
    suspendFirstMutation: Bool = false,
    failAfterApplying: InboxMembershipMutation? = nil
  ) {
    self.state = state
    shouldSuspendFirstMutation = suspendFirstMutation
    self.failAfterApplying = failAfterApplying
  }

  func currentState() -> InboxMembershipCanonicalState { state }

  func performedMutations() -> [InboxMembershipMutation] { mutations }

  func waitUntilFirstMutationStarts() async {
    guard !firstMutationStarted else { return }
    await withCheckedContinuation { continuation in
      firstMutationStartWaiters.append(continuation)
    }
  }

  func releaseFirstMutation() {
    releaseFirstMutationContinuation?.resume()
    releaseFirstMutationContinuation = nil
  }

  func perform(_ mutation: InboxMembershipMutation) async throws {
    mutations.append(mutation)
    if shouldSuspendFirstMutation {
      shouldSuspendFirstMutation = false
      firstMutationStarted = true
      let waiters = firstMutationStartWaiters
      firstMutationStartWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
      await withCheckedContinuation { continuation in
        releaseFirstMutationContinuation = continuation
      }
    }

    state = state.applying(mutation)
    if failAfterApplying == mutation {
      failAfterApplying = nil
      throw InboxTestError.simulatedLostResponse
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
