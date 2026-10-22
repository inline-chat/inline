import Foundation
import Testing

@testable import InlineRTC

@Suite("Call diagnostics")
struct InlineRTCDiagnosticsTests {
  @Test("receive buffer is the per-interval average, not the lifetime one")
  func receiveBufferInterval() {
    let previous = GridInboundAudioCounters(
      timestampMicroseconds: 0,
      bytesReceived: 0,
      packetsReceived: 100,
      packetsLost: 0,
      jitterBufferDelaySeconds: 48, // 80 ms average over 600 frames
      jitterBufferEmittedCount: 600,
      concealedSamples: 0,
      totalSamplesReceived: 96_000
    )
    let current = GridInboundAudioCounters(
      timestampMicroseconds: 2_000_000,
      bytesReceived: 16_000,
      packetsReceived: 198,
      packetsLost: 2,
      jitterBufferDelaySeconds: 48 + 250, // 2.5 s per frame for 100 frames
      jitterBufferEmittedCount: 700,
      concealedSamples: 960,
      totalSamplesReceived: 96_000 + 96_000
    )

    let interval = GridDiagnosticsMath.interval(from: previous, to: current)

    #expect(interval.receiveBufferMilliseconds == 2_500)
    #expect(interval.bitrateKbps == 64)
    #expect(interval.lossPercent == 2)
    #expect(interval.concealedPercent == 1)
  }

  @Test("a replaced stream yields no interval values instead of negative ones")
  func counterReset() {
    let previous = GridInboundAudioCounters(
      timestampMicroseconds: 0,
      bytesReceived: 10_000,
      packetsReceived: 500,
      packetsLost: 3,
      jitterBufferDelaySeconds: 10,
      jitterBufferEmittedCount: 100
    )
    let current = GridInboundAudioCounters(
      timestampMicroseconds: 2_000_000,
      bytesReceived: 100,
      packetsReceived: 5,
      packetsLost: 0,
      jitterBufferDelaySeconds: 1,
      jitterBufferEmittedCount: 10
    )

    let interval = GridDiagnosticsMath.interval(from: previous, to: current)

    #expect(interval.bitrateKbps == nil)
    #expect(interval.receiveBufferMilliseconds == nil)
  }

  @Test("delay estimate adds both network legs, buffer, and devices")
  func delayEstimate() {
    let incoming = Self.incoming(identity: "a", buffer: 2_600)
    let sample = Self.sample(rtt: 50, incoming: [incoming])

    let estimate = sample.estimatedDelay(for: incoming)

    #expect(estimate.networkMilliseconds == 50)
    #expect(estimate.receiveBufferMilliseconds == 2_600)
    #expect(estimate.totalMilliseconds == 50 + 2_600 + 40)
  }

  @Test("receive buffer growth and recovery are logged once each")
  func bufferEvents() {
    var recorder = InlineRTCDiagnosticsRecorder()
    recorder.record(Self.sample(rtt: 40, incoming: [Self.incoming(identity: "a", buffer: 80)]))
    recorder.record(Self.sample(rtt: 40, incoming: [Self.incoming(identity: "a", buffer: 900)]))
    recorder.record(Self.sample(rtt: 40, incoming: [Self.incoming(identity: "a", buffer: 1_200)]))
    recorder.record(Self.sample(rtt: 40, incoming: [Self.incoming(identity: "a", buffer: 60)]))

    let messages = recorder.events.map(\.message)
    #expect(messages.filter { $0.contains("grew to") }.count == 1)
    #expect(messages.filter { $0.contains("back to") }.count == 1)
    #expect(recorder.samples.count == 4)
  }

  private static func sample(
    rtt: Double,
    incoming: [InlineRTCIncomingAudioStats]
  ) -> InlineRTCDiagnosticsSample {
    let candidate = InlineRTCCandidateInfo(type: "host", transportProtocol: "udp", relayProtocol: nil)
    let transport = InlineRTCTransportStats(
      roundTripMilliseconds: rtt,
      availableOutgoingKbps: nil,
      availableIncomingKbps: nil,
      local: candidate,
      remote: candidate,
      iceState: nil,
      dtlsState: nil
    )
    return InlineRTCDiagnosticsSample(
      time: Date(),
      server: InlineRTCServerInfo(host: nil, region: nil, nodeID: nil, version: nil, roomSid: nil),
      localConnectionQuality: "good",
      publisher: transport,
      subscriber: transport,
      outgoing: nil,
      incoming: incoming,
      outputDeviceDelayMilliseconds: 10,
      inputDeviceDelayMilliseconds: 10
    )
  }

  private static func incoming(identity: String, buffer: Double) -> InlineRTCIncomingAudioStats {
    InlineRTCIncomingAudioStats(
      participantIdentity: identity,
      trackSid: "TR_\(identity)",
      muted: false,
      codec: "opus",
      bitrateKbps: 32,
      jitterMilliseconds: 5,
      lossPercent: 0,
      receiveBufferMilliseconds: buffer,
      receiveBufferTargetMilliseconds: 80,
      concealedPercent: 0,
      audioLevel: nil,
      packetsLostTotal: 0,
      packetsReceivedTotal: 100,
      connectionQuality: "good"
    )
  }
}
