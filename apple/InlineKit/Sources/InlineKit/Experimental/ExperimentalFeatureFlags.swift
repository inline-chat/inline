import Foundation

public enum ExperimentalFeatureFlags {
  public static let voiceMessagesKey = "experimental.voiceMessages"

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
}
