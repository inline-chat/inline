import Foundation
import LiveKit

/// Private provider tuning for InlineRTC's LiveKit implementation.
///
/// Keep product defaults here rather than scattering SDK options through the
/// connection controller. This makes experiments reviewable and gives a future
/// settings/debug surface one typed source of truth. This is intentionally not
/// part of InlineRTC's public API: applications express media intent, not
/// provider policy.
struct InlineRTCConfiguration: Equatable, Sendable {
  public var connection: Connection
  public var capture: Capture
  public var publishing: Publishing
  public var voiceProcessing: VoiceProcessing

  public init(
    connection: Connection = .init(),
    capture: Capture = .init(),
    publishing: Publishing = .init(),
    voiceProcessing: VoiceProcessing = .init()
  ) {
    self.connection = connection
    self.capture = capture
    self.publishing = publishing
    self.voiceProcessing = voiceProcessing
  }

  /// Voice-first defaults. Video-specific adaptive stream and dynacast remain
  /// disabled until Grid gains camera or screen sharing.
  public static let voice = InlineRTCConfiguration()

  public struct Connection: Equatable, Sendable {
    /// Resolve the nearest LiveKit Cloud edge immediately before signaling.
    /// This is an experimental diagnostic switch: discovery performs no
    /// WebRTC or microphone work, but a measured late preparation added about
    /// 1.25 seconds. Keep it off until preparation can overlap solo presence
    /// rather than extending click-to-connect latency.
    public var prepareCloudConnection = false
    /// Subscribe to remote tracks automatically. Grid needs this for voice.
    public var autoSubscribe = true
    /// Total LiveKit reconnect attempts after an established connection drops.
    /// At the default maximum delay, 180 attempts cover roughly 20 minutes.
    /// Inline also has an indefinite recovery loop after the SDK gives up.
    public var reconnectAttempts = 180
    /// First reconnect delay in seconds.
    public var reconnectAttemptDelay: TimeInterval = 0.3
    /// Maximum reconnect delay in seconds.
    public var reconnectMaximumDelay: TimeInterval = 7
    /// Timeout for the initial LiveKit signaling WebSocket.
    public var socketConnectTimeout: TimeInterval = 15
    /// Timeout for the subscriber/primary WebRTC transport.
    public var primaryTransportConnectTimeout: TimeInterval = 15
    /// Timeout for the publisher WebRTC transport.
    public var publisherTransportConnectTimeout: TimeInterval = 15
    /// Emit a diagnostic while an initial connection is still pending. This
    /// does not disturb the attempt; it makes regressions visible before the
    /// transport's longer failure timeout. Set to zero to disable.
    public var initialConnectSlowWarningDelay: TimeInterval = 5
    /// Rebuild an initial connection that remains stuck beyond this duration.
    /// Like Noor's peer watchdog, the callback is guarded by both the logical
    /// room generation and the concrete LiveKit room handle before acting.
    /// Set to zero to disable.
    public var initialConnectWatchdogTimeout: TimeInterval = 12
    /// Wait briefly for a healthy microphone graph before connecting. After
    /// this bound Grid joins listen-only and repairs publication separately,
    /// so a poisoned input device cannot block remote audio indefinitely.
    public var audioPreparationConnectWaitTimeout: TimeInterval = 1.5
    /// Rebuild the room if a microphone publication call never completes.
    public var microphonePublishWatchdogTimeout: TimeInterval = 8
    /// Rebuild the room if an SDK mute reconciliation never completes.
    public var microphoneMuteWatchdogTimeout: TimeInterval = 3
    /// Give a retiring room a brief chance to finish before a replacement
    /// starts. Normal LiveKit disconnects complete in tens of milliseconds;
    /// bounding this wait prevents a pathological teardown from recreating the
    /// old multi-second leave/join hang.
    public var retirementBarrierTimeout: TimeInterval = 0.25
    /// Maximum time Grid retains its own audio leases and shutdown bookkeeping
    /// for a retiring provider room. The LiveKit disconnect may continue
    /// independently after this bound, but it can no longer block a new room,
    /// logout, or process audio cleanup.
    public var providerTeardownTimeout: TimeInterval = 3
    /// Silencing is best effort and must not prevent provider teardown from
    /// starting. This bounds logical ownership if the SDK mute path is stuck.
    public var roomSilenceTimeout: TimeInterval = 0.25
    /// Maximum cancellation-insensitive LiveKit calls Grid permits to remain
    /// suspended before opening an app-owned circuit. One replacement attempt
    /// is useful when an individual Room is poisoned; more retries would only
    /// accumulate tasks if the shared SDK/native layer is wedged. The circuit
    /// closes automatically when any retired operation eventually returns.
    public var maxAbandonedProviderOperations = 2
    /// First PCM health check after unmuting. This is long enough for the audio
    /// graph to deliver its first buffer while still surfacing a dead capture
    /// path promptly.
    public var localAudioFlowStartupTimeout: TimeInterval = 1
    /// Recheck PCM throughout a long-running unmuted call. The check compares
    /// frame counters off the real-time thread and remains silent while healthy.
    public var localAudioFlowCheckInterval: TimeInterval = 5
    /// While LiveKit reports a remote participant as speaking, require decoded
    /// PCM to advance within this interval. Checks stop when speaking stops so
    /// DTX/silent rooms are never classified as broken.
    public var remoteAudioFlowCheckInterval: TimeInterval = 0.75
    /// Consecutive speaking-window misses required before surfacing degraded
    /// incoming audio. Two avoids reacting to a single short speech boundary.
    public var remoteAudioFlowMissThreshold = 2
    /// Publish an already-enabled microphone as part of `Room.connect()`.
    /// Keep this off for Grid: LiveKit waits for publication before returning
    /// from connect, so a slow input device can incorrectly hold the whole room
    /// in "connecting" for many seconds. Grid warms muted capture separately,
    /// marks the transport connected, then reconciles publication asynchronously.
    public var publishEnabledMicrophoneDuringConnect = false
    /// Allow differentiated-services markings when a publishing priority requests it.
    public var differentiatedServicesCodePointEnabled = false
    /// Use one publisher-primary peer connection for both publishing and
    /// subscribing. Grid always does both, and LiveKit's dual-PC mode otherwise
    /// negotiates a second publisher transport during initial connection. Our
    /// Cloud deployment supports the v1 RTC path; the SDK falls back to dual-PC
    /// mode automatically when an endpoint does not.
    public var singlePeerConnection = true

