import Foundation

/// An application-defined identity for one logical media session.
///
/// InlineRTC deliberately treats this value as opaque. Product concepts such
/// as spaces, rooms, generations, RPCs, and server updates stay in the app or
/// InlineKit and are translated to this identifier at the module boundary.
public struct InlineRTCSessionID: RawRepresentable, Equatable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    precondition(!rawValue.isEmpty, "An InlineRTC session ID cannot be empty")
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.init(rawValue: rawValue)
  }
}

public struct InlineRTCCredentials: Equatable, Sendable {
  public let target: InlineRTCSessionID
  public let serverURL: URL
  public let participantIdentity: String
  public let token: String
  public let expiresAt: Date

  public init(
    target: InlineRTCSessionID,
    serverURL: URL,
    participantIdentity: String,
    token: String,
    expiresAt: Date
  ) {
    self.target = target
    self.serverURL = serverURL
    self.participantIdentity = participantIdentity
    self.token = token
    self.expiresAt = expiresAt
  }

  public var isExpired: Bool {
    expiresAt <= Date()
  }
}

public struct InlineRTCDemand: Equatable, Sendable {
  public var target: InlineRTCSessionID?
  public var credentials: InlineRTCCredentials?
  public var microphoneEnabled: Bool
  public var input: AudioInputSelection
  public var outputVolume: Float

  public init(
    target: InlineRTCSessionID? = nil,
    credentials: InlineRTCCredentials? = nil,
    microphoneEnabled: Bool = false,
    input: AudioInputSelection = .automatic,
    outputVolume: Float = 1
  ) {
    self.target = target
    self.credentials = credentials
    self.microphoneEnabled = microphoneEnabled
    self.input = input
    self.outputVolume = min(max(outputVolume, 0), 1)
  }
}

enum GridAudioDriverEvent: Equatable, Sendable {
  case devicesChanged
  case engineStarting(playout: Bool, recording: Bool)
  case engineStopped(playout: Bool, recording: Bool)
  case engineDisabled(playout: Bool, recording: Bool)
  case expectedEngineStop(playout: Bool, recording: Bool)
  case expectedEngineDisable(playout: Bool, recording: Bool)
}

enum GridAudioLease: Equatable, Hashable, Sendable {
  case connectionDemand(InlineRTCSessionID)
  case rtcLifecycle(UUID)
}

public enum InlineRTCAudioState: Equatable, Sendable {
  case cold
  case configuring
  case waitingForPermission
  case permissionDenied
  case warming
  case ready
  case coolingDown
  case stopping
  case failed(String)
}

public struct InlineRTCAudioRoute: Equatable, Sendable {
  public let currentInputID: String?
  public let defaultInputID: String?
  public let currentOutputID: String?
  public let defaultOutputID: String?
  public let inputDeviceCount: Int
  public let outputDeviceCount: Int
  public let isInputRouteValid: Bool
  public let isOutputRouteValid: Bool
  public let routeEpoch: UInt64

  public init(
    currentInputID: String?,
    defaultInputID: String?,
    currentOutputID: String?,
    defaultOutputID: String?,
    inputDeviceCount: Int,
    outputDeviceCount: Int,
    isInputRouteValid: Bool,
    isOutputRouteValid: Bool,
    routeEpoch: UInt64 = 0
  ) {
    self.currentInputID = currentInputID
    self.defaultInputID = defaultInputID
    self.currentOutputID = currentOutputID
    self.defaultOutputID = defaultOutputID
    self.inputDeviceCount = inputDeviceCount
    self.outputDeviceCount = outputDeviceCount
    self.isInputRouteValid = isInputRouteValid
    self.isOutputRouteValid = isOutputRouteValid
    self.routeEpoch = routeEpoch
  }
}

struct GridAudioRuntimeHealth: Equatable, Sendable {
  let isEngineRunning: Bool
  let isRecording: Bool
  let isPlaying: Bool
  let route: InlineRTCAudioRoute?

