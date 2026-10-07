import Foundation
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
@Observable
public final class GridMediaPresentation {
  public fileprivate(set) var connectionState: GridMediaConnectionStatus = .disconnected
  public fileprivate(set) var audioState: InlineRTCAudioState = .cold
  public fileprivate(set) var isAudioSafetyPaused = false
  public fileprivate(set) var isMicrophoneEnabled: Bool
  public fileprivate(set) var autoUnmuteOnJoin: Bool
  public fileprivate(set) var autoMuteWhenAlone: Bool
  public fileprivate(set) var inputDevices: [AudioInputDeviceDescriptor] = []
  public fileprivate(set) var automaticInputDeviceName = "System Default"
  public fileprivate(set) var activeInputDeviceID: String?
  public fileprivate(set) var inputSelection: AudioInputSelection
  public fileprivate(set) var isFallingBackToAutomaticInput = false
  public fileprivate(set) var outputDevices: [AudioOutputDeviceDescriptor] = []
  public fileprivate(set) var automaticOutputDeviceName = "System Default"
  public fileprivate(set) var activeOutputDeviceID: String?
  public fileprivate(set) var outputSelection: AudioOutputSelection
  public fileprivate(set) var isFallingBackToAutomaticOutput = false
  public fileprivate(set) var participantAudioLevels: [String: Float] = [:]
  public fileprivate(set) var participantScreenShareIntents: [String: Bool] = [:]
  public fileprivate(set) var connectedParticipantIdentities = Set<String>()
  public fileprivate(set) var hasParticipantMediaSnapshot = false
  public fileprivate(set) var reconnectCount = 0
  public fileprivate(set) var recoveryAttempt = 0
  public fileprivate(set) var lastConnectDurationMilliseconds: Int?
  public fileprivate(set) var lastDisconnectDurationMilliseconds: Int?
  public fileprivate(set) var lastConnectionError: String?
  public fileprivate(set) var isMicrophoneCapturePrepared = false
  public fileprivate(set) var microphonePermission: InlineRTCMicrophonePermission = .notDetermined
  public fileprivate(set) var microphonePublicationState: InlineRTCMicrophoneState = .notRequested
  public fileprivate(set) var localAudioFlowState: InlineRTCAudioFlowState = .unknown
  public fileprivate(set) var remoteAudioFlowStates: [String: InlineRTCAudioFlowState] = [:]
  public fileprivate(set) var abandonedProviderOperationCount = 0
  public fileprivate(set) var providerCircuitOpen = false
  public fileprivate(set) var outputVolume: Float
  public fileprivate(set) var screenCaptureSources: [InlineRTCScreenCaptureSource] = []
  public fileprivate(set) var selectedScreenCaptureSource: InlineRTCScreenCaptureSource?
  public fileprivate(set) var screenShareQualityProfile: InlineRTCScreenShareQualityProfile
  public fileprivate(set) var screenShareEpisodeID: UInt64 = 0
  public fileprivate(set) var screenShareState: InlineRTCScreenShareState = .off
  public fileprivate(set) var screenShares: [InlineRTCScreenShare] = []
  public fileprivate(set) var isRefreshingScreenCaptureSources = false
  public fileprivate(set) var screenCaptureError: String?
  public fileprivate(set) var screenCaptureIssue: GridScreenCaptureIssue?

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

/// The sole writer for `GridMediaPresentation`. Views only receive the
/// presentation reference and therefore cannot feed state back into its owner.
@MainActor
final class GridMediaPresentationController {
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
