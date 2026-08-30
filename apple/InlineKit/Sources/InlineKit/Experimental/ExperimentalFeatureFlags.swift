import Foundation

public enum ExperimentalFeatureFlags {
  public static let sidebarAsInboxKey = "experimental.sidebarAsInbox"
  public static let mentionableAgentsKey = "experimental.mentionableAgents"
  public static let nativeFileDownloadsKey = "experimental.nativeFileDownloads"

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

  public static var mentionableAgentsEnabled: Bool {
    UserDefaults.standard.bool(forKey: mentionableAgentsKey)
  }

  public static var nativeFileDownloadsEnabled: Bool {
    UserDefaults.standard.bool(forKey: nativeFileDownloadsKey)
  }
}

public extension Notification.Name {
  static let mentionableAgentsExperimentChanged = Notification.Name(
    "MentionableAgentsExperimentChanged"
  )
}
