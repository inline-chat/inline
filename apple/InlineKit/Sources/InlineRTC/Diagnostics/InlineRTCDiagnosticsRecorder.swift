import Foundation

/// Bounded call history for diagnostics. Owned by `InlineRTCSession`, so all
/// mutation happens on that actor. Turns engine snapshot transitions and stats
/// thresholds into a short event timeline next to the raw samples.
struct InlineRTCDiagnosticsRecorder {
  static let sampleCapacity = 450 // 15 minutes at the 2 s sample interval.
  static let eventCapacity = 300
  static let highReceiveBufferMilliseconds = 400.0
  static let highRoundTripMilliseconds = 300.0

  private(set) var samples: [InlineRTCDiagnosticsSample] = []
  private(set) var events: [InlineRTCDiagnosticsEvent] = []
  private(set) var callStartedAt: Date?
  private var nextEventID: UInt64 = 0
  private var previousState: InlineRTCState?
  private var highBufferIdentities = Set<String>()
  private var highRoundTrip = false

  func report(state: InlineRTCState?, now: Date = Date()) -> InlineRTCDiagnosticsReport {
    InlineRTCDiagnosticsReport(
      generatedAt: now,
      callStartedAt: callStartedAt,
      state: state,
      samples: samples,
      events: events
    )
  }

  mutating func observe(_ state: InlineRTCState, now: Date = Date()) {
    defer { previousState = state }
    let rtc = state.rtc
    let previousRTC = previousState?.rtc

    if previousRTC?.target != rtc.target {
      if let target = rtc.target {
        // A new call starts a fresh history; switching rooms is a new call.
        samples.removeAll()
        events.removeAll()
        highBufferIdentities.removeAll()
        highRoundTrip = false
        callStartedAt = now
        append(.info, "Call started (\(target.rawValue))", now)
      } else if previousRTC?.target != nil {
        append(.info, "Call ended", now)
      }
    }

    if previousRTC?.state != rtc.state {
      let label = Self.label(rtc.state, connectMilliseconds: rtc.lastConnectMilliseconds)
      append(Self.severity(rtc.state), label, now)
    }
    if let previousRTC, rtc.reconnectCount > previousRTC.reconnectCount {
      append(.warning, "Reconnected (\(rtc.reconnectCount) total)", now)
    }
    if previousRTC?.microphonePublicationState != rtc.microphonePublicationState {
      switch rtc.microphonePublicationState {
      case let .failed(message, attempt):
        append(.error, "Microphone publish failed (attempt \(attempt)): \(message)", now)
      case .published:
        append(.info, "Microphone published", now)
      default:
        break
      }
    }
    if let previousRTC, previousRTC.microphoneMuted != rtc.microphoneMuted {
      append(.info, rtc.microphoneMuted ? "Microphone muted" : "Microphone unmuted", now)
    }
    if previousRTC?.localAudioFlowState != rtc.localAudioFlowState, rtc.localAudioFlowState == .missing {
      append(.error, "Outgoing microphone audio stopped flowing", now)
    }
    for (identity, flow) in rtc.remoteAudioFlowStates where previousRTC?.remoteAudioFlowStates[identity] != flow {
      if flow == .missing {
        append(.error, "Incoming audio stalled from \(identity)", now)
      } else if flow == .flowing, previousRTC?.remoteAudioFlowStates[identity] == .missing {
        append(.info, "Incoming audio recovered from \(identity)", now)
      }
    }
    if rtc.providerCircuitOpen, previousRTC?.providerCircuitOpen != true {
      append(.error, "Voice connection paused after repeated provider failures", now)
    }

    let audio = state.audio
    let previousAudio = previousState?.audio
    if previousAudio?.state != audio.state, case let .failed(message) = audio.state {
      append(.error, "Audio engine failed: \(message)", now)
    }
    if previousAudio?.input?.activeDeviceName != audio.input?.activeDeviceName, let name = audio.input?.activeDeviceName {
      append(.info, "Input device: \(name)", now)
    }
    if previousAudio?.output?.activeDeviceName != audio.output?.activeDeviceName, let name = audio.output?.activeDeviceName {
      append(.info, "Output device: \(name)", now)
    }
    if audio.isSafetyPaused, previousAudio?.isSafetyPaused != true {
      append(.warning, "Audio paused for safety", now)
    }
    if let previousAudio, previousAudio.isCaptureHealthy, !audio.isCaptureHealthy, audio.isRecording {
      append(.warning, "Microphone capture unhealthy", now)
    }
    if let previousAudio, previousAudio.isPlayoutHealthy, !audio.isPlayoutHealthy, audio.isPlaying {
      append(.warning, "Speaker playout unhealthy", now)
    }
  }

