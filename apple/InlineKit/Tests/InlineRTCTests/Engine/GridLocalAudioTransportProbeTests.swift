@testable import InlineRTC
import Testing

@Suite("Grid local audio transport probe")
struct GridLocalAudioTransportProbeTests {
  @Test
  func requiresARealOutboundCounterAdvance() {
    let baseline = snapshot(id: "audio", timestamp: 1, packets: 10, bytes: 1_000)

    #expect(!baseline.hasProgress(since: baseline))
    #expect(
      !snapshot(id: "audio", timestamp: 2, packets: 10, bytes: 1_000)
        .hasProgress(since: baseline)
    )
    #expect(
      snapshot(id: "audio", timestamp: 2, packets: 11, bytes: 1_000)
        .hasProgress(since: baseline)
    )
    #expect(
      snapshot(id: "audio", timestamp: 2, packets: 10, bytes: 1_001)
        .hasProgress(since: baseline)
    )
  }

  @Test
  func acceptsAReplacementSenderOnlyAfterItSends() {
    let baseline = snapshot(id: "old", timestamp: 1, packets: 10, bytes: 1_000)

    #expect(
      !snapshot(id: "new", timestamp: 2, packets: 0, bytes: 0)
        .hasProgress(since: baseline)
    )
    #expect(
      snapshot(id: "new", timestamp: 2, packets: 1, bytes: 100)
        .hasProgress(since: baseline)
    )
  }

  @Test
  func acceptsAStatsCounterResetOnlyWithANewerSample() {
    let baseline = snapshot(id: "audio", timestamp: 5, packets: 100, bytes: 10_000)

    #expect(
      !snapshot(id: "audio", timestamp: 5, packets: 1, bytes: 100)
        .hasProgress(since: baseline)
    )
    #expect(
      snapshot(id: "audio", timestamp: 6, packets: 1, bytes: 100)
        .hasProgress(since: baseline)
    )
  }

  @Test
  func totalsSaturateInsteadOfWrapping() {
    let snapshot = GridLocalAudioTransportSnapshot(streams: [
      .init(id: "a", timestamp: 1, packetsSent: .max, bytesSent: .max),
      .init(id: "b", timestamp: 1, packetsSent: 1, bytesSent: 1),
    ])

    #expect(snapshot.packetCount == .max)
    #expect(snapshot.byteCount == .max)
  }

  @Test("one sender statistics miss is suspect before confirmed failure")
  func requiresConsecutiveMisses() {
    var proof = GridLocalAudioTransportProof(missThreshold: 2)

    #expect(proof.observe(hasProgress: false) == .suspect(consecutiveMisses: 1))
    #expect(proof.observe(hasProgress: false) == .missing(consecutiveMisses: 2))
  }

  @Test("sender progress resets the miss sequence")
  func progressResetsMissSequence() {
    var proof = GridLocalAudioTransportProof(missThreshold: 2)

    #expect(proof.observe(hasProgress: false) == .suspect(consecutiveMisses: 1))
    #expect(proof.observe(hasProgress: true) == .flowing)
    #expect(proof.observe(hasProgress: false) == .suspect(consecutiveMisses: 1))
  }

  @Test("an explicit proof reset fences an older sender epoch")
  func resetFencesOlderEpoch() {
    var proof = GridLocalAudioTransportProof(missThreshold: 2)
    _ = proof.observe(hasProgress: false)

    proof.reset()

    #expect(proof.observe(hasProgress: false) == .suspect(consecutiveMisses: 1))
  }

  private func snapshot(
    id: String,
    timestamp: Double,
    packets: UInt64,
    bytes: UInt64
  ) -> GridLocalAudioTransportSnapshot {
    GridLocalAudioTransportSnapshot(streams: [
      .init(
        id: id,
        timestamp: timestamp,
        packetsSent: packets,
        bytesSent: bytes
      ),
    ])
  }
}
