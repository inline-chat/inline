import Foundation

public enum ExperimentalFeatureFlags {
  public static let voiceMessagesKey = "experimental.voiceMessages"
  public static let replyThreadMenuItemsKey = "experimental.replyThreadMenuItems"

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

  public static var replyThreadMenuItemsEnabled: Bool {
    get { isReplyThreadMenuItemsEnabled }
    set { setReplyThreadMenuItemsEnabled(newValue) }
  }

  public static var isReplyThreadMenuItemsEnabled: Bool {
    UserDefaults.standard.bool(forKey: replyThreadMenuItemsKey)
  }

  public static func setReplyThreadMenuItemsEnabled(_ isEnabled: Bool) {
    UserDefaults.standard.set(isEnabled, forKey: replyThreadMenuItemsKey)
  }
}
