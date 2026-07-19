#if os(macOS)
import Foundation
import LiveKit

struct MacGridWebRTCInputDevice: Equatable, Sendable {
  let id: String
  let name: String
}

/// The narrow WebRTC device boundary used by Grid.
///
/// Route policy and durable device identity stay in InlineRTC. This boundary
/// performs only the final selection against WebRTC's post-transport device
/// inventory, which also makes policy transactions testable without audio
/// hardware or a running LiveKit room.
protocol MacGridWebRTCInputDeviceAccess: Sendable {
  func selectInputDevice(id: String) throws -> MacGridWebRTCInputDevice
}

struct LiveKitMacGridWebRTCInputDeviceAccess: MacGridWebRTCInputDeviceAccess {
  func selectInputDevice(id: String) throws -> MacGridWebRTCInputDevice {
    let manager = AudioManager.shared
    guard let device = manager.inputDevices.first(where: { $0.deviceId == id }) else {
      throw MacGridWebRTCInputDeviceError.unavailable
    }

    // M144's result-returning Obj-C helpers invert WebRTC's native
    // zero-on-success convention. Its ordinary setter discards that broken
    // Boolean while still performing the native selection. Recording startup
    // is the operational validation for the transaction.
    manager.inputDevice = device
    return MacGridWebRTCInputDevice(id: device.deviceId, name: device.name)
  }
}

struct MacGridWebRTCInputDeviceController: Sendable {
  private let access: any MacGridWebRTCInputDeviceAccess

  init(
    access: any MacGridWebRTCInputDeviceAccess = LiveKitMacGridWebRTCInputDeviceAccess()
  ) {
    self.access = access
  }

  @discardableResult
  func select(
    _ target: AudioInputRouteTarget,
    in snapshot: MacGridAudioCatalogSnapshot
  ) throws -> MacGridWebRTCInputDevice {
    let deviceID = try MacGridPlatformAudioDeviceResolver.platformInputDeviceID(
      for: target,
      in: snapshot
    )
    return try access.selectInputDevice(id: deviceID)
  }
}

enum MacGridWebRTCInputDeviceError: LocalizedError, Sendable {
  case unavailable

  var errorDescription: String? {
    "The selected microphone is not available to WebRTC."
  }
}
#endif
