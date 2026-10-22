import Foundation

/// Opt-in call diagnostics for people debugging their own situation. Nothing
/// here drives media behavior; it is a read-only projection of WebRTC stats and
/// engine snapshots, recorded at a low rate while a call is active so the
/// history is already there when someone notices a problem.

public struct InlineRTCCandidateInfo: Equatable, Sendable {
  /// host, srflx, prflx, or relay.
  public let type: String?
  /// udp or tcp.
  public let transportProtocol: String?
  /// For relay candidates: how this client reaches the TURN server.
  public let relayProtocol: String?

  public init(
    type: String?,
    transportProtocol: String?,
    relayProtocol: String?
  ) {
    self.type = type
    self.transportProtocol = transportProtocol
    self.relayProtocol = relayProtocol
  }

  public var isRelay: Bool { type == "relay" }
  public var isTCP: Bool {
    transportProtocol == "tcp" || relayProtocol == "tcp" || relayProtocol == "tls"
  }

  public var summary: String {
    var parts = [type ?? "?", transportProtocol ?? "?"]
    if let relayProtocol { parts.append("via \(relayProtocol)") }
    return parts.joined(separator: " ")
  }
}

public struct InlineRTCTransportStats: Equatable, Sendable {
  public let roundTripMilliseconds: Double?
  public let availableOutgoingKbps: Double?
  public let availableIncomingKbps: Double?
  public let local: InlineRTCCandidateInfo?
  public let remote: InlineRTCCandidateInfo?
  public let iceState: String?
  public let dtlsState: String?

  public init(
    roundTripMilliseconds: Double?,
    availableOutgoingKbps: Double?,
    availableIncomingKbps: Double?,
    local: InlineRTCCandidateInfo?,
    remote: InlineRTCCandidateInfo?,
    iceState: String?,
    dtlsState: String?
  ) {
    self.roundTripMilliseconds = roundTripMilliseconds
    self.availableOutgoingKbps = availableOutgoingKbps
    self.availableIncomingKbps = availableIncomingKbps
    self.local = local
    self.remote = remote
    self.iceState = iceState
    self.dtlsState = dtlsState
  }
}

public struct InlineRTCOutgoingAudioStats: Equatable, Sendable {
  public let muted: Bool
  public let codec: String?
  public let bitrateKbps: Double?
  public let targetBitrateKbps: Double?
  public let packetsPerSecond: Double?
  public let retransmittedPacketsPerSecond: Double?
  /// RTCP-measured round trip between this sender and the media server.
  public let serverRoundTripMilliseconds: Double?
  /// Loss the media server reports for this upload, 0–100.
  public let serverReportedLossPercent: Double?
  public let serverReportedJitterMilliseconds: Double?

  public init(
    muted: Bool,
    codec: String?,
    bitrateKbps: Double?,
    targetBitrateKbps: Double?,
    packetsPerSecond: Double?,
    retransmittedPacketsPerSecond: Double?,
    serverRoundTripMilliseconds: Double?,
    serverReportedLossPercent: Double?,
    serverReportedJitterMilliseconds: Double?
  ) {
    self.muted = muted
    self.codec = codec
    self.bitrateKbps = bitrateKbps
    self.targetBitrateKbps = targetBitrateKbps
    self.packetsPerSecond = packetsPerSecond
    self.retransmittedPacketsPerSecond = retransmittedPacketsPerSecond
    self.serverRoundTripMilliseconds = serverRoundTripMilliseconds
    self.serverReportedLossPercent = serverReportedLossPercent
    self.serverReportedJitterMilliseconds = serverReportedJitterMilliseconds
  }
}

public struct InlineRTCIncomingAudioStats: Equatable, Sendable, Identifiable {
  public var id: String { trackSid }

