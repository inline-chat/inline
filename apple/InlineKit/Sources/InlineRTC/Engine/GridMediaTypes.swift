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
  public var screenCaptureSource: InlineRTCScreenCaptureSource?
  public var input: AudioInputSelection
  public var output: AudioOutputSelection
  public var outputVolume: Float

  public init(
    target: InlineRTCSessionID? = nil,
    credentials: InlineRTCCredentials? = nil,
    microphoneEnabled: Bool = false,
    screenCaptureSource: InlineRTCScreenCaptureSource? = nil,
    input: AudioInputSelection = .automatic,
    output: AudioOutputSelection = .automatic,
    outputVolume: Float = 1
  ) {
    self.target = target
    self.credentials = credentials
    self.microphoneEnabled = microphoneEnabled
    self.screenCaptureSource = screenCaptureSource
    self.input = input
    self.output = output
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
  public let inputCallbackCount: UInt64?
  public let outputCallbackCount: UInt64?
  public let inputCallbackAgeMilliseconds: UInt64?
  public let outputCallbackAgeMilliseconds: UInt64?
  public let measuredInputDelayMilliseconds: UInt16?
  public let measuredOutputDelayMilliseconds: UInt16?

  public init(
    currentInputID: String?,
    defaultInputID: String?,
    currentOutputID: String?,
    defaultOutputID: String?,
    inputDeviceCount: Int,
    outputDeviceCount: Int,
    isInputRouteValid: Bool,
    isOutputRouteValid: Bool,
    routeEpoch: UInt64 = 0,
    inputCallbackCount: UInt64? = nil,
    outputCallbackCount: UInt64? = nil,
    inputCallbackAgeMilliseconds: UInt64? = nil,
    outputCallbackAgeMilliseconds: UInt64? = nil,
    measuredInputDelayMilliseconds: UInt16? = nil,
    measuredOutputDelayMilliseconds: UInt16? = nil
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
    self.inputCallbackCount = inputCallbackCount
    self.outputCallbackCount = outputCallbackCount
    self.inputCallbackAgeMilliseconds = inputCallbackAgeMilliseconds
    self.outputCallbackAgeMilliseconds = outputCallbackAgeMilliseconds
    self.measuredInputDelayMilliseconds = measuredInputDelayMilliseconds
    self.measuredOutputDelayMilliseconds = measuredOutputDelayMilliseconds
  }
}

public enum InlineRTCAudioProcessingImplementation: String, Equatable, Sendable {
  case unknown
  case disabled
  case software
  case platform
  case softwareAndPlatform
}

public struct InlineRTCAudioProcessingState: Equatable, Sendable {
  public let echoCancellationRequested: Bool?
  public let echoCancellationEffective: InlineRTCAudioProcessingImplementation
  public let noiseSuppressionRequested: Bool?
  public let noiseSuppressionEffective: InlineRTCAudioProcessingImplementation
  public let automaticGainControlRequested: Bool?
  public let automaticGainControlEffective: InlineRTCAudioProcessingImplementation
  public let platformVoiceProcessingAllowed: Bool
  public let platformVoiceProcessingRequested: Bool
  public let platformVoiceProcessingActive: Bool

  public init(
    echoCancellationRequested: Bool?,
    echoCancellationEffective: InlineRTCAudioProcessingImplementation,
    noiseSuppressionRequested: Bool?,
    noiseSuppressionEffective: InlineRTCAudioProcessingImplementation,
    automaticGainControlRequested: Bool?,
    automaticGainControlEffective: InlineRTCAudioProcessingImplementation,
    platformVoiceProcessingAllowed: Bool,
    platformVoiceProcessingRequested: Bool,
    platformVoiceProcessingActive: Bool
  ) {
    self.echoCancellationRequested = echoCancellationRequested
    self.echoCancellationEffective = echoCancellationEffective
    self.noiseSuppressionRequested = noiseSuppressionRequested
    self.noiseSuppressionEffective = noiseSuppressionEffective
    self.automaticGainControlRequested = automaticGainControlRequested
    self.automaticGainControlEffective = automaticGainControlEffective
    self.platformVoiceProcessingAllowed = platformVoiceProcessingAllowed
    self.platformVoiceProcessingRequested = platformVoiceProcessingRequested
    self.platformVoiceProcessingActive = platformVoiceProcessingActive
  }

