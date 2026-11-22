import Foundation
import InlineCompat
import InlineKit
import InlineRTC
import Observation

public enum GridMediaConnectionStatus: Equatable, Sendable {
  case disconnected
  case connecting
  case connected
  case failed
}

public enum GridScreenCaptureIssue: Equatable, Sendable {
  case sourceDiscovery
  case sharing
}

@MainActor
public final class GridMediaPresentation: CompatObservable {
  public let observationRegistrar = CompatObservationRegistrar()
  @Tracked public fileprivate(set) var connectionState: GridMediaConnectionStatus = .disconnected
  /// True while an established or attempted call is being recovered, as
  /// opposed to its first connect. Retries never surface as errors.
  @Tracked public fileprivate(set) var isReconnecting = false
  @Tracked public fileprivate(set) var audioState: InlineRTCAudioState = .cold
  @Tracked public fileprivate(set) var isAudioSafetyPaused = false
  @Tracked public fileprivate(set) var isMicrophoneEnabled: Bool
  @Tracked public fileprivate(set) var autoUnmuteOnJoin: Bool
  @Tracked public fileprivate(set) var autoMuteWhenAlone: Bool
  @Tracked public fileprivate(set) var inputDevices: [AudioInputDeviceDescriptor] = []
  @Tracked public fileprivate(set) var automaticInputDeviceName = "System Default"
  @Tracked public fileprivate(set) var activeInputDeviceID: String? = nil
  @Tracked public fileprivate(set) var inputSelection: AudioInputSelection
  @Tracked public fileprivate(set) var isFallingBackToAutomaticInput = false
  @Tracked public fileprivate(set) var outputDevices: [AudioOutputDeviceDescriptor] = []
  @Tracked public fileprivate(set) var automaticOutputDeviceName = "System Default"
  @Tracked public fileprivate(set) var activeOutputDeviceID: String? = nil
  @Tracked public fileprivate(set) var outputSelection: AudioOutputSelection
  @Tracked public fileprivate(set) var isFallingBackToAutomaticOutput = false
  @Tracked public fileprivate(set) var participantAudioLevels: [String: Float] = [:]
  @Tracked public fileprivate(set) var participantScreenShareIntents: [String: Bool] = [:]
  @Tracked public fileprivate(set) var connectedParticipantIdentities = Set<String>()
  @Tracked public fileprivate(set) var hasParticipantMediaSnapshot = false
  @Tracked public fileprivate(set) var reconnectCount = 0
  @Tracked public fileprivate(set) var recoveryAttempt = 0
  @Tracked public fileprivate(set) var lastConnectDurationMilliseconds: Int? = nil
  @Tracked public fileprivate(set) var lastDisconnectDurationMilliseconds: Int? = nil
  @Tracked public fileprivate(set) var lastConnectionError: String? = nil
  @Tracked public fileprivate(set) var isMicrophoneCapturePrepared = false
  @Tracked public fileprivate(set) var microphonePermission: InlineRTCMicrophonePermission = .notDetermined
  @Tracked public fileprivate(set) var microphonePublicationState: InlineRTCMicrophoneState = .notRequested
  @Tracked public fileprivate(set) var localAudioFlowState: InlineRTCAudioFlowState = .unknown
  @Tracked public fileprivate(set) var remoteAudioFlowStates: [String: InlineRTCAudioFlowState] = [:]
  @Tracked public fileprivate(set) var abandonedProviderOperationCount = 0
  @Tracked public fileprivate(set) var providerCircuitOpen = false
  @Tracked public fileprivate(set) var outputVolume: Float
  @Tracked public fileprivate(set) var screenCaptureSources: [InlineRTCScreenCaptureSource] = []
  @Tracked public fileprivate(set) var selectedScreenCaptureSource: InlineRTCScreenCaptureSource? = nil
  @Tracked public fileprivate(set) var screenShareQualityProfile: InlineRTCScreenShareQualityProfile
  @Tracked public fileprivate(set) var screenShareEpisodeID: UInt64 = 0
  @Tracked public fileprivate(set) var screenShareState: InlineRTCScreenShareState = .off
  @Tracked public fileprivate(set) var screenShares: [InlineRTCScreenShare] = []
  @Tracked public fileprivate(set) var isRefreshingScreenCaptureSources = false
  @Tracked public fileprivate(set) var screenCaptureError: String? = nil
  @Tracked public fileprivate(set) var screenCaptureIssue: GridScreenCaptureIssue? = nil

