import Foundation
import LiveKit

/// A sender-side proof that an unmuted microphone track is advancing through
/// WebRTC's outbound RTP path. Physical AUHAL callback/readback health is
/// checked separately by `GridAudioEngine`; combining the two observations
/// covers both sides of the custom audio-device boundary without depending on
/// LiveKit's capture renderer, which is not connected to the factory-owned APM
/// when official M144 is initialized with a custom `RTCAudioDevice`.
struct GridLocalAudioTransportSnapshot: Equatable, Sendable {
  struct Stream: Equatable, Sendable {
    let id: String
    let timestamp: Double
    let packetsSent: UInt64
    let bytesSent: UInt64
  }

  static let empty = GridLocalAudioTransportSnapshot(streams: [])

  let streams: [String: Stream]

  init(statistics: TrackStatistics?) {
    self.init(
      streams: statistics?.outboundRtpStream.compactMap { stream in
        guard stream.kind == nil || stream.kind == "audio",
              stream.active != false
        else { return nil }
        return Stream(
          id: stream.id,
          timestamp: stream.timestamp,
          packetsSent: stream.packetsSent ?? 0,
          bytesSent: stream.bytesSent ?? 0
        )
      } ?? []
    )
  }

  init(streams: [Stream]) {
    self.streams = Dictionary(streams.map { ($0.id, $0) }, uniquingKeysWith: { _, next in next })
  }

  var packetCount: UInt64 {
    streams.values.reduce(0) { Self.saturatingAdd($0, $1.packetsSent) }
  }

  var byteCount: UInt64 {
    streams.values.reduce(0) { Self.saturatingAdd($0, $1.bytesSent) }
  }

  /// Proves that at least one active outbound audio stream moved after the
  /// baseline. A new stream with nonzero counters covers sender replacement;
  /// a counter reset with a newer stats timestamp covers transport recovery.
  func hasProgress(since baseline: Self) -> Bool {
    streams.values.contains { current in
      guard current.packetsSent > 0 || current.bytesSent > 0 else { return false }
      guard let previous = baseline.streams[current.id] else { return true }
      guard current.timestamp > previous.timestamp else { return false }
      if current.packetsSent > previous.packetsSent
        || current.bytesSent > previous.bytesSent {
        return true
      }
      return current.packetsSent < previous.packetsSent
        || current.bytesSent < previous.bytesSent
    }
  }

  private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let result = lhs.addingReportingOverflow(rhs)
    return result.overflow ? .max : result.partialValue
  }
}

enum GridLocalAudioTransportObservation: Equatable, Sendable {
  case flowing
  case suspect(consecutiveMisses: Int)
  case missing(consecutiveMisses: Int)
}

/// A single statistics sample is not a terminal sender failure. Track misses
/// within one actor-owned microphone/room epoch and escalate only after the
/// configured confirmation count.
struct GridLocalAudioTransportProof: Equatable, Sendable {
  let missThreshold: Int
  private(set) var consecutiveMisses = 0

  init(missThreshold: Int) {
    self.missThreshold = max(missThreshold, 1)
  }

  mutating func observe(hasProgress: Bool) -> GridLocalAudioTransportObservation {
    if hasProgress {
      consecutiveMisses = 0
      return .flowing
    }
    consecutiveMisses += 1
    if consecutiveMisses >= missThreshold {
      return .missing(consecutiveMisses: consecutiveMisses)
    }
    return .suspect(consecutiveMisses: consecutiveMisses)
  }

  mutating func reset() {
    consecutiveMisses = 0
  }
}
