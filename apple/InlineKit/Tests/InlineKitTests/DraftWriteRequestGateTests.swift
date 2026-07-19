import Testing

@testable import InlineKit

@Suite("Draft Write Request Gate")
struct DraftWriteRequestGateTests {
  @Test("newer request invalidates older request for same peer")
  func newerRequestInvalidatesOlderForSamePeer() {
    var gate = DraftWriteRequestGate()
    let peer: Peer = .thread(id: 123)

    let first = gate.registerRequest(for: peer)
    #expect(gate.isLatest(first, for: peer))

    let second = gate.registerRequest(for: peer)
    #expect(!gate.isLatest(first, for: peer))
    #expect(gate.isLatest(second, for: peer))
  }

  @Test("latest intent kind follows request order")
  func latestIntentKindFollowsRequestOrder() {
    var gate = DraftWriteRequestGate()
    let peer: Peer = .thread(id: 456)

    _ = gate.registerRequest(for: peer, kind: .update)
    #expect(gate.latestKind(for: peer) == .update)

    _ = gate.registerRequest(for: peer, kind: .clear)
    #expect(gate.latestKind(for: peer) == .clear)
  }

  @Test("requests are tracked independently per peer")
  func requestsAreTrackedPerPeer() {
    var gate = DraftWriteRequestGate()
    let peerA: Peer = .thread(id: 1)
    let peerB: Peer = .user(id: 2)

    let tokenA = gate.registerRequest(for: peerA)
    let tokenB = gate.registerRequest(for: peerB)

    #expect(gate.isLatest(tokenA, for: peerA))
    #expect(gate.isLatest(tokenB, for: peerB))
    #expect(!gate.isLatest(tokenA, for: peerB))
    #expect(!gate.isLatest(tokenB, for: peerA))
  }

  @Test("clear keeps suppressing restoration while replacement content is pending")
  func clearKeepsSuppressingRestorationWhileReplacementContentIsPending() {
    let drafts = Drafts()
    let peer: Peer = .thread(id: 789)

    let oldUpdate = drafts.registerIntent(for: peer, kind: .update)
    let clear = drafts.registerIntent(for: peer, kind: .clear)

    #expect(!drafts.isLatestIntent(oldUpdate))
    #expect(drafts.isLatestIntent(clear))
    #expect(drafts.shouldSuppressDraftRestoration(for: peer))

    let newUpdate = drafts.registerIntent(for: peer, kind: .update)

    #expect(!drafts.isLatestIntent(clear))
    #expect(drafts.isLatestIntent(newUpdate))
    #expect(drafts.shouldSuppressDraftRestoration(for: peer))
  }

  @Test("persisted replacement content releases restoration suppression")
  func persistedReplacementContentReleasesRestorationSuppression() {
    var gate = DraftWriteRequestGate()
    let peer: Peer = .thread(id: 790)

    _ = gate.registerRequest(for: peer, kind: .clear)
    let replacement = gate.registerRequest(for: peer, kind: .update)
    #expect(gate.shouldSuppressRestoration(for: peer))

    gate.markPersisted(replacement, for: peer)

    #expect(!gate.shouldSuppressRestoration(for: peer))
  }
}