  mutating func record(_ sample: InlineRTCDiagnosticsSample) {
    let previous = samples.last
    let now = sample.time

    if let previous {
      if previous.localConnectionQuality != sample.localConnectionQuality {
        append(
          Self.severity(quality: sample.localConnectionQuality),
          "Your connection quality: \(sample.localConnectionQuality)",
          now
        )
      }
      let previousQuality = Dictionary(
        previous.incoming.map { ($0.participantIdentity, $0.connectionQuality) },
        uniquingKeysWith: { first, _ in first }
      )
      for incoming in sample.incoming {
        if let before = previousQuality[incoming.participantIdentity], before != incoming.connectionQuality {
          append(
            Self.severity(quality: incoming.connectionQuality),
            "\(incoming.participantIdentity) connection quality: \(incoming.connectionQuality)",
            now
          )
        }
      }
      for (label, before, after) in [
        ("Send path", previous.publisher?.local, sample.publisher?.local),
        ("Receive path", previous.subscriber?.local, sample.subscriber?.local),
      ] where before != nil && after != nil && before != after {
        append(
          after?.isRelay == true || after?.isTCP == true ? .warning : .info,
          "\(label) changed: \(before!.summary) → \(after!.summary)",
          now
        )
      }
    } else {
      for (label, candidate) in [("Send path", sample.publisher?.local), ("Receive path", sample.subscriber?.local)] {
        guard let candidate else { continue }
        append(
          candidate.isRelay || candidate.isTCP ? .warning : .info,
          "\(label): \(candidate.summary)",
          now
        )
      }
    }

    for incoming in sample.incoming {
      guard let buffer = incoming.receiveBufferMilliseconds else { continue }
      let identity = incoming.participantIdentity
      if buffer >= Self.highReceiveBufferMilliseconds, !highBufferIdentities.contains(identity) {
        highBufferIdentities.insert(identity)
        append(.warning, "Receive buffer for \(identity) grew to \(Int(buffer)) ms", now)
      } else if buffer < Self.highReceiveBufferMilliseconds / 2, highBufferIdentities.contains(identity) {
        highBufferIdentities.remove(identity)
        append(.info, "Receive buffer for \(identity) back to \(Int(buffer)) ms", now)
      }
    }
    if let rtt = sample.uplinkRoundTripMilliseconds {
      if rtt >= Self.highRoundTripMilliseconds, !highRoundTrip {
        highRoundTrip = true
        append(.warning, "Round trip to server rose to \(Int(rtt)) ms", now)
      } else if rtt < Self.highRoundTripMilliseconds / 2, highRoundTrip {
        highRoundTrip = false
        append(.info, "Round trip to server back to \(Int(rtt)) ms", now)
      }
    }

    samples.append(sample)
    if samples.count > Self.sampleCapacity {
      samples.removeFirst(samples.count - Self.sampleCapacity)
    }
  }

  private mutating func append(
    _ severity: InlineRTCDiagnosticsEvent.Severity,
    _ message: String,
    _ time: Date
  ) {
    nextEventID &+= 1
    events.append(InlineRTCDiagnosticsEvent(id: nextEventID, time: time, severity: severity, message: message))
    if events.count > Self.eventCapacity {
      events.removeFirst(events.count - Self.eventCapacity)
    }
  }

  static func label(_ state: InlineRTCConnectionState, connectMilliseconds: Int? = nil) -> String {
    switch state {
    case .idle: "Idle"
    case .waitingForCredentials: "Waiting for credentials"
    case .preparingAudio: "Preparing audio"
    case let .connecting(_, attempt): "Connecting (attempt \(attempt))"
    case .connected:
      connectMilliseconds.map { "Connected in \($0) ms" } ?? "Connected"
    case .reconnecting: "Reconnecting"
    case .switching: "Switching rooms"
    case .disconnecting: "Disconnecting"
    case let .backingOff(_, attempt, delaySeconds): "Backing off \(delaySeconds) s (attempt \(attempt))"
    case let .failed(_, message): "Failed: \(message)"
    }
  }

  private static func severity(_ state: InlineRTCConnectionState) -> InlineRTCDiagnosticsEvent.Severity {
    switch state {
    case .reconnecting, .backingOff: .warning
    case .failed: .error
    default: .info
    }
  }

  private static func severity(quality: String) -> InlineRTCDiagnosticsEvent.Severity {
    switch quality {
    case "poor": .warning
    case "lost": .error
    default: .info
    }
  }
}
