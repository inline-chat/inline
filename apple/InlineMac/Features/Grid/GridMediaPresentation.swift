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

  fileprivate init(
    microphoneEnabled: Bool,
    inputSelection: AudioInputSelection,
    outputVolume: Float = 1
  ) {
    isMicrophoneEnabled = microphoneEnabled
    self.inputSelection = inputSelection
    self.outputVolume = min(max(outputVolume, 0), 1)
  }

  var isUsingAutomaticInput: Bool {
    inputSelection == .automatic
  }

  var hasRemoteAudioFlowFailure: Bool {
    remoteAudioFlowStates.values.contains(.missing)
  }

  func prefersInputDevice(_ device: AudioInputDeviceDescriptor) -> Bool {
    inputSelection.matches(device, among: inputDevices)
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
    outputVolume: Float = 1
  ) {
    presentation = GridMediaPresentation(
      microphoneEnabled: microphoneEnabled,
      inputSelection: inputSelection,
      outputVolume: outputVolume
    )
  }

  func setMicrophoneEnabled(_ enabled: Bool) {
    presentation.isMicrophoneEnabled = enabled
  }

  func setDesiredInputSelection(_ selection: AudioInputSelection) {
    presentation.inputSelection = selection
  }

  func setDesiredOutputVolume(_ volume: Float) {
    presentation.outputVolume = min(max(volume, 0), 1)
  }

  func apply(audio snapshot: InlineRTCAudioSnapshot) {
    presentation.audioState = snapshot.state
    presentation.isMicrophoneCapturePrepared = snapshot.isPrepared
    presentation.microphonePermission = snapshot.microphonePermission
    if let resolvedInput = snapshot.input {
      presentation.activeInputDeviceID = resolvedInput.activeDeviceID
      presentation.isFallingBackToAutomaticInput = resolvedInput.isFallingBackToAutomatic
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
    presentation.abandonedProviderOperationCount = snapshot.abandonedProviderOperationCount
    presentation.providerCircuitOpen = snapshot.providerCircuitOpen
  }

  func apply(devices snapshot: AudioInputDeviceSnapshot) {
    presentation.automaticInputDeviceName = snapshot.automaticDeviceName
    presentation.inputDevices = snapshot.devices
    presentation.activeInputDeviceID = snapshot.resolvedInput.activeDeviceID
    presentation.isFallingBackToAutomaticInput = snapshot.resolvedInput.isFallingBackToAutomatic
  }
}
