import Foundation
import InlineConfig

public enum ExperimentalFeatureFlags {
  public static let newThreadAgentPickerKey = "experimental.newThreadAgentPicker"

  /// macOS-only, opt-in persistent agent selection for the new-thread composer.
  public static var newThreadAgentPickerEnabled: Bool {
    UserDefaults.standard.bool(forKey: newThreadAgentPickerKey)
  }

  /// Read only to migrate pre-`sidebarMode` installs; never written.
  public static let sidebarAsInboxKey = "experimental.sidebarAsInbox"
  public static let quickForwardKey = "experimental.quickForward"

  /// Opt-in macOS experiment; an unset preference intentionally defaults to false.
  public static var quickForwardEnabled: Bool {
    UserDefaults.standard.bool(forKey: quickForwardKey)
  }

  public static let newThreadComposerKey = "experimental.newThreadComposer"

  /// iOS and iPadOS: New Thread opens the first-message composer instead of creating an empty
  /// thread. Off until the composer is reliable; an unset preference defaults to false.
  public static var newThreadComposerEnabled: Bool {
    UserDefaults.standard.bool(forKey: newThreadComposerKey)
  }

  public static let fileBrowserKey = "experimental.fileBrowser"

  public static var fileBrowserEnabled: Bool {
    UserDefaults.standard.bool(forKey: fileBrowserKey)
  }
}