  init(
    isEngineRunning: Bool,
    isRecording: Bool? = nil,
    isPlaying: Bool? = nil,
    route: InlineRTCAudioRoute?
  ) {
    self.isEngineRunning = isEngineRunning
    // Test and alternate drivers that only expose the legacy aggregate fact
    // retain their previous semantics. LiveKit supplies the concrete ADM facts.
    self.isRecording = isRecording ?? isEngineRunning
    self.isPlaying = isPlaying ?? isEngineRunning
    self.route = route
  }

  var isHealthy: Bool {
    isEngineRunning
      && isRecording
      && route?.isInputRouteValid != false
      && route?.isOutputRouteValid != false
  }
}

public struct InlineRTCAudioSnapshot: Equatable, Sendable {
  public let state: InlineRTCAudioState
  public let isPrepared: Bool
  public let captureLeaseCount: Int
  public let input: ResolvedAudioInput?
  public let route: InlineRTCAudioRoute?
  public let outputVolume: Float
  public let lastTransitionMilliseconds: Int?
  public let microphonePermission: InlineRTCMicrophonePermission

  public init(
    state: InlineRTCAudioState,
    isPrepared: Bool,
    captureLeaseCount: Int,
    input: ResolvedAudioInput?,
    route: InlineRTCAudioRoute? = nil,
    outputVolume: Float,
    lastTransitionMilliseconds: Int?,
    microphonePermission: InlineRTCMicrophonePermission
  ) {
    self.state = state
    self.isPrepared = isPrepared
    self.captureLeaseCount = captureLeaseCount
    self.input = input
    self.route = route
    self.outputVolume = outputVolume
    self.lastTransitionMilliseconds = lastTransitionMilliseconds
    self.microphonePermission = microphonePermission
  }
}

struct GridRTCRoomHandle: Equatable, Hashable, Sendable {
  let id: UUID

  init(id: UUID = UUID()) {
    self.id = id
  }
}

public struct InlineRTCParticipant: Equatable, Sendable {
  public let identity: String
  public let isSpeaking: Bool
  public let audioLevel: Float

  public init(identity: String, isSpeaking: Bool, audioLevel: Float) {
    self.identity = identity
    self.isSpeaking = isSpeaking
    self.audioLevel = audioLevel
  }
}

enum GridRTCReconnectMode: String, Equatable, Sendable {
  case quick
  case full
}

enum GridRTCLifecycleEvent: Equatable, Sendable {
  case reconnecting(mode: GridRTCReconnectMode)
  case reconnected(mode: GridRTCReconnectMode)
  case localMicrophonePublished(muted: Bool)
  case localMicrophoneUnpublished
  case localAudioFlow(InlineRTCAudioFlowState)
  case remoteAudioFlow(identity: String, state: InlineRTCAudioFlowState)
  case disconnected(error: String?)
}

struct GridRTCLifecycleEventEnvelope: Equatable, Sendable {
  let room: GridRTCRoomHandle
  let event: GridRTCLifecycleEvent
}

struct GridRTCParticipantSnapshotEnvelope: Equatable, Sendable {
  let room: GridRTCRoomHandle
  let participants: [InlineRTCParticipant]
}

public enum InlineRTCConnectionState: Equatable, Sendable {
  case idle
  case waitingForCredentials(InlineRTCSessionID)
  case preparingAudio(InlineRTCSessionID)
  case connecting(InlineRTCSessionID, attempt: Int)
  case connected(InlineRTCSessionID)
  case reconnecting(InlineRTCSessionID)
  case switching(from: InlineRTCSessionID, to: InlineRTCSessionID)
  case disconnecting(InlineRTCSessionID)
  case backingOff(InlineRTCSessionID, attempt: Int, delaySeconds: Int)
  case failed(InlineRTCSessionID?, String)
}

/// Microphone publication is deliberately independent from the RTC room's
/// transport state. A participant can remain connected and hear the room while
/// a failed publication is retried in the background.
public enum InlineRTCMicrophoneState: Equatable, Sendable {
  case notRequested
  case waitingForPermission
  case waitingForAudio
  case publishing(attempt: Int)
  case published
  case failed(message: String, attempt: Int)
}

