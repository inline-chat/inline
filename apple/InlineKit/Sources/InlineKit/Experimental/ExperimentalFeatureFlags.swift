import Foundation

public enum ExperimentalFeatureFlags {
  public static let newThreadAgentPickerKey = "experimental.newThreadAgentPicker"

  /// macOS-only, opt-in persistent agent selection for the new-thread composer.
  public static var newThreadAgentPickerEnabled: Bool {
    UserDefaults.standard.bool(forKey: newThreadAgentPickerKey)
  }

  public static let sidebarAsInboxKey = "experimental.sidebarAsInbox"
  public static let nativeFileDownloadsKey = "experimental.nativeFileDownloads"
  public static let macMessageSelectionKey = "experimental.macMessageSelection"

  /// macOS-only and off by default, independent of the Quick Forward experiment.
  public static var macMessageSelectionEnabled: Bool {
    UserDefaults.standard.bool(forKey: macMessageSelectionKey)
  }

  public static let quickForwardKey = "experimental.quickForward"
  public static let richMessageCopyEditingKey = "experimental.richMessageCopyEditing"

  /// Opt-in on both Apple platforms; existing installations keep their current clipboard and editor behavior.
  public static var richMessageCopyEditingEnabled: Bool {
    UserDefaults.standard.bool(forKey: richMessageCopyEditingKey)
  }

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