  fileprivate init(
    microphoneEnabled: Bool,
    autoUnmuteOnJoin: Bool,
    autoMuteWhenAlone: Bool,
    inputSelection: AudioInputSelection,
    screenShareQualityProfile: InlineRTCScreenShareQualityProfile = .automatic,
    outputSelection: AudioOutputSelection = .automatic,
    outputVolume: Float = 1
  ) {
    isMicrophoneEnabled = microphoneEnabled
    self.autoUnmuteOnJoin = autoUnmuteOnJoin
    self.autoMuteWhenAlone = autoMuteWhenAlone
    self.inputSelection = inputSelection
    self.screenShareQualityProfile = screenShareQualityProfile
    self.outputSelection = outputSelection
    self.outputVolume = min(max(outputVolume, 0), 1)
  }

  public var isUsingAutomaticInput: Bool {
    inputSelection == .automatic
  }

  public var hasRemoteAudioFlowFailure: Bool {
    remoteAudioFlowStates.values.contains(.missing)
  }

  public var isScreenSharing: Bool {
    screenShares.contains(where: \.isLocal)
  }

  public var isScreenShareRequested: Bool {
    selectedScreenCaptureSource != nil
  }

  public func prefersInputDevice(_ device: AudioInputDeviceDescriptor) -> Bool {
    inputSelection.matches(device, among: inputDevices)
  }

  public func prefersOutputDevice(_ device: AudioOutputDeviceDescriptor) -> Bool {
    outputSelection.matches(device, among: outputDevices)
  }

}

@available(iOS 17.0, macOS 14.0, *)
extension GridMediaPresentation: Observable {}

/// The sole writer for `GridMediaPresentation`. Views only receive the
/// presentation reference and therefore cannot feed state back into its owner.
@MainActor
final class GridMediaPresentationController {
  private var lastConnectedTarget: InlineRTCSessionID?
  let presentation: GridMediaPresentation

  init(
    microphoneEnabled: Bool,
    autoUnmuteOnJoin: Bool,
    autoMuteWhenAlone: Bool,
    inputSelection: AudioInputSelection,
    screenShareQualityProfile: InlineRTCScreenShareQualityProfile = .automatic,
    outputSelection: AudioOutputSelection = .automatic,
    outputVolume: Float = 1
  ) {
    presentation = GridMediaPresentation(
      microphoneEnabled: microphoneEnabled,
      autoUnmuteOnJoin: autoUnmuteOnJoin,
      autoMuteWhenAlone: autoMuteWhenAlone,
      inputSelection: inputSelection,
      screenShareQualityProfile: screenShareQualityProfile,
      outputSelection: outputSelection,
      outputVolume: outputVolume
    )
  }

  func setMicrophoneEnabled(_ enabled: Bool) {
    presentation.isMicrophoneEnabled = enabled
  }

  func setAutoUnmuteOnJoin(_ enabled: Bool) {
    presentation.autoUnmuteOnJoin = enabled
  }

  func setAutoMuteWhenAlone(_ enabled: Bool) {
    presentation.autoMuteWhenAlone = enabled
  }

  func setDesiredInputSelection(_ selection: AudioInputSelection) {
    presentation.inputSelection = selection
  }

  func setDesiredOutputSelection(_ selection: AudioOutputSelection) {
    presentation.outputSelection = selection
  }

  func setDesiredOutputVolume(_ volume: Float) {
    presentation.outputVolume = min(max(volume, 0), 1)
  }

  func setSelectedScreenCaptureSource(_ source: InlineRTCScreenCaptureSource?) {
    if presentation.selectedScreenCaptureSource == nil, source != nil {
      presentation.screenShareEpisodeID &+= 1
    }
    presentation.selectedScreenCaptureSource = source
  }

  func setScreenShareQualityProfile(_ profile: InlineRTCScreenShareQualityProfile) {
    presentation.screenShareQualityProfile = profile
  }

  func clearScreenCaptureError() {
    presentation.screenCaptureError = nil
    presentation.screenCaptureIssue = nil
  }

  func setRefreshingScreenCaptureSources(_ isRefreshing: Bool) {
    presentation.isRefreshingScreenCaptureSources = isRefreshing
  }

  func applyScreenCaptureSources(
    _ result: Result<[InlineRTCScreenCaptureSource], Error>
  ) {
    switch result {
    case let .success(sources):
      presentation.screenCaptureSources = sources
      presentation.screenCaptureError = nil
      presentation.screenCaptureIssue = nil
    case let .failure(error):
      presentation.screenCaptureSources = []
      presentation.screenCaptureError = error.localizedDescription
      presentation.screenCaptureIssue = .sourceDiscovery
    }
  }