  public let participantIdentity: String
  public let trackSid: String
  public let muted: Bool
  public let codec: String?
  public let bitrateKbps: Double?
  public let jitterMilliseconds: Double?
  /// Loss during the last sample interval, 0–100.
  public let lossPercent: Double?
  /// Average time emitted audio spent in the receive (NetEq) buffer during
  /// the last interval. This is the component that grows to seconds after a
  /// network burst.
  public let receiveBufferMilliseconds: Double?
  public let receiveBufferTargetMilliseconds: Double?
  /// Share of output samples WebRTC synthesized to hide loss, 0–100.
  public let concealedPercent: Double?
  public let audioLevel: Double?
  public let packetsLostTotal: Int64?
  public let packetsReceivedTotal: UInt64?
  public let connectionQuality: String

  public init(
    participantIdentity: String,
    trackSid: String,
    muted: Bool,
    codec: String?,
    bitrateKbps: Double?,
    jitterMilliseconds: Double?,
    lossPercent: Double?,
    receiveBufferMilliseconds: Double?,
    receiveBufferTargetMilliseconds: Double?,
    concealedPercent: Double?,
    audioLevel: Double?,
    packetsLostTotal: Int64?,
    packetsReceivedTotal: UInt64?,
    connectionQuality: String
  ) {
    self.participantIdentity = participantIdentity
    self.trackSid = trackSid
    self.muted = muted
    self.codec = codec
    self.bitrateKbps = bitrateKbps
    self.jitterMilliseconds = jitterMilliseconds
    self.lossPercent = lossPercent
    self.receiveBufferMilliseconds = receiveBufferMilliseconds
    self.receiveBufferTargetMilliseconds = receiveBufferTargetMilliseconds
    self.concealedPercent = concealedPercent
    self.audioLevel = audioLevel
    self.packetsLostTotal = packetsLostTotal
    self.packetsReceivedTotal = packetsReceivedTotal
    self.connectionQuality = connectionQuality
  }
}

public struct InlineRTCServerInfo: Equatable, Sendable {
  public let host: String?
  public let region: String?
  public let nodeID: String?
  public let version: String?
  public let roomSid: String?

  public init(host: String?, region: String?, nodeID: String?, version: String?, roomSid: String?) {
    self.host = host
    self.region = region
    self.nodeID = nodeID
    self.version = version
    self.roomSid = roomSid
  }
}

/// One periodic measurement of the active room.
public struct InlineRTCDiagnosticsSample: Equatable, Sendable {
  public let time: Date
  public let server: InlineRTCServerInfo
  public let localConnectionQuality: String
  public let publisher: InlineRTCTransportStats?
  public let subscriber: InlineRTCTransportStats?
  public let outgoing: InlineRTCOutgoingAudioStats?
  public let incoming: [InlineRTCIncomingAudioStats]
  /// Output and input device latency reported by the audio engine.
  public let outputDeviceDelayMilliseconds: Double?
  public let inputDeviceDelayMilliseconds: Double?

  public init(
    time: Date,
    server: InlineRTCServerInfo,
    localConnectionQuality: String,
    publisher: InlineRTCTransportStats?,
    subscriber: InlineRTCTransportStats?,
    outgoing: InlineRTCOutgoingAudioStats?,
    incoming: [InlineRTCIncomingAudioStats],
    outputDeviceDelayMilliseconds: Double? = nil,
    inputDeviceDelayMilliseconds: Double? = nil
  ) {
    self.time = time
    self.server = server
    self.localConnectionQuality = localConnectionQuality
    self.publisher = publisher
    self.subscriber = subscriber
    self.outgoing = outgoing
    self.incoming = incoming
    self.outputDeviceDelayMilliseconds = outputDeviceDelayMilliseconds
    self.inputDeviceDelayMilliseconds = inputDeviceDelayMilliseconds
  }

  func withDeviceDelays(input: Double?, output: Double?) -> Self {
    Self(
      time: time,
      server: server,
      localConnectionQuality: localConnectionQuality,
      publisher: publisher,
      subscriber: subscriber,
      outgoing: outgoing,
      incoming: incoming,
      outputDeviceDelayMilliseconds: output,
      inputDeviceDelayMilliseconds: input
    )
  }

  /// Round trip used for one network leg; the RTCP measurement is preferred
  /// because ICE pair RTT can be stale on an idle transport.
  public var uplinkRoundTripMilliseconds: Double? {
    outgoing?.serverRoundTripMilliseconds ?? publisher?.roundTripMilliseconds
  }

