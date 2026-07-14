import Foundation

/// A user preference, not a currently connected device.
///
/// An explicit preference survives device removal. While it is unavailable,
/// the audio backend falls back to the system default without erasing the
/// preference, then restores it when the device returns.
public enum AudioInputSelection: Equatable, Hashable, Sendable {
  case automatic
  case device(id: String, rememberedName: String)

  public func matches(_ device: AudioInputDeviceDescriptor) -> Bool {
    guard case let .device(id, _) = self else { return false }
    return id == device.id
  }

  public func matches(
    _ device: AudioInputDeviceDescriptor,
    among devices: [AudioInputDeviceDescriptor]
  ) -> Bool {
    resolvedDeviceID(in: devices) == device.id
  }

  /// Resolves a persisted preference without guessing between same-name
  /// devices. Stable ID wins; remembered name is only a repair key when unique.
  public func resolvedDeviceID(in devices: [AudioInputDeviceDescriptor]) -> String? {
    guard case let .device(id, rememberedName) = self else { return nil }
    if devices.contains(where: { $0.id == id }) { return id }
    let normalizedRememberedName = rememberedName.trimmingCharacters(in: .whitespacesAndNewlines)
    let matchingNames = devices.filter {
      $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
        .localizedCaseInsensitiveCompare(normalizedRememberedName) == .orderedSame
    }
    return matchingNames.count == 1 ? matchingNames[0].id : nil
  }
}

public struct AudioInputDeviceDescriptor: Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let isSystemDefault: Bool
  public let systemImage: String

  public init(id: String, name: String, isSystemDefault: Bool, systemImage: String) {
    self.id = id
    self.name = name
    self.isSystemDefault = isSystemDefault
    self.systemImage = systemImage
  }
}

public struct ResolvedAudioInput: Equatable, Sendable {
  public let selection: AudioInputSelection
  public let activeDeviceID: String?
  public let activeDeviceName: String
  public let isFallingBackToAutomatic: Bool

  public init(
    selection: AudioInputSelection,
    activeDeviceID: String?,
    activeDeviceName: String,
    isFallingBackToAutomatic: Bool
  ) {
    self.selection = selection
    self.activeDeviceID = activeDeviceID
    self.activeDeviceName = activeDeviceName
    self.isFallingBackToAutomatic = isFallingBackToAutomatic
  }
}

public struct AudioInputDeviceSnapshot: Equatable, Sendable {
  /// The current physical device behind the system-default route. This is
  /// never the backend's synthetic `default` sentinel.
  public let automaticDeviceID: String?
  public let automaticDeviceName: String
  public let devices: [AudioInputDeviceDescriptor]
  public let resolvedInput: ResolvedAudioInput
  public let routeEpoch: UInt64

  public init(
    automaticDeviceID: String? = nil,
    automaticDeviceName: String,
    devices: [AudioInputDeviceDescriptor],
    resolvedInput: ResolvedAudioInput,
    routeEpoch: UInt64 = 0
  ) {
    self.automaticDeviceID = automaticDeviceID
    self.automaticDeviceName = automaticDeviceName
    self.devices = devices
    self.resolvedInput = resolvedInput
    self.routeEpoch = routeEpoch
  }
}

/// Persists input preference independently from any call or Grid lifecycle.
/// Keep this on the main actor because `UserDefaults` is process-global state
/// consumed by UI-owned feature services.
@MainActor
public final class AudioInputPreferenceStore {
  private let defaults: UserDefaults
  private let deviceIDKey: String
  private let deviceNameKey: String

  public init(
    defaults: UserDefaults = .standard,
    keyPrefix: String = "audio.input"
  ) {
    self.defaults = defaults
    deviceIDKey = "\(keyPrefix).preferredDeviceID"
    deviceNameKey = "\(keyPrefix).preferredDeviceName"
  }

  /// Use explicit keys when adopting this abstraction without invalidating an
  /// existing product preference.
  public init(
    defaults: UserDefaults = .standard,
    deviceIDKey: String,
    deviceNameKey: String
  ) {
    self.defaults = defaults
    self.deviceIDKey = deviceIDKey
    self.deviceNameKey = deviceNameKey
  }

  public var selection: AudioInputSelection {
    guard let id = defaults.string(forKey: deviceIDKey),
          let name = defaults.string(forKey: deviceNameKey),
          !id.isEmpty,
          !name.isEmpty
    else { return .automatic }
    return .device(id: id, rememberedName: name)
  }

  public func setSelection(_ selection: AudioInputSelection) {
    switch selection {
    case .automatic:
      defaults.removeObject(forKey: deviceIDKey)
      defaults.removeObject(forKey: deviceNameKey)
    case let .device(id, rememberedName):
      defaults.set(id, forKey: deviceIDKey)
      defaults.set(rememberedName, forKey: deviceNameKey)
    }
  }
}
