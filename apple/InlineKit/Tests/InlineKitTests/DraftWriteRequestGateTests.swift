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
}
