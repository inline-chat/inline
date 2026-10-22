import Foundation
import LiveKit

/// Converts LiveKit's per-track WebRTC stats into Inline diagnostics values.
/// Per-room cumulative counters are owned by the driver so interval values
/// (bitrate, loss, receive buffer) cover exactly one sample period.
struct LiveKitGridDiagnosticsCounters: Sendable {
  var inbound: [String: GridInboundAudioCounters] = [:]
  var outbound: [String: GridOutboundAudioCounters] = [:]
}

enum LiveKitGridDiagnostics {
  static func sample(
    room: Room,
    microphoneTrack: LocalAudioTrack?,
    counters: inout LiveKitGridDiagnosticsCounters,
    now: Date = Date()
  ) -> InlineRTCDiagnosticsSample {
    let local = room.localParticipant
    var publisher: InlineRTCTransportStats?
    var outgoing: InlineRTCOutgoingAudioStats?
    var nextOutbound: [String: GridOutboundAudioCounters] = [:]

    if let track = microphoneTrack, let statistics = track.statistics {
      publisher = transport(statistics)
      let stream = statistics.outboundRtpStream.first { $0.kind == nil || $0.kind == "audio" }
      let remoteInbound = statistics.remoteInboundRtpStream.first
      var interval = GridOutboundAudioInterval()
      if let stream {
        let current = GridOutboundAudioCounters(
          timestampMicroseconds: stream.timestamp,
          bytesSent: stream.bytesSent,
          packetsSent: stream.packetsSent,
          retransmittedPacketsSent: stream.retransmittedPacketsSent
        )
        interval = GridDiagnosticsMath.interval(from: counters.outbound[stream.id], to: current)
        nextOutbound[stream.id] = current
      }
      outgoing = InlineRTCOutgoingAudioStats(
        muted: track.isMuted,
        codec: codec(statistics, id: stream?.codecId),
        bitrateKbps: interval.bitrateKbps,
        targetBitrateKbps: stream?.targetBitrate.map { $0 / 1_000 },
        packetsPerSecond: interval.packetsPerSecond,
        retransmittedPacketsPerSecond: interval.retransmittedPacketsPerSecond,
        serverRoundTripMilliseconds: remoteInbound?.roundTripTime.map { $0 * 1_000 },
        serverReportedLossPercent: remoteInbound?.fractionLost.map { $0 * 100 },
        serverReportedJitterMilliseconds: remoteInbound?.jitter.map { $0 * 1_000 }
      )
    }

    var subscriber: InlineRTCTransportStats?
    var incoming: [InlineRTCIncomingAudioStats] = []
    var nextInbound: [String: GridInboundAudioCounters] = [:]
    for participant in room.remoteParticipants.values {
      for publication in participant.audioTracks {
        guard let track = publication.track as? RemoteAudioTrack,
              let statistics = track.statistics,
              let stream = statistics.inboundRtpStream.first
        else { continue }
        if subscriber == nil {
          subscriber = transport(statistics)
        }
        let current = GridInboundAudioCounters(
          timestampMicroseconds: stream.timestamp,
          bytesReceived: stream.bytesReceived,
          packetsReceived: stream.packetsReceived,
          packetsLost: stream.packetsLost,
          jitterBufferDelaySeconds: stream.jitterBufferDelay,
          jitterBufferEmittedCount: stream.jitterBufferEmittedCount,
          concealedSamples: stream.concealedSamples,
          totalSamplesReceived: stream.totalSamplesReceived
        )
        let interval = GridDiagnosticsMath.interval(from: counters.inbound[stream.id], to: current)
        nextInbound[stream.id] = current
        // Target delay is cumulative like jitterBufferDelay; divide by the
        // lifetime emitted count for a stable target value.
        let target: Double? = {
          guard let total = stream.jitterBufferTargetDelay,
                let emitted = stream.jitterBufferEmittedCount,
                emitted > 0
          else { return nil }
          return total / Double(emitted) * 1_000
        }()
        incoming.append(
          InlineRTCIncomingAudioStats(
            participantIdentity: participant.identity?.stringValue ?? "unknown",
            trackSid: publication.sid.stringValue,
            muted: publication.isMuted,
            codec: codec(statistics, id: stream.codecId),
            bitrateKbps: interval.bitrateKbps,
            jitterMilliseconds: stream.jitter.map { $0 * 1_000 },
            lossPercent: interval.lossPercent,
            receiveBufferMilliseconds: interval.receiveBufferMilliseconds,
            receiveBufferTargetMilliseconds: target,
            concealedPercent: interval.concealedPercent,
            audioLevel: stream.audioLevel,
            packetsLostTotal: stream.packetsLost,
            packetsReceivedTotal: stream.packetsReceived,
            connectionQuality: quality(participant.connectionQuality)
          )
        )
      }
    }
    counters.inbound = nextInbound
    counters.outbound = nextOutbound

    return InlineRTCDiagnosticsSample(
      time: now,
      server: InlineRTCServerInfo(
        host: room.url.flatMap { URL(string: $0)?.host },
        region: room.serverRegion,
        nodeID: room.serverNodeId,
        version: room.serverVersion,
        roomSid: room.sid?.stringValue
      ),
      localConnectionQuality: quality(local.connectionQuality),
      publisher: publisher,
      subscriber: subscriber,
      outgoing: outgoing,
      incoming: incoming.sorted { $0.participantIdentity < $1.participantIdentity }
    )
  }

  private static func transport(_ statistics: TrackStatistics) -> InlineRTCTransportStats {
    let selectedID = statistics.transportStats?.selectedCandidatePairId
    let pair = statistics.iceCandidatePair.first { $0.id == selectedID }
      ?? statistics.iceCandidatePair.first { $0.nominated == true && $0.state == .succeeded }
      ?? statistics.iceCandidatePair.first
    return InlineRTCTransportStats(
      roundTripMilliseconds: pair?.currentRoundTripTime.map { $0 * 1_000 },
      availableOutgoingKbps: pair?.availableOutgoingBitrate.map { $0 / 1_000 },
      availableIncomingKbps: pair?.availableIncomingBitrate.map { $0 / 1_000 },
      local: statistics.localIceCandidate.map(candidate),
      remote: statistics.remoteIceCandidate.map(candidate),
      iceState: statistics.transportStats?.iceState?.rawValue,
      dtlsState: statistics.transportStats?.dtlsState?.rawValue
    )
  }

  private static func candidate(_ candidate: IceCandidateStatistics) -> InlineRTCCandidateInfo {
    InlineRTCCandidateInfo(
      type: candidate.candidateType?.rawValue,
      transportProtocol: candidate.protocol,
      relayProtocol: candidate.relayProtocol?.rawValue
    )
  }

  private static func codec(_ statistics: TrackStatistics, id: String?) -> String? {
    let codec = statistics.codec.first { $0.id == id } ?? statistics.codec.first
    guard let mimeType = codec?.mimeType else { return nil }
    return mimeType.split(separator: "/").last.map(String.init) ?? mimeType
  }

  static func quality(_ quality: ConnectionQuality) -> String {
    switch quality {
    case .unknown: "unknown"
    case .lost: "lost"
    case .poor: "poor"
    case .good: "good"
    case .excellent: "excellent"
    @unknown default: "unknown"
    }
  }
}
