import Combine
import Foundation

/// Stores user-configurable hotkeys (UserDefaults-backed) without bloating `AppSettings`.
@MainActor
public final class HotkeySettingsStore: ObservableObject {
  public static let shared = HotkeySettingsStore(userDefaults: .standard)

  public struct HotkeyConfiguration: Codable, Equatable {
    public var enabled: Bool
    public var hotkey: InlineHotkey?

    public init(enabled: Bool, hotkey: InlineHotkey?) {
      self.enabled = enabled
      self.hotkey = hotkey
    }
  }

  public typealias GlobalFocusHotkey = HotkeyConfiguration

  @Published public var globalFocusHotkey: HotkeyConfiguration {
    didSet {
      persist(globalFocusHotkey, key: Self.globalFocusHotkeyKey)
    }
  }

  @Published public var gridMicrophoneHotkey: HotkeyConfiguration {
    didSet {
      persist(gridMicrophoneHotkey, key: Self.gridMicrophoneHotkeyKey)
    }
  }

  private let userDefaults: UserDefaults

  public init(userDefaults: UserDefaults) {
    self.userDefaults = userDefaults
    globalFocusHotkey =
      Self.load(from: userDefaults, key: Self.globalFocusHotkeyKey) ??
      HotkeyConfiguration(enabled: false, hotkey: nil)
    gridMicrophoneHotkey =
      Self.load(from: userDefaults, key: Self.gridMicrophoneHotkeyKey) ??
      HotkeyConfiguration(enabled: false, hotkey: nil)
  }

  private static let globalFocusHotkeyKey = "globalFocusHotkey.v1"
  private static let gridMicrophoneHotkeyKey = "gridMicrophoneHotkey.v1"

  private func persist(_ value: HotkeyConfiguration, key: String) {
    let encoder = JSONEncoder()
    guard let data = try? encoder.encode(value) else {
      // Don't overwrite the last known good value if encoding fails.
      return
    }
    userDefaults.set(data, forKey: key)
  }

  private static func load(from userDefaults: UserDefaults, key: String) -> HotkeyConfiguration? {
    guard let data = userDefaults.data(forKey: key) else {
      return nil
    }
    return try? JSONDecoder().decode(HotkeyConfiguration.self, from: data)
  }
}
