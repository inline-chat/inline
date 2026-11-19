import Foundation

/// Opt-in switch for people building on Inline (bots, integrations, agents). When on, the
/// apps show the Debug settings page, plus raw chat and user IDs in the chat menu and Chat
/// Info to copy into API calls, the CLI, or an agent prompt. Off by default; per device.
public enum DeveloperMode {
  public static let key = "developerMode"

  public static var isEnabled: Bool {
    UserDefaults.standard.bool(forKey: key)
  }
}