/// Evidence from PCM frames delivered by the concrete local microphone track.
/// This is intentionally separate from signaling publication and Core Audio's
/// running flag: both can be healthy while no capture frames reach WebRTC.
public enum InlineRTCAudioFlowState: Equatable, Sendable {
  case unknown
  case flowing
  case missing
}

public struct InlineRTCConnectionSnapshot: Equatable, Sendable {
  public let state: InlineRTCConnectionState
  public let target: InlineRTCSessionID?
  public let microphonePublicationState: InlineRTCMicrophoneState
  public let microphonePublished: Bool
  public let microphoneMuted: Bool
  public let localAudioFlowState: InlineRTCAudioFlowState
  public let remoteAudioFlowStates: [String: InlineRTCAudioFlowState]
  public let participants: [InlineRTCParticipant]
  public let reconnectCount: Int
  public let recoveryAttempt: Int
  public let lastConnectMilliseconds: Int?
  public let lastDisconnectMilliseconds: Int?
  public let lastError: String?
  public let abandonedProviderOperationCount: Int
  public let providerCircuitOpen: Bool

  public init(
    state: InlineRTCConnectionState,
    target: InlineRTCSessionID?,
    microphonePublicationState: InlineRTCMicrophoneState,
    microphonePublished: Bool,
    microphoneMuted: Bool,
    localAudioFlowState: InlineRTCAudioFlowState = .unknown,
    remoteAudioFlowStates: [String: InlineRTCAudioFlowState] = [:],
    participants: [InlineRTCParticipant],
    reconnectCount: Int,
    recoveryAttempt: Int,
    lastConnectMilliseconds: Int?,
    lastDisconnectMilliseconds: Int?,
    lastError: String?,
    abandonedProviderOperationCount: Int = 0,
    providerCircuitOpen: Bool = false
  ) {
    self.state = state
    self.target = target
    self.microphonePublicationState = microphonePublicationState
    self.microphonePublished = microphonePublished
    self.microphoneMuted = microphoneMuted
    self.localAudioFlowState = localAudioFlowState
    self.remoteAudioFlowStates = remoteAudioFlowStates
    self.participants = participants
    self.reconnectCount = reconnectCount
    self.recoveryAttempt = recoveryAttempt
    self.lastConnectMilliseconds = lastConnectMilliseconds
    self.lastDisconnectMilliseconds = lastDisconnectMilliseconds
    self.lastError = lastError
    self.abandonedProviderOperationCount = abandonedProviderOperationCount
    self.providerCircuitOpen = providerCircuitOpen
  }
}

/// The only commands accepted by the process-wide InlineRTC runtime.
///
/// Commands describe the latest desired state or a lifecycle signal. They do
/// not expose AudioManager, LiveKit rooms, tracks, or engine leases to product
/// and UI layers.
enum GridEngineCommand: Equatable, Sendable {
  case setDemand(InlineRTCDemand)
  case refreshDevices
  case retryInput(AudioInputSelection)
  case requestMicrophonePermission
  case retryAudio
  case networkBecameAvailable
  case applicationDidWake
  case shutdown(requestID: UUID)
}

/// A complete immutable projection of the process-wide InlineRTC runtime.
///
/// Subscribers use watch-channel semantics: they may coalesce intermediate
/// revisions, but every delivered value is internally coherent and contains
/// all module state needed to render the latest revision.
public struct InlineRTCState: Equatable, Sendable {
  public let revision: UInt64
  public let audio: InlineRTCAudioSnapshot
  public let devices: AudioInputDeviceSnapshot?
  public let rtc: InlineRTCConnectionSnapshot

  public init(
    revision: UInt64,
    audio: InlineRTCAudioSnapshot,
    devices: AudioInputDeviceSnapshot?,
    rtc: InlineRTCConnectionSnapshot
  ) {
    self.revision = revision
    self.audio = audio
    self.devices = devices
    self.rtc = rtc
  }
}