    public init() {}
  }

  public struct Capture: Equatable, Sendable {
    /// Request WebRTC echo cancellation for the published microphone track.
    /// The exact processor remains provider-owned; this is independent of
    /// Grid's macOS HAL versus AVAudioEngine device-routing choice.
    public var echoCancellation = true
    /// Request WebRTC automatic gain control for the published track.
    public var automaticGainControl = true
    /// Request WebRTC noise suppression. Enhanced providers such as Krisp
    /// require a separate custom audio processor.
    public var noiseSuppression = true
    /// Remove very low-frequency energy before encoding.
    public var highPassFilter = false
    /// Ask WebRTC audio processing to detect typing noise where supported.
    public var typingNoiseDetection = true

    public init() {}
  }

  public struct Publishing: Equatable, Sendable {
    /// Opus bitrate preset. Speech is the voice-room default.
    public var quality: Quality = .speech
    /// Discontinuous transmission avoids sending Opus frames during silence.
    public var discontinuousTransmission = true
    /// Opus RED adds redundant audio data for loss recovery at a bandwidth cost.
    public var redundantEncoding = true
    /// Optional LiveKit track name for diagnostics or future mixed media tracks.
    public var trackName: String?

    public init() {}

    public enum Quality: Int, CaseIterable, Equatable, Sendable {
      case telephone = 12_000
      case speech = 24_000
      case music = 48_000
      case musicStereo = 64_000
      case musicHighQuality = 96_000
      case musicHighQualityStereo = 128_000
    }
  }

