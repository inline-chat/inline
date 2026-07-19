#if os(macOS)
import CoreAudio
import Testing

@testable import InlineRTC

@Suite("WebRTC input-device boundary")
struct MacGridWebRTCInputDeviceControllerTests {
  @Test("initial Auto selects WebRTC's enumerated default device")
  func initialAutomaticSelection() throws {
    let access = RecordingInputDeviceAccess()
    let controller = MacGridWebRTCInputDeviceController(access: access)

    let selected = try controller.select(.automatic, in: snapshot)

    #expect(selected.id == "default")
    #expect(access.selectedDeviceIDs == ["default"])
  }

  @Test("switching from an explicit input back to Auto restores index zero")
  func explicitToAutomaticSelection() throws {
    let access = RecordingInputDeviceAccess()
    let controller = MacGridWebRTCInputDeviceController(access: access)

    try controller.select(
      .device(id: "usb-uid", name: "USB Microphone"),
      in: snapshot
    )
    try controller.select(.automatic, in: snapshot)

    #expect(access.selectedDeviceIDs == ["202", "default"])
  }

  @Test("automatic recovery re-applies WebRTC's default policy")
  func automaticRecoverySelection() throws {
    let access = RecordingInputDeviceAccess()
    let controller = MacGridWebRTCInputDeviceController(access: access)
    var captureState = MacGridPlatformAudioCaptureState()
    captureState.inputSelected(.automatic)
    captureState.recordingStarted()
    captureState.recordingStopped()

    try controller.select(
      captureState.recoveryTarget(preserving: nil),
      in: snapshot
    )

    #expect(access.selectedDeviceIDs == ["default"])
  }

  @Test("selection fails before WebRTC advertises the requested device")
  func unavailableDeviceFails() {
    let access = RecordingInputDeviceAccess(availableDevices: [])
    let controller = MacGridWebRTCInputDeviceController(access: access)

    #expect(throws: MacGridWebRTCInputDeviceError.self) {
      try controller.select(.automatic, in: snapshot)
    }
    #expect(access.selectedDeviceIDs.isEmpty)
  }

  private var snapshot: MacGridAudioCatalogSnapshot {
    MacGridAudioCatalogSnapshot(
      devices: [
        device(id: 101, uid: "built-in-input-uid", name: "Built-in Microphone"),
        device(id: 202, uid: "usb-uid", name: "USB Microphone"),
      ],
      defaultInputID: 101,
      defaultOutputID: nil,
      epoch: 4
    )
  }

  private func device(
    id: AudioDeviceID,
    uid: String,
    name: String
  ) -> MacGridAudioDevice {
    MacGridAudioDevice(
      id: id,
      uid: uid,
      name: name,
      hasInput: true,
      hasOutput: false,
      sampleRate: 48_000,
      bufferFrameSize: 512,
      transport: 0
    )
  }
}

private final class RecordingInputDeviceAccess: MacGridWebRTCInputDeviceAccess,
  @unchecked Sendable {
  private let availableDevices: [MacGridWebRTCInputDevice]
  private(set) var selectedDeviceIDs: [String] = []

  init(
    availableDevices: [MacGridWebRTCInputDevice] = [
      MacGridWebRTCInputDevice(id: "default", name: "System Default"),
      MacGridWebRTCInputDevice(id: "202", name: "USB Microphone"),
    ]
  ) {
    self.availableDevices = availableDevices
  }

  func selectInputDevice(id: String) throws -> MacGridWebRTCInputDevice {
    guard let device = availableDevices.first(where: { $0.id == id }) else {
      throw MacGridWebRTCInputDeviceError.unavailable
    }
    selectedDeviceIDs.append(id)
    return device
  }
}
#endif
