import Combine
import Foundation

/// Stores user-configurable hotkeys (UserDefaults-backed) without bloating `AppSettings`.
@MainActor
public final class HotkeySettingsStore: ObservableObject {
  public static let shared = HotkeySettingsStore(userDefaults: .standard)

  public struct GlobalFocusHotkey: Codable, Equatable {
    public var enabled: Bool
    public var hotkey: InlineHotkey?

    public init(enabled: Bool, hotkey: InlineHotkey?) {
      self.enabled = enabled
      self.hotkey = hotkey
    }
  }

  @Published public var globalFocusHotkey: GlobalFocusHotkey {
    didSet {
      persist(globalFocusHotkey)
    }
  }

  private let userDefaults: UserDefaults

  public init(userDefaults: UserDefaults) {
    self.userDefaults = userDefaults
    globalFocusHotkey =
      Self.load(from: userDefaults) ??
      GlobalFocusHotkey(enabled: false, hotkey: nil)
  }

  private static let globalFocusHotkeyKey = "globalFocusHotkey.v1"

  private func persist(_ value: GlobalFocusHotkey) {
    let encoder = JSONEncoder()
    guard let data = try? encoder.encode(value) else {
      // Don't overwrite the last known good value if encoding fails.
      return
    }
    userDefaults.set(data, forKey: Self.globalFocusHotkeyKey)
  }

  private static func load(from userDefaults: UserDefaults) -> GlobalFocusHotkey? {
    guard let data = userDefaults.data(forKey: Self.globalFocusHotkeyKey) else {
      return nil
    }
    return try? JSONDecoder().decode(GlobalFocusHotkey.self, from: data)
  }
}
