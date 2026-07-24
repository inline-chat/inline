import CoreAudio
import LiveKit

#if os(macOS)
enum MacGridLiveKitAudioProcessingPolicy {
  static func snapshot(
    manager: AudioManager = .shared
  ) -> InlineRTCAudioProcessingState {
    let processingState = manager.audioProcessingState
    let platformState = manager.platformVoiceProcessingState
    return InlineRTCAudioProcessingState(
      echoCancellationRequested: processingState.echoCancellation.requested?.isEnabled,
      echoCancellationEffective: implementation(
        processingState.echoCancellation.effective
      ),
      noiseSuppressionRequested: processingState.noiseSuppression.requested?.isEnabled,
      noiseSuppressionEffective: implementation(
        processingState.noiseSuppression.effective
      ),
      automaticGainControlRequested: processingState.autoGainControl.requested?.isEnabled,
      automaticGainControlEffective: implementation(
        processingState.autoGainControl.effective
      ),
      platformVoiceProcessingAllowed: manager.isPlatformVoiceProcessingAllowed,
      platformVoiceProcessingRequested:
        platformState.voiceProcessingEnabled.isRequested
        || platformState.echoCancellation.isRequested
        || platformState.noiseSuppression.isRequested,
      platformVoiceProcessingActive:
        platformState.voiceProcessingEnabled.isActive
        || platformState.echoCancellation.isActive
        || platformState.noiseSuppression.isActive
    )
  }

  private static func implementation(
    _ implementation: AudioProcessingImplementation
  ) -> InlineRTCAudioProcessingImplementation {
    switch implementation {
    case .unknown: .unknown
    case .disabled: .disabled
    case .software: .software
    case .platform: .platform
    case .softwareAndPlatform: .softwareAndPlatform
    @unknown default: .unknown
    }
  }
}

enum MacGridADMDeviceDirection: String, Sendable {
  case input
  case output
}

/// Stateful verifier for the physical devices Core Audio reports as carrying
/// this process's IO. A WebRTC setter returning is not a commit signal.
struct MacGridADMDeviceReadbackMonitor {
  let expectedUID: String
  let direction: MacGridADMDeviceDirection
  private(set) var observedUIDs: [String] = []

  var observedUID: String? {
    if observedUIDs.contains(expectedUID) { return expectedUID }
    return observedUIDs.count == 1 ? observedUIDs[0] : nil
  }

  mutating func observe(
    processDeviceIDs: [AudioDeviceID],
    isRunning: Bool,
    snapshot: MacGridAudioCatalogSnapshot
  ) -> Bool {
    observedUIDs = Self.stableUIDs(
      forCoreAudioDeviceIDs: processDeviceIDs,
      direction: direction,
      snapshot: snapshot
    )
    return isRunning && observedUIDs.contains(expectedUID)
  }

  static func stableUIDs(
    forCoreAudioDeviceIDs deviceIDs: [AudioDeviceID],
    direction: MacGridADMDeviceDirection,
    snapshot: MacGridAudioCatalogSnapshot
  ) -> [String] {
    let devices = direction == .input ? snapshot.inputs : snapshot.outputs
    let ids = Set(deviceIDs)
    return devices.filter { ids.contains($0.id) }.map(\.uid).sorted()
  }
}

enum MacGridAudioCallbackHealth {
  static let maximumFreshAgeMilliseconds: UInt64 = 500

  static func isFresh(seen: Bool, ageMilliseconds: UInt64?) -> Bool {
    seen && ageMilliseconds.map { $0 <= maximumFreshAgeMilliseconds } == true
  }
}

enum MacGridAudioGraphFormatHealth {
  private static let sampleRateTolerance = 1.0

  static func expectedRecordingSampleRate(
    inputSampleRate: Double?,
    outputSampleRate: Double?,
    isPlaying: Bool
  ) -> Double? {
    isPlaying ? outputSampleRate : inputSampleRate
  }

  static func matches(
    configuredSampleRate: Double,
    configuredChannels: UInt32,
    expectedSampleRate: Double?,
    isActive: Bool
  ) -> Bool {
    guard isActive else { return true }
    guard configuredSampleRate.isFinite,
          configuredSampleRate > 0,
          configuredChannels > 0,
          let expectedSampleRate,
          expectedSampleRate.isFinite,
          expectedSampleRate > 0
    else { return false }
    return abs(configuredSampleRate - expectedSampleRate) <= sampleRateTolerance
  }
}
#endif