  func apply(audio snapshot: InlineRTCAudioSnapshot) {
    presentation.audioState = snapshot.state
    presentation.isAudioSafetyPaused = snapshot.isSafetyPaused
    presentation.isMicrophoneCapturePrepared = snapshot.isPrepared
    presentation.microphonePermission = snapshot.microphonePermission
    if let resolvedInput = snapshot.input {
      presentation.activeInputDeviceID = resolvedInput.activeDeviceID
      presentation.isFallingBackToAutomaticInput = resolvedInput.isFallingBackToAutomatic
    }
    if let resolvedOutput = snapshot.output {
      presentation.activeOutputDeviceID = resolvedOutput.activeDeviceID
      presentation.isFallingBackToAutomaticOutput = resolvedOutput.isFallingBackToAutomatic
    }
  }

  func apply(rtc snapshot: InlineRTCConnectionSnapshot) {
    presentation.connectionState = switch snapshot.state {
    case .idle: .disconnected
    case .connected: .connected
    case .failed: .failed
    default: .connecting
    }
    // Reconnecting means this target was live and is being recovered, so a
    // whole recovery reads the same however many steps it passes through.
    switch snapshot.state {
    case let .connected(target): lastConnectedTarget = target
    case .idle: lastConnectedTarget = nil
    default: break
    }
    let recoveringConnectedTarget = lastConnectedTarget != nil && lastConnectedTarget == snapshot.target
    presentation.isReconnecting = switch snapshot.state {
    case .connected, .idle, .failed: false
    default: recoveringConnectedTarget
    }
    presentation.participantAudioLevels = Dictionary(
      uniqueKeysWithValues: snapshot.participants.map {
        ($0.identity, $0.isSpeaking ? $0.audioLevel : 0)
      }
    )
    presentation.participantScreenShareIntents = Dictionary(
      uniqueKeysWithValues: snapshot.participants.compactMap { participant in
        participant.screenShareIntent.map { (participant.identity, $0) }
      }
    )
    presentation.connectedParticipantIdentities = Set(snapshot.participants.map(\.identity))
    presentation.hasParticipantMediaSnapshot = snapshot.hasParticipantMediaSnapshot
    presentation.reconnectCount = snapshot.reconnectCount
    presentation.recoveryAttempt = snapshot.recoveryAttempt
    presentation.lastConnectDurationMilliseconds = snapshot.lastConnectMilliseconds
    presentation.lastDisconnectDurationMilliseconds = snapshot.lastDisconnectMilliseconds
    presentation.lastConnectionError = snapshot.lastError
    presentation.microphonePublicationState = snapshot.microphonePublicationState
    presentation.localAudioFlowState = snapshot.localAudioFlowState
    presentation.remoteAudioFlowStates = snapshot.remoteAudioFlowStates
    presentation.screenShareState = snapshot.screenShareState
    presentation.screenShares = snapshot.screenShares
    if case let .failed(message) = snapshot.screenShareState,
       message != "Screen sharing stopped" {
      presentation.screenCaptureError = message
      presentation.screenCaptureIssue = .sharing
    } else if case let .failed(message) = snapshot.screenShareState,
              message == "Screen sharing stopped" {
      presentation.screenCaptureError = nil
      presentation.screenCaptureIssue = nil
    } else if snapshot.screenShareState == .off,
              presentation.connectionState == .connected,
              presentation.screenCaptureError == "Screen sharing did not stop" {
      // A failed Stop is recoverable through room reconstruction. Keep the
      // warning visible until the fresh connected projection proves that no
      // local publication remains, then retire the transient recovery notice.
      presentation.screenCaptureError = nil
      presentation.screenCaptureIssue = nil
    }
    presentation.abandonedProviderOperationCount = snapshot.abandonedProviderOperationCount
    presentation.providerCircuitOpen = snapshot.providerCircuitOpen
  }

  func apply(devices snapshot: AudioInputDeviceSnapshot) {
    presentation.automaticInputDeviceName = snapshot.automaticDeviceName
    presentation.inputDevices = snapshot.devices
    presentation.activeInputDeviceID = snapshot.resolvedInput.activeDeviceID
    presentation.isFallingBackToAutomaticInput = snapshot.resolvedInput.isFallingBackToAutomatic
  }

  func apply(outputDevices snapshot: AudioOutputDeviceSnapshot) {
    presentation.automaticOutputDeviceName = snapshot.automaticDeviceName
    presentation.outputDevices = snapshot.devices
    presentation.activeOutputDeviceID = snapshot.resolvedOutput.activeDeviceID
    presentation.isFallingBackToAutomaticOutput =
      snapshot.resolvedOutput.isFallingBackToAutomatic
  }
}
