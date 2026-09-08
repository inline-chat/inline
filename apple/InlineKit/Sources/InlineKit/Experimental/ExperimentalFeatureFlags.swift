import Foundation

public enum ExperimentalFeatureFlags {
  public static let sidebarAsInboxKey = "experimental.sidebarAsInbox"
  public static let nativeFileDownloadsKey = "experimental.nativeFileDownloads"
  public static let quickForwardKey = "experimental.quickForward"

  /// Opt-in macOS experiment; an unset preference intentionally defaults to false.
  public static var quickForwardEnabled: Bool {
    UserDefaults.standard.bool(forKey: quickForwardKey)
  }

  public static let fileBrowserKey = "experimental.fileBrowser"

  public static var fileBrowserEnabled: Bool {
    UserDefaults.standard.bool(forKey: fileBrowserKey)
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

  public static var nativeFileDownloadsEnabled: Bool {
    UserDefaults.standard.bool(forKey: nativeFileDownloadsKey)
  }
}