  public var downlinkRoundTripMilliseconds: Double? {
    subscriber?.roundTripMilliseconds ?? publisher?.roundTripMilliseconds
  }

  /// Estimated mouth-to-ear delay for one remote speaker. The remote sender's
  /// upload leg is not observable here, so it is assumed to match ours.
  public func estimatedDelay(for incoming: InlineRTCIncomingAudioStats) -> InlineRTCDelayEstimate {
    let downlink = downlinkRoundTripMilliseconds.map { $0 / 2 }
    let uplink = uplinkRoundTripMilliseconds.map { $0 / 2 } ?? downlink
    let network = (uplink ?? 0) + (downlink ?? 0)
    let buffer = incoming.receiveBufferMilliseconds ?? 0
    // Opus 20 ms framing plus sender capture and our playout device.
    let devices = 20 + (inputDeviceDelayMilliseconds ?? 10) + (outputDeviceDelayMilliseconds ?? 10)
    return InlineRTCDelayEstimate(
      networkMilliseconds: network,
      receiveBufferMilliseconds: buffer,
      deviceMilliseconds: devices
    )
  }

  public var worstIncoming: InlineRTCIncomingAudioStats? {
    incoming.max { estimatedDelay(for: $0).totalMilliseconds < estimatedDelay(for: $1).totalMilliseconds }
  }
}

public struct InlineRTCDelayEstimate: Equatable, Sendable {
  public let networkMilliseconds: Double
  public let receiveBufferMilliseconds: Double
  public let deviceMilliseconds: Double

  public var totalMilliseconds: Double {
    networkMilliseconds + receiveBufferMilliseconds + deviceMilliseconds
  }
}

public struct InlineRTCDiagnosticsEvent: Equatable, Sendable, Identifiable {
  public enum Severity: String, Sendable {
    case info
    case warning
    case error
  }

  public let id: UInt64
  public let time: Date
  public let severity: Severity
  public let message: String

  public init(id: UInt64, time: Date, severity: Severity, message: String) {
    self.id = id
    self.time = time
    self.severity = severity
    self.message = message
  }
}

public struct InlineRTCDiagnosticsReport: Equatable, Sendable {
  public static let sampleInterval: Duration = .seconds(2)

  public let generatedAt: Date
  public let callStartedAt: Date?
  public let state: InlineRTCState?
  public let samples: [InlineRTCDiagnosticsSample]
  public let events: [InlineRTCDiagnosticsEvent]

  public init(
    generatedAt: Date,
    callStartedAt: Date?,
    state: InlineRTCState?,
    samples: [InlineRTCDiagnosticsSample],
    events: [InlineRTCDiagnosticsEvent]
  ) {
    self.generatedAt = generatedAt
    self.callStartedAt = callStartedAt
    self.state = state
    self.samples = samples
    self.events = events
  }

  public var latest: InlineRTCDiagnosticsSample? { samples.last }
}

// MARK: - Interval math

/// Cumulative WebRTC counters for one inbound audio stream.
struct GridInboundAudioCounters: Equatable, Sendable {
  var timestampMicroseconds: Double
  var bytesReceived: UInt64?
  var packetsReceived: UInt64?
  var packetsLost: Int64?
  var jitterBufferDelaySeconds: Double?
  var jitterBufferEmittedCount: UInt64?
  var concealedSamples: UInt64?
  var totalSamplesReceived: UInt64?
}

/// Cumulative WebRTC counters for one outbound audio stream.
struct GridOutboundAudioCounters: Equatable, Sendable {
  var timestampMicroseconds: Double
  var bytesSent: UInt64?
  var packetsSent: UInt64?
  var retransmittedPacketsSent: UInt64?
}

struct GridInboundAudioInterval: Equatable, Sendable {
  var bitrateKbps: Double?
  var lossPercent: Double?
  var receiveBufferMilliseconds: Double?
  var concealedPercent: Double?
}

struct GridOutboundAudioInterval: Equatable, Sendable {
  var bitrateKbps: Double?
  var packetsPerSecond: Double?
  var retransmittedPacketsPerSecond: Double?
}

