import Foundation

/// A durable output preference, not a projection of the currently connected
/// Core Audio device. An unavailable explicit device falls back to the system
/// default without erasing the preference and is restored when it returns.
public enum AudioOutputSelection: Equatable, Hashable, Sendable {
  case automatic
  case device(id: String, rememberedName: String)

  public func matches(_ device: AudioOutputDeviceDescriptor) -> Bool {
    guard case let .device(id, _) = self else { return false }
    return id == device.id
  }

  public func matches(
    _ device: AudioOutputDeviceDescriptor,
    among devices: [AudioOutputDeviceDescriptor]
  ) -> Bool {
    resolvedDeviceID(in: devices) == device.id
  }

  /// Stable UID wins. A remembered display name repairs an old UID only when
  /// exactly one currently connected output has that name.
  public func resolvedDeviceID(in devices: [AudioOutputDeviceDescriptor]) -> String? {
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

public struct AudioOutputDeviceDescriptor: Identifiable, Equatable, Sendable {
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

public struct ResolvedAudioOutput: Equatable, Sendable {
  public let selection: AudioOutputSelection
  public let activeDeviceID: String?
  public let activeDeviceName: String
  public let isFallingBackToAutomatic: Bool

  public init(
    selection: AudioOutputSelection,
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

public struct AudioOutputDeviceSnapshot: Equatable, Sendable {
  public let automaticDeviceID: String?
  public let automaticDeviceName: String
  public let devices: [AudioOutputDeviceDescriptor]
  public let resolvedOutput: ResolvedAudioOutput
  public let routeEpoch: UInt64

  public init(
    automaticDeviceID: String? = nil,
    automaticDeviceName: String,
    devices: [AudioOutputDeviceDescriptor],
    resolvedOutput: ResolvedAudioOutput,
    routeEpoch: UInt64 = 0
  ) {
    self.automaticDeviceID = automaticDeviceID
    self.automaticDeviceName = automaticDeviceName
    self.devices = devices
    self.resolvedOutput = resolvedOutput
    self.routeEpoch = routeEpoch
  }
}

@MainActor
public final class AudioOutputPreferenceStore {
  private let defaults: UserDefaults
  private let deviceIDKey: String
  private let deviceNameKey: String

  public init(
    defaults: UserDefaults = .standard,
    keyPrefix: String = "audio.output"
  ) {
    self.defaults = defaults
    deviceIDKey = "\(keyPrefix).preferredDeviceID"
    deviceNameKey = "\(keyPrefix).preferredDeviceName"
  }

  public init(
    defaults: UserDefaults = .standard,
    deviceIDKey: String,
    deviceNameKey: String
  ) {
    self.defaults = defaults
    self.deviceIDKey = deviceIDKey
    self.deviceNameKey = deviceNameKey
  }

  public var selection: AudioOutputSelection {
    guard let id = defaults.string(forKey: deviceIDKey),
          let name = defaults.string(forKey: deviceNameKey),
          !id.isEmpty,
          !name.isEmpty
    else { return .automatic }
    return .device(id: id, rememberedName: name)
  }

  public func setSelection(_ selection: AudioOutputSelection) {
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