  public var isGridPolicyEffective: Bool {
    echoCancellationRequested == true
      && echoCancellationEffective == .software
      && noiseSuppressionRequested == true
      && noiseSuppressionEffective == .software
      && !platformVoiceProcessingAllowed
      && !platformVoiceProcessingRequested
      && !platformVoiceProcessingActive
  }

  /// The APM request is track-scoped. Before the first microphone track is
  /// attached to a sender, WebRTC truthfully reports no request even though the
  /// AudioEngine ADM is already recording. Treat that bootstrap state as
  /// pending rather than failed so audio preparation can reach publication;
  /// once either Grid component has a request, the complete software-only
  /// policy must be effective.
  var isCompatibleWithCaptureBootstrap: Bool {
    let hasObservedGridRequest = echoCancellationRequested != nil
      || noiseSuppressionRequested != nil
    return !hasObservedGridRequest || isGridPolicyEffective
  }

  var logDescription: String {
    let aecRequested = echoCancellationRequested.map(String.init) ?? "none"
    let nsRequested = noiseSuppressionRequested.map(String.init) ?? "none"
    let agcRequested = automaticGainControlRequested.map(String.init) ?? "none"
    return [
      "aec_requested=\(aecRequested)",
      "aec_effective=\(echoCancellationEffective.rawValue)",
      "ns_requested=\(nsRequested)",
      "ns_effective=\(noiseSuppressionEffective.rawValue)",
      "agc_requested=\(agcRequested)",
      "agc_effective=\(automaticGainControlEffective.rawValue)",
      "vpio_allowed=\(platformVoiceProcessingAllowed)",
      "vpio_requested=\(platformVoiceProcessingRequested)",
      "vpio_active=\(platformVoiceProcessingActive)",
    ].joined(separator: " ")
  }
}

struct GridAudioRuntimeHealth: Equatable, Sendable {
  let isEngineRunning: Bool
  let isRecording: Bool
  /// `nil` for aggregate/legacy drivers. The custom ADM reports WebRTC's
  /// native microphone-sender demand so an intentionally muted sender can be
  /// distinguished from a lost recording direction.
  let isRecordingExpected: Bool?
  let isPlaying: Bool
  let route: InlineRTCAudioRoute?
  let processing: InlineRTCAudioProcessingState?

  init(
    isEngineRunning: Bool,
    isRecording: Bool? = nil,
    isRecordingExpected: Bool? = nil,
    isPlaying: Bool? = nil,
    route: InlineRTCAudioRoute?,
    processing: InlineRTCAudioProcessingState? = nil
  ) {
    self.isEngineRunning = isEngineRunning
    // Test and alternate drivers that only expose the legacy aggregate fact
    // retain their previous semantics. LiveKit supplies the concrete ADM facts.
    self.isRecording = isRecording ?? isEngineRunning
    self.isRecordingExpected = isRecordingExpected
    self.isPlaying = isPlaying ?? isEngineRunning
    self.route = route
    self.processing = processing
  }

  /// Capture-device health is the full-ADM recovery boundary owned by
  /// `GridAudioEngine`. Output failure is repaired directionally and APM policy
  /// is track/sender scoped; neither should restart a healthy microphone.
  var isAudioDeviceHealthy: Bool {
    isEngineRunning
      && isRecording
      && route?.isInputRouteValid != false
  }

  var isCaptureHealthy: Bool {
    isEngineRunning
      && isRecording
      && route?.isInputRouteValid != false
      && processing?.isCompatibleWithCaptureBootstrap != false
  }

  var isPlayoutHealthy: Bool {
    isEngineRunning
      && isPlaying
      && route?.isOutputRouteValid != false
  }
}

struct GridAudioDriverShutdownReceipt: Equatable, Sendable {
  let recordingStopped: Bool
  let playoutStopped: Bool
  let failures: [String]

  var isQuiescent: Bool {
    recordingStopped && playoutStopped && failures.isEmpty
  }
}

struct GridAudioShutdownReceipt: Equatable, Sendable {
  let recordingStopped: Bool
  let playoutStopped: Bool
  let mutationReleased: Bool
  let failures: [String]

  var isQuiescent: Bool {
    recordingStopped && playoutStopped && mutationReleased && failures.isEmpty
  }
}