  public struct VoiceProcessing: Equatable, Sendable {
    /// AVAudioEngine-backend-only Apple Voice Processing I/O experiment. Grid's
    /// default macOS HAL backend ignores this entire section. A measured cold
    /// start took about seven seconds with VPIO enabled versus under one second
    /// without it, so it remains off. Changing it requires an engine restart.
    public var enabled = false
    /// Bypass VPIO while keeping the processing-capable audio path initialized.
    /// Useful for music experiments; normally false for conversation.
    public var bypassed = false
    /// Apple's VPIO automatic gain control. This is effective on macOS.
    public var automaticGainControlEnabled = true
    /// Keep mute/unmute independent from device and engine setup. Input mixer
    /// is the closest SDK-supported match to Noor's always-running capture path:
    /// it silences frames without reconfiguring AVAudioEngine and avoids the
    /// system mute sound. The microphone indicator remains on while Grid keeps
    /// an active connection prepared. Restart is intentionally available only
    /// for experiments because it makes unmute pay cold-engine latency.
    public var microphoneMuteMode: MicrophoneMuteMode = .inputMixer
    /// Dynamically duck other audio based on speech activity.
    public var advancedDuckingEnabled = false
    /// How much non-Grid audio is reduced while voice processing is active.
    public var duckingLevel: DuckingLevel = .minimum

    public init() {}

    public enum DuckingLevel: Equatable, Sendable {
      case systemDefault
      case minimum
      case medium
      case maximum
    }

    public enum MicrophoneMuteMode: String, CaseIterable, Equatable, Sendable {
      case voiceProcessing
      case inputMixer
      case restart
    }
  }

  func makeConnectOptions(microphoneEnabled: Bool) -> ConnectOptions {
    ConnectOptions(
      autoSubscribe: connection.autoSubscribe,
      reconnectAttempts: connection.reconnectAttempts,
      reconnectAttemptDelay: connection.reconnectAttemptDelay,
      reconnectMaxDelay: connection.reconnectMaximumDelay,
      socketConnectTimeoutInterval: connection.socketConnectTimeout,
      primaryTransportConnectTimeout: connection.primaryTransportConnectTimeout,
      publisherTransportConnectTimeout: connection.publisherTransportConnectTimeout,
      isDscpEnabled: connection.differentiatedServicesCodePointEnabled,
      enableMicrophone: connection.publishEnabledMicrophoneDuringConnect && microphoneEnabled
    )
  }

  func makeRoomOptions() -> RoomOptions {
    RoomOptions(
      defaultAudioCaptureOptions: AudioCaptureOptions(
        echoCancellation: capture.echoCancellation,
        autoGainControl: capture.automaticGainControl,
        noiseSuppression: capture.noiseSuppression,
        highpassFilter: capture.highPassFilter,
        typingNoiseDetection: capture.typingNoiseDetection
      ),
      defaultAudioPublishOptions: AudioPublishOptions(
        name: publishing.trackName,
        encoding: AudioEncoding(maxBitrate: publishing.quality.rawValue),
        dtx: publishing.discontinuousTransmission,
        red: publishing.redundantEncoding
      ),
      singlePeerConnection: connection.singlePeerConnection
    )
  }

  func applyVoiceProcessing() throws {
    let manager = AudioManager.shared
    if manager.isVoiceProcessingEnabled != voiceProcessing.enabled {
      try manager.setVoiceProcessingEnabled(voiceProcessing.enabled)
    }
    let microphoneMuteMode: LiveKit.MicrophoneMuteMode = switch voiceProcessing.microphoneMuteMode {
    case .voiceProcessing: .voiceProcessing
    case .inputMixer: .inputMixer
    case .restart: .restart
    }
    try manager.set(microphoneMuteMode: microphoneMuteMode)
    manager.isVoiceProcessingBypassed = voiceProcessing.bypassed
    manager.isVoiceProcessingAGCEnabled = voiceProcessing.automaticGainControlEnabled
    manager.isAdvancedDuckingEnabled = voiceProcessing.advancedDuckingEnabled
    manager.duckingLevel = switch voiceProcessing.duckingLevel {
    case .systemDefault: .default
    case .minimum: .min
    case .medium: .mid
    case .maximum: .max
    }
  }
}
