import Foundation
import Testing

@testable import InlineRTC

@Suite("Grid media foundations", .serialized)
@MainActor
struct GridMediaFoundationTests {
  @Test("input preference is independent from a Grid or RTC lifecycle")
  func inputPreferencePersistence() {
    let userDefaults = UserDefaults(suiteName: "GridMediaFoundationTests.\(UUID().uuidString)")!
    let first = AudioInputPreferenceStore(
      defaults: userDefaults,
      deviceIDKey: "test.input.id",
      deviceNameKey: "test.input.name"
    )

    #expect(first.selection == .automatic)
    first.setSelection(.device(id: "external-mic", rememberedName: "Studio Microphone"))

    let restored = AudioInputPreferenceStore(
      defaults: userDefaults,
      deviceIDKey: "test.input.id",
      deviceNameKey: "test.input.name"
    )
    #expect(
      restored.selection
        == .device(id: "external-mic", rememberedName: "Studio Microphone")
    )

    restored.setSelection(.automatic)
    #expect(first.selection == .automatic)
  }

  @Test("voice configuration exposes reviewable LiveKit audio defaults")
  func voiceConfigurationDefaults() {
    let configuration = InlineRTCConfiguration.voice

    #expect(configuration.connection.prepareCloudConnection == false)
    #expect(configuration.connection.publishEnabledMicrophoneDuringConnect == false)
    #expect(configuration.connection.reconnectAttempts >= 120)
    #expect(configuration.connection.singlePeerConnection)
    #expect(configuration.connection.initialConnectSlowWarningDelay > 0)
    #expect(
      configuration.connection.initialConnectWatchdogTimeout
        > configuration.connection.initialConnectSlowWarningDelay
    )
    #expect(configuration.connection.retirementBarrierTimeout > 0)
    #expect(configuration.connection.maxAbandonedProviderOperations == 2)
    #expect(configuration.capture.echoCancellation)
    #expect(configuration.capture.echoCancellationMode == .software)
    #expect(configuration.capture.noiseSuppression)
    #expect(configuration.capture.noiseSuppressionMode == .software)
    let captureOptions = configuration.makeRoomOptions().defaultAudioCaptureOptions
    #expect(captureOptions.echoCancellation)
    #expect(captureOptions.echoCancellationMode == .software)
    #expect(captureOptions.noiseSuppression)
    #expect(captureOptions.noiseSuppressionMode == .software)
    #expect(!captureOptions.typingNoiseDetection)
    #expect(configuration.publishing.quality == .speech)
    #expect(configuration.publishing.discontinuousTransmission)
    #expect(configuration.publishing.redundantEncoding)
    #expect(configuration.voiceProcessing.platformVoiceProcessingAllowed == false)
    #expect(configuration.voiceProcessing.bypassed == false)
    #expect(configuration.voiceProcessing.microphoneMuteMode == .inputMixer)
  }

  @Test("device snapshot retains an explicit unavailable preference")
  func unavailableDevicePreference() {
    let selection = AudioInputSelection.device(
      id: "disconnected-device",
      rememberedName: "Desk Microphone"
    )
    let snapshot = AudioInputDeviceSnapshot(
      automaticDeviceName: "MacBook Pro Microphone",
      devices: [],
      resolvedInput: ResolvedAudioInput(
        selection: selection,
        activeDeviceID: "built-in",
        activeDeviceName: "MacBook Pro Microphone",
        isFallingBackToAutomatic: true
      )
    )

    #expect(snapshot.resolvedInput.selection == selection)
    #expect(snapshot.resolvedInput.isFallingBackToAutomatic)
    #expect(snapshot.automaticDeviceName == "MacBook Pro Microphone")
  }

  @Test("explicit preference repairs an ID only through an unambiguous inventory")
  func explicitPreferenceMatchesReplacementID() {
    let selection = AudioInputSelection.device(id: "old-id", rememberedName: "Studio Microphone")
    let reconnected = AudioInputDeviceDescriptor(
      id: "new-id",
      name: "Studio Microphone",
      isSystemDefault: false,
      systemImage: "mic.fill"
    )

    #expect(!selection.matches(reconnected))
    #expect(selection.matches(reconnected, among: [reconnected]))
    #expect(selection.resolvedDeviceID(in: [reconnected]) == "new-id")
  }

  @Test("same-name microphones never restore an explicit preference ambiguously")
  func duplicateDeviceNamesAreAmbiguous() {
    let selection = AudioInputSelection.device(id: "old-id", rememberedName: "AirPods")
    let devices = [
      AudioInputDeviceDescriptor(
        id: "first",
        name: "AirPods",
        isSystemDefault: false,
        systemImage: "airpods"
      ),
      AudioInputDeviceDescriptor(
        id: "second",
        name: "AirPods",
        isSystemDefault: false,
        systemImage: "airpods"
      ),
    ]

    #expect(selection.resolvedDeviceID(in: devices) == nil)
  }

  @Test("remembered-name repair ignores harmless case and whitespace changes")
  func rememberedNameRepairIsNormalized() {
    let selection = AudioInputSelection.device(
      id: "old-id",
      rememberedName: "  Studio Microphone "
    )
    let device = AudioInputDeviceDescriptor(
      id: "new-id",
      name: "studio microphone",
      isSystemDefault: false,
      systemImage: "mic.fill"
    )

    #expect(selection.resolvedDeviceID(in: [device]) == "new-id")
  }
}