struct GridLocalRoomQuiescenceReceipt: Equatable, Sendable {
  let room: GridRTCRoomHandle
  let localResourcesReleased: Bool
  let localMediaMutationCount: Int
  let microphonePublicationCount: Int
  let screenSharePublicationCount: Int
  let failures: [String]

  init(
    room: GridRTCRoomHandle,
    localResourcesReleased: Bool,
    localMediaMutationCount: Int = 0,
    microphonePublicationCount: Int = 0,
    screenSharePublicationCount: Int = 0,
    failures: [String]
  ) {
    self.room = room
    self.localResourcesReleased = localResourcesReleased
    self.localMediaMutationCount = localMediaMutationCount
    self.microphonePublicationCount = microphonePublicationCount
    self.screenSharePublicationCount = screenSharePublicationCount
    self.failures = failures
  }

  var isQuiescent: Bool {
    localResourcesReleased
      && localMediaMutationCount == 0
      && microphonePublicationCount == 0
      && screenSharePublicationCount == 0
      && failures.isEmpty
  }
}

struct GridRTCShutdownReceipt: Equatable, Sendable {
  let locallyActiveRoomCount: Int
  let localMediaMutationCount: Int
  let microphonePublicationCount: Int
  let screenSharePublicationCount: Int
  let failures: [String]

  init(
    locallyActiveRoomCount: Int,
    localMediaMutationCount: Int = 0,
    microphonePublicationCount: Int = 0,
    screenSharePublicationCount: Int = 0,
    failures: [String]
  ) {
    self.locallyActiveRoomCount = locallyActiveRoomCount
    self.localMediaMutationCount = localMediaMutationCount
    self.microphonePublicationCount = microphonePublicationCount
    self.screenSharePublicationCount = screenSharePublicationCount
    self.failures = failures
  }

  var isQuiescent: Bool {
    locallyActiveRoomCount == 0
      && localMediaMutationCount == 0
      && microphonePublicationCount == 0
      && screenSharePublicationCount == 0
      && failures.isEmpty
  }
}

public struct GridMediaShutdownReceipt: Equatable, Sendable {
  public let recordingStopped: Bool
  public let playoutStopped: Bool
  public let audioMutationReleased: Bool
  public let locallyActiveRoomCount: Int
  public let rtcLocalMediaMutationCount: Int
  public let microphonePublicationCount: Int
  public let screenSharePublicationCount: Int
  public let failures: [String]

  public var isLocallyQuiescent: Bool {
    recordingStopped
      && playoutStopped
      && audioMutationReleased
      && locallyActiveRoomCount == 0
      && rtcLocalMediaMutationCount == 0
      && microphonePublicationCount == 0
      && screenSharePublicationCount == 0
      && failures.isEmpty
  }

  init(audio: GridAudioShutdownReceipt, rtc: GridRTCShutdownReceipt) {
    recordingStopped = audio.recordingStopped
    playoutStopped = audio.playoutStopped
    audioMutationReleased = audio.mutationReleased
    locallyActiveRoomCount = rtc.locallyActiveRoomCount
    rtcLocalMediaMutationCount = rtc.localMediaMutationCount
    microphonePublicationCount = rtc.microphonePublicationCount
    screenSharePublicationCount = rtc.screenSharePublicationCount
    failures = rtc.failures + audio.failures
  }
}

enum GridAudioPlayoutFailureDisposition: Equatable, Sendable {
  case recoveredPhysicalPlayout
  case reconstructRTCSession
}

enum GridAudioCaptureFailureDisposition: Equatable, Sendable {
  case recoveredPhysicalCapture
  case reconstructRTCSession
}

public struct InlineRTCAudioSnapshot: Equatable, Sendable {
  public let state: InlineRTCAudioState
  public let isConfigured: Bool
  public let isPrepared: Bool
  public let captureLeaseCount: Int
  public let input: ResolvedAudioInput?
  public let output: ResolvedAudioOutput?
  public let route: InlineRTCAudioRoute?
  public let processing: InlineRTCAudioProcessingState?
  public let isRecording: Bool
  public let isPlaying: Bool
  public let isCaptureHealthy: Bool
  public let isPlayoutHealthy: Bool
  public let currentMutationKind: String?
  public let currentMutationMilliseconds: Int?
  public let outputVolume: Float
  public let lastTransitionMilliseconds: Int?
  public let microphonePermission: InlineRTCMicrophonePermission