enum GridDiagnosticsMath {
  static func interval(
    from previous: GridInboundAudioCounters?,
    to current: GridInboundAudioCounters
  ) -> GridInboundAudioInterval {
    guard let previous else {
      // First observation: the lifetime average is the best available value.
      return GridInboundAudioInterval(
        bitrateKbps: nil,
        lossPercent: ratioPercent(
          part: current.packetsLost.map { Double(max($0, 0)) },
          whole: sum(current.packetsLost.map { Double(max($0, 0)) }, current.packetsReceived.map { Double($0) })
        ),
        receiveBufferMilliseconds: perItemMilliseconds(
          seconds: current.jitterBufferDelaySeconds,
          count: current.jitterBufferEmittedCount.map { Double($0) }
        ),
        concealedPercent: ratioPercent(
          part: current.concealedSamples.map { Double($0) },
          whole: current.totalSamplesReceived.map { Double($0) }
        )
      )
    }
    let seconds = (current.timestampMicroseconds - previous.timestampMicroseconds) / 1_000_000
    let lost = delta(current.packetsLost.map { Double($0) }, previous.packetsLost.map { Double($0) }).map { max($0, 0) }
    let received = delta(current.packetsReceived.map { Double($0) }, previous.packetsReceived.map { Double($0) })
    return GridInboundAudioInterval(
      bitrateKbps: rate(
        delta(current.bytesReceived.map { Double($0) }, previous.bytesReceived.map { Double($0) }).map { $0 * 8 / 1_000 },
        seconds: seconds
      ),
      lossPercent: ratioPercent(part: lost, whole: sum(lost, received)),
      receiveBufferMilliseconds: perItemMilliseconds(
        seconds: delta(current.jitterBufferDelaySeconds, previous.jitterBufferDelaySeconds),
        count: delta(
          current.jitterBufferEmittedCount.map { Double($0) },
          previous.jitterBufferEmittedCount.map { Double($0) }
        )
      ),
      concealedPercent: ratioPercent(
        part: delta(current.concealedSamples.map { Double($0) }, previous.concealedSamples.map { Double($0) }),
        whole: delta(current.totalSamplesReceived.map { Double($0) }, previous.totalSamplesReceived.map { Double($0) })
      )
    )
  }

  static func interval(
    from previous: GridOutboundAudioCounters?,
    to current: GridOutboundAudioCounters
  ) -> GridOutboundAudioInterval {
    guard let previous else { return GridOutboundAudioInterval() }
    let seconds = (current.timestampMicroseconds - previous.timestampMicroseconds) / 1_000_000
    return GridOutboundAudioInterval(
      bitrateKbps: rate(
        delta(current.bytesSent.map { Double($0) }, previous.bytesSent.map { Double($0) }).map { $0 * 8 / 1_000 },
        seconds: seconds
      ),
      packetsPerSecond: rate(
        delta(current.packetsSent.map { Double($0) }, previous.packetsSent.map { Double($0) }),
        seconds: seconds
      ),
      retransmittedPacketsPerSecond: rate(
        delta(
          current.retransmittedPacketsSent.map { Double($0) },
          previous.retransmittedPacketsSent.map { Double($0) }
        ),
        seconds: seconds
      )
    )
  }

  /// A counter that went backwards means the stream was replaced; there is no
  /// meaningful interval value for that sample.
  private static func delta(_ current: Double?, _ previous: Double?) -> Double? {
    guard let current, let previous, current >= previous else { return nil }
    return current - previous
  }

  private static func sum(_ lhs: Double?, _ rhs: Double?) -> Double? {
    guard let lhs, let rhs else { return nil }
    return lhs + rhs
  }

  private static func rate(_ value: Double?, seconds: Double) -> Double? {
    guard let value, seconds > 0 else { return nil }
    return value / seconds
  }

  private static func ratioPercent(part: Double?, whole: Double?) -> Double? {
    guard let part, let whole, whole > 0 else { return nil }
    return part / whole * 100
  }

  private static func perItemMilliseconds(seconds: Double?, count: Double?) -> Double? {
    guard let seconds, let count, count > 0 else { return nil }
    return seconds / count * 1_000
  }
}
