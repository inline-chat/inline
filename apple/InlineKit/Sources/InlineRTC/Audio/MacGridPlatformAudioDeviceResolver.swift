#if os(macOS)
import CoreAudio
import Foundation

/// Translates between Grid's durable Core Audio UIDs and WebRTC's
/// process-local device identifiers.
///
/// WebRTC represents the system-default policy route as `default`. Explicit
/// routes use a decimal `AudioDeviceID`, which is not stable enough to persist.
enum MacGridPlatformAudioDeviceResolver {
  static let defaultDeviceID = "default"

  static func platformInputDeviceID(
    for target: AudioInputRouteTarget,
    in snapshot: MacGridAudioCatalogSnapshot
  ) throws -> String {
    switch target {
    case .automatic:
      _ = try inputDevice(for: target, in: snapshot)
      return defaultDeviceID
    case .device:
      let device = try inputDevice(for: target, in: snapshot)
      return String(device.id)
    }
  }

  static func inputDevice(
    for target: AudioInputRouteTarget,
    in snapshot: MacGridAudioCatalogSnapshot
  ) throws -> MacGridAudioDevice {
    switch target {
    case .automatic:
      guard let device = snapshot.defaultInput else {
        throw MacGridCoreAudioError.unavailable("No default microphone is available.")
      }
      guard MacGridAudioRouteTransitionPolicy.inputIsUsable(device) else {
        throw MacGridCoreAudioError.unavailable(
          "The default microphone has no readable live input format."
        )
      }
      return device
    case let .device(uid, _):
      guard let device = snapshot.inputs.first(where: { $0.uid == uid }) else {
        throw MacGridCoreAudioError.unavailable("The selected microphone is no longer connected.")
      }
      guard MacGridAudioRouteTransitionPolicy.inputIsUsable(device) else {
        throw MacGridCoreAudioError.unavailable(
          "The selected microphone has no readable live input format."
        )
      }
      return device
    }
  }

  static func outputDevice(
    for target: AudioOutputRouteTarget,
    in snapshot: MacGridAudioCatalogSnapshot
  ) throws -> MacGridAudioDevice {
    switch target {
    case .automatic:
      guard let device = snapshot.defaultOutput else {
        throw MacGridCoreAudioError.unavailable("No default output device is available.")
      }
      guard MacGridAudioRouteTransitionPolicy.outputIsUsable(device) else {
        throw MacGridCoreAudioError.unavailable(
          "The default output device has no readable live format."
        )
      }
      return device
    case let .device(uid, _):
      guard let device = snapshot.outputs.first(where: { $0.uid == uid }) else {
        throw MacGridCoreAudioError.unavailable("The selected output device is no longer connected.")
      }
      guard MacGridAudioRouteTransitionPolicy.outputIsUsable(device) else {
        throw MacGridCoreAudioError.unavailable(
          "The selected output device has no readable live format."
        )
      }
      return device
    }
  }

  static func stableInputUID(
    forPlatformDeviceID deviceID: String,
    in snapshot: MacGridAudioCatalogSnapshot
  ) -> String? {
    stableUID(
      forPlatformDeviceID: deviceID,
      defaultDevice: snapshot.defaultInput,
      devices: snapshot.inputs
    )
  }

  static func stableOutputUID(
    forPlatformDeviceID deviceID: String,
    in snapshot: MacGridAudioCatalogSnapshot
  ) -> String? {
    stableUID(
      forPlatformDeviceID: deviceID,
      defaultDevice: snapshot.defaultOutput,
      devices: snapshot.outputs
    )
  }

  private static func stableUID(
    forPlatformDeviceID deviceID: String,
    defaultDevice: MacGridAudioDevice?,
    devices: [MacGridAudioDevice]
  ) -> String? {
    if deviceID == defaultDeviceID {
      return defaultDevice?.uid
    }
    return devices.first(where: { String($0.id) == deviceID })?.uid
  }
}
#endif