  public init(
    state: InlineRTCAudioState,
    isConfigured: Bool = false,
    isPrepared: Bool,
    captureLeaseCount: Int,
    input: ResolvedAudioInput?,
    output: ResolvedAudioOutput? = nil,
    route: InlineRTCAudioRoute? = nil,
    processing: InlineRTCAudioProcessingState? = nil,
    isRecording: Bool = false,
    isPlaying: Bool = false,
    isCaptureHealthy: Bool = false,
    isPlayoutHealthy: Bool = false,
    currentMutationKind: String? = nil,
    currentMutationMilliseconds: Int? = nil,
    outputVolume: Float,
    lastTransitionMilliseconds: Int?,
    microphonePermission: InlineRTCMicrophonePermission
  ) {
    self.state = state
    self.isConfigured = isConfigured
    self.isPrepared = isPrepared
    self.captureLeaseCount = captureLeaseCount
    self.input = input
    self.output = output
    self.route = route
    self.processing = processing
    self.isRecording = isRecording
    self.isPlaying = isPlaying
    self.isCaptureHealthy = isCaptureHealthy
    self.isPlayoutHealthy = isPlayoutHealthy
    self.currentMutationKind = currentMutationKind
    self.currentMutationMilliseconds = currentMutationMilliseconds
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
  case screenSharesChanged(revision: UInt64, shares: [InlineRTCScreenShare])
  case localAudioFlow(InlineRTCAudioFlowState)
  case remoteAudioFlow(identity: String, state: InlineRTCAudioFlowState)
  case remoteAudioFramesObserved(identity: String)
  case retiredLocalMediaMutationReleased
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
  public let screenShareState: InlineRTCScreenShareState
  public let screenShares: [InlineRTCScreenShare]
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
  public let activeRoomCount: Int
  public let retiringRoomCount: Int
  public let failedLocalQuiescenceCount: Int
  public let pendingRemoteLeaveCount: Int

  public init(
    state: InlineRTCConnectionState,
    target: InlineRTCSessionID?,
    microphonePublicationState: InlineRTCMicrophoneState,
    microphonePublished: Bool,
    microphoneMuted: Bool,
    screenShareState: InlineRTCScreenShareState,
    screenShares: [InlineRTCScreenShare],
    localAudioFlowState: InlineRTCAudioFlowState = .unknown,
    remoteAudioFlowStates: [String: InlineRTCAudioFlowState] = [:],
    participants: [InlineRTCParticipant],
    reconnectCount: Int,
    recoveryAttempt: Int,
    lastConnectMilliseconds: Int?,
    lastDisconnectMilliseconds: Int?,
    lastError: String?,
    abandonedProviderOperationCount: Int = 0,
    providerCircuitOpen: Bool = false,
    activeRoomCount: Int = 0,
    retiringRoomCount: Int = 0,
    failedLocalQuiescenceCount: Int = 0,
    pendingRemoteLeaveCount: Int = 0
  ) {
    self.state = state
    self.target = target
    self.microphonePublicationState = microphonePublicationState
    self.microphonePublished = microphonePublished
    self.microphoneMuted = microphoneMuted
    self.screenShareState = screenShareState
    self.screenShares = screenShares
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
    self.activeRoomCount = activeRoomCount
    self.retiringRoomCount = retiringRoomCount
    self.failedLocalQuiescenceCount = failedLocalQuiescenceCount
    self.pendingRemoteLeaveCount = pendingRemoteLeaveCount
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
  case retryOutput(AudioOutputSelection)
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
  public let outputDevices: AudioOutputDeviceSnapshot?
  public let rtc: InlineRTCConnectionSnapshot

  public init(
    revision: UInt64,
    audio: InlineRTCAudioSnapshot,
    devices: AudioInputDeviceSnapshot?,
    outputDevices: AudioOutputDeviceSnapshot? = nil,
    rtc: InlineRTCConnectionSnapshot
  ) {
    self.revision = revision
    self.audio = audio
    self.devices = devices
    self.outputDevices = outputDevices
    self.rtc = rtc
  }
}
