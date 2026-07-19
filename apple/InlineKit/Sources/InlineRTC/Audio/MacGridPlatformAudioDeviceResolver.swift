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
      guard snapshot.defaultInput != nil else {
        throw MacGridCoreAudioError.unavailable("No default microphone is available.")
      }
      return defaultDeviceID
    case let .device(uid, _):
      guard let device = snapshot.inputs.first(where: { $0.uid == uid }) else {
        throw MacGridCoreAudioError.unavailable("The selected microphone is no longer connected.")
      }
      return String(device.id)
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
