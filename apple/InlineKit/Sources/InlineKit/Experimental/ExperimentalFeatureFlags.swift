import Foundation

public enum ExperimentalFeatureFlags {
  public static let voiceMessagesKey = "experimental.voiceMessages"
  public static let sidebarAsInboxKey = "experimental.sidebarAsInbox"

  public static var voiceMessagesEnabled: Bool {
    get { isVoiceMessagesEnabled }
    set { setVoiceMessagesEnabled(newValue) }
  }

  public static var isVoiceMessagesEnabled: Bool {
    UserDefaults.standard.bool(forKey: voiceMessagesKey)
  }

  public static func setVoiceMessagesEnabled(_ isEnabled: Bool) {
    UserDefaults.standard.set(isEnabled, forKey: voiceMessagesKey)
  }

  public static var sidebarAsInboxEnabled: Bool {
    get { isSidebarAsInboxEnabled }
    set { setSidebarAsInboxEnabled(newValue) }
  }

  public static var isSidebarAsInboxEnabled: Bool {
    UserDefaults.standard.bool(forKey: sidebarAsInboxKey)
  }

  public static func setSidebarAsInboxEnabled(_ isEnabled: Bool) {
    UserDefaults.standard.set(isEnabled, forKey: sidebarAsInboxKey)
  }
}
