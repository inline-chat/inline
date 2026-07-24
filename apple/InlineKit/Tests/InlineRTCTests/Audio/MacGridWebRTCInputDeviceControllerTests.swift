#if os(macOS)
import CoreAudio
import Testing

@testable import InlineRTC

@Suite("WebRTC input-device boundary")
struct MacGridWebRTCInputDeviceControllerTests {
  @Test("initial Auto selects WebRTC's enumerated default device")
  func initialAutomaticSelection() async throws {
    let access = RecordingInputDeviceAccess()
    let controller = MacGridWebRTCInputDeviceController(access: access)

    let selected = try await controller.select(.automatic, in: snapshot)

    #expect(selected.id == "default")
    #expect(access.selectedDeviceIDs == ["default"])
  }

  @Test("switching from an explicit input back to Auto restores index zero")
  func explicitToAutomaticSelection() async throws {
    let access = RecordingInputDeviceAccess()
    let controller = MacGridWebRTCInputDeviceController(access: access)

    try await controller.select(
      .device(id: "usb-uid", name: "USB Microphone"),
      in: snapshot
    )
    try await controller.select(.automatic, in: snapshot)

    #expect(access.selectedDeviceIDs == ["202", "default"])
  }

  @Test("automatic recovery re-applies WebRTC's default policy")
  func automaticRecoverySelection() async throws {
    let access = RecordingInputDeviceAccess()
    let controller = MacGridWebRTCInputDeviceController(access: access)
    var captureState = MacGridPlatformAudioCaptureState()
    captureState.inputSelected(.automatic)
    captureState.recordingStarted()
    captureState.recordingStopped()

    try await controller.select(
      captureState.recoveryTarget(preserving: nil),
      in: snapshot
    )

    #expect(access.selectedDeviceIDs == ["default"])
  }

  @Test("selection waits for WebRTC's inventory to converge")
  func waitsForInventoryConvergence() async throws {
    let access = RecordingInputDeviceAccess(
      availableDevicesByAttempt: [
        [],
        [],
        [MacGridWebRTCInputDevice(id: "default", name: "System Default")],
      ]
    )
    let controller = MacGridWebRTCInputDeviceController(
      access: access,
      maximumAttempts: 3,
      retryDelay: .zero,
      sleep: { _ in }
    )

    let selected = try await controller.select(.automatic, in: snapshot)

    #expect(selected.id == "default")
    #expect(access.requestedDeviceIDs == ["default", "default", "default"])
    #expect(access.selectedDeviceIDs == ["default"])
  }

  @Test("an explicit route re-resolves its ephemeral Core Audio ID while settling")
  func explicitRouteReResolvesEphemeralID() async throws {
    let catalogs = SnapshotSequence(
      snapshot,
      then: [snapshot(usbDeviceID: 303)]
    )
    let access = RecordingInputDeviceAccess(availableDevices: [
      MacGridWebRTCInputDevice(id: "303", name: "USB Microphone"),
    ])
    let controller = MacGridWebRTCInputDeviceController(
      access: access,
      maximumAttempts: 2,
      retryDelay: .zero,
      sleep: { _ in }
    )

    let selected = try await controller.select(
      .device(id: "usb-uid", name: "USB Microphone"),
      snapshot: { await catalogs.next() }
    )

    #expect(access.requestedDeviceIDs == ["202", "303"])
    #expect(selected.webRTCDevice.id == "303")
    #expect(selected.physicalDevice.id == 303)
    #expect(selected.physicalDevice.uid == "usb-uid")
  }

  @Test("a persistent inventory gap reports bounded diagnostic state")
  func persistentInventoryGapFailsAfterBoundedAttempts() async {
    let access = RecordingInputDeviceAccess(availableDevices: [])
    let controller = MacGridWebRTCInputDeviceController(
      access: access,
      maximumAttempts: 3,
      retryDelay: .zero,
      sleep: { _ in }
    )

    do {
      _ = try await controller.select(.automatic, in: snapshot)
      Issue.record("Expected WebRTC inventory convergence to time out")
    } catch let error as MacGridWebRTCInputDeviceError {
      #expect(error.requestedID == "default")
      #expect(error.availableIDs.isEmpty)
      #expect(error.attempts == 3)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
    #expect(access.requestedDeviceIDs == ["default", "default", "default"])
    #expect(access.selectedDeviceIDs.isEmpty)
  }

  private var snapshot: MacGridAudioCatalogSnapshot {
    snapshot(usbDeviceID: 202)
  }

  private func snapshot(usbDeviceID: AudioDeviceID) -> MacGridAudioCatalogSnapshot {
    MacGridAudioCatalogSnapshot(
      devices: [
        device(id: 101, uid: "built-in-input-uid", name: "Built-in Microphone"),
        device(id: usbDeviceID, uid: "usb-uid", name: "USB Microphone"),
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
    let format = MacGridAudioStreamFormat(
      AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: 1,
        mBitsPerChannel: 32,
        mReserved: 0
      )
    )
    return MacGridAudioDevice(
      id: id,
      uid: uid,
      name: name,
      hasInput: true,
      hasOutput: false,
      sampleRate: 48_000,
      bufferFrameSize: 512,
      transport: 0,
      inputStreamFormat: format
    )
  }
}

private actor SnapshotSequence {
  private var current: MacGridAudioCatalogSnapshot
  private var snapshots: [MacGridAudioCatalogSnapshot]

  init(
    _ first: MacGridAudioCatalogSnapshot,
    then snapshots: [MacGridAudioCatalogSnapshot]
  ) {
    current = first
    self.snapshots = [first] + snapshots
  }

  func next() -> MacGridAudioCatalogSnapshot {
    if let next = snapshots.first {
      current = next
      snapshots.removeFirst()
    }
    return current
  }
}

private final class RecordingInputDeviceAccess: MacGridWebRTCInputDeviceAccess,
  @unchecked Sendable {
  private var availableDevicesByAttempt: [[MacGridWebRTCInputDevice]]
  private(set) var requestedDeviceIDs: [String] = []
  private(set) var selectedDeviceIDs: [String] = []

  init(
    availableDevices: [MacGridWebRTCInputDevice] = [
      MacGridWebRTCInputDevice(id: "default", name: "System Default"),
      MacGridWebRTCInputDevice(id: "202", name: "USB Microphone"),
    ]
  ) {
    availableDevicesByAttempt = [availableDevices]
  }

  init(availableDevicesByAttempt: [[MacGridWebRTCInputDevice]]) {
    self.availableDevicesByAttempt = availableDevicesByAttempt
  }

  func selectInputDevice(id: String) throws -> MacGridWebRTCInputDevice {
    requestedDeviceIDs.append(id)
    let availableDevices = availableDevicesByAttempt.count > 1
      ? availableDevicesByAttempt.removeFirst()
      : availableDevicesByAttempt.first ?? []
    guard let device = availableDevices.first(where: { $0.id == id }) else {
      throw MacGridWebRTCInputDeviceError.inventoryDidNotConverge(
        requestedID: id,
        availableIDs: availableDevices.map(\.id),
        attempts: 1
      )
    }
    selectedDeviceIDs.append(id)
    return device
  }
}
#endif
