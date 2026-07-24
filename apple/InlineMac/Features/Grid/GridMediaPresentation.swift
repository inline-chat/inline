import Foundation
import InlineKit
import InlineRTC
import Observation

enum GridMediaConnectionStatus: Equatable, Sendable {
  case disconnected
  case connecting
  case connected
  case failed
}

enum GridScreenCaptureIssue: Equatable, Sendable {
  case sourceDiscovery
  case sharing
}

@MainActor
@Observable
final class GridMediaPresentation {
  fileprivate(set) var connectionState: GridMediaConnectionStatus = .disconnected
  fileprivate(set) var audioState: InlineRTCAudioState = .cold
  fileprivate(set) var isMicrophoneEnabled: Bool
  fileprivate(set) var inputDevices: [AudioInputDeviceDescriptor] = []
  fileprivate(set) var automaticInputDeviceName = "System Default"
  fileprivate(set) var activeInputDeviceID: String?
  fileprivate(set) var inputSelection: AudioInputSelection
  fileprivate(set) var isFallingBackToAutomaticInput = false
  fileprivate(set) var outputDevices: [AudioOutputDeviceDescriptor] = []
  fileprivate(set) var automaticOutputDeviceName = "System Default"
  fileprivate(set) var activeOutputDeviceID: String?
  fileprivate(set) var outputSelection: AudioOutputSelection
  fileprivate(set) var isFallingBackToAutomaticOutput = false
  fileprivate(set) var participantAudioLevels: [String: Float] = [:]
  fileprivate(set) var connectedParticipantIdentities = Set<String>()
  fileprivate(set) var reconnectCount = 0
  fileprivate(set) var recoveryAttempt = 0
  fileprivate(set) var lastConnectDurationMilliseconds: Int?
  fileprivate(set) var lastDisconnectDurationMilliseconds: Int?
  fileprivate(set) var lastConnectionError: String?
  fileprivate(set) var isMicrophoneCapturePrepared = false
  fileprivate(set) var microphonePermission: InlineRTCMicrophonePermission = .notDetermined
  fileprivate(set) var microphonePublicationState: InlineRTCMicrophoneState = .notRequested
  fileprivate(set) var localAudioFlowState: InlineRTCAudioFlowState = .unknown
  fileprivate(set) var remoteAudioFlowStates: [String: InlineRTCAudioFlowState] = [:]
  fileprivate(set) var abandonedProviderOperationCount = 0
  fileprivate(set) var providerCircuitOpen = false
  fileprivate(set) var outputVolume: Float
  fileprivate(set) var screenCaptureSources: [InlineRTCScreenCaptureSource] = []
  fileprivate(set) var selectedScreenCaptureSource: InlineRTCScreenCaptureSource?
  fileprivate(set) var screenShareEpisodeID: UInt64 = 0
  fileprivate(set) var screenShareState: InlineRTCScreenShareState = .off
  fileprivate(set) var screenShares: [InlineRTCScreenShare] = []
  fileprivate(set) var isRefreshingScreenCaptureSources = false
  fileprivate(set) var screenCaptureError: String?
  fileprivate(set) var screenCaptureIssue: GridScreenCaptureIssue?

  fileprivate init(
    microphoneEnabled: Bool,
    inputSelection: AudioInputSelection,
    outputSelection: AudioOutputSelection = .automatic,
    outputVolume: Float = 1
  ) {
    isMicrophoneEnabled = microphoneEnabled
    self.inputSelection = inputSelection
    self.outputSelection = outputSelection
    self.outputVolume = min(max(outputVolume, 0), 1)
  }

  var isUsingAutomaticInput: Bool {
    inputSelection == .automatic
  }

  var hasRemoteAudioFlowFailure: Bool {
    remoteAudioFlowStates.values.contains(.missing)
  }

  var isScreenSharing: Bool {
    screenShares.contains(where: \.isLocal)
  }

  var isScreenShareRequested: Bool {
    selectedScreenCaptureSource != nil
  }

  func prefersInputDevice(_ device: AudioInputDeviceDescriptor) -> Bool {
    inputSelection.matches(device, among: inputDevices)
  }

  func prefersOutputDevice(_ device: AudioOutputDeviceDescriptor) -> Bool {
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
    inputSelection: AudioInputSelection,
    outputSelection: AudioOutputSelection = .automatic,
    outputVolume: Float = 1
  ) {
    presentation = GridMediaPresentation(
      microphoneEnabled: microphoneEnabled,
      inputSelection: inputSelection,
      outputSelection: outputSelection,
      outputVolume: outputVolume
    )
  }

  func setMicrophoneEnabled(_ enabled: Bool) {
    presentation.isMicrophoneEnabled = enabled
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
    presentation.connectedParticipantIdentities = Set(snapshot.participants.map(\.identity))
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
    if case let .failed(message) = snapshot.screenShareState {
      presentation.screenCaptureError = message
      presentation.screenCaptureIssue = .sharing
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
