import Foundation

/// Opt-in switch for people building on Inline (bots, integrations, agents). When on, the
/// apps show raw chat and user IDs in the chat menu and Chat Info so they can be copied
/// into API calls, the CLI, or an agent prompt. Off by default; per device.
public enum DeveloperMode {
  public static let key = "developerMode"

  public static var isEnabled: Bool {
    UserDefaults.standard.bool(forKey: key)
  }
}
