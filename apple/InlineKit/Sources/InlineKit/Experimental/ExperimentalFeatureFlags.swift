import Auth
import Foundation
import InlineConfig

public enum ExperimentalFeatureFlags {
  public static let agentActivityKey = AgentActivityFeature.preferenceKey
  public static var agentActivityEnabled: Bool { AgentActivityFeature.isEnabled }

  public static let gridTranscriptionKey = "experimental.gridTranscription"

  /// Opt-in while the Grid transcription client experience is being rebuilt.
  public static var gridTranscriptionEnabled: Bool {
    UserDefaults.standard.bool(forKey: gridTranscriptionKey)
  }

  public static let newThreadAgentPickerKey = "experimental.newThreadAgentPicker"

  /// macOS-only, opt-in persistent agent selection for the new-thread composer.
  public static var newThreadAgentPickerEnabled: Bool {
    UserDefaults.standard.bool(forKey: newThreadAgentPickerKey)
  }

  /// Read only to migrate pre-`sidebarMode` installs; never written.
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

  /// Native downloads stay opt-in at every size, on either authenticated realtime transport.
  public static var nativeFileDownloadsEnabled: Bool {
    nativeFileDownloadsEnabled(auth: Auth.shared.handle)
  }

  static func nativeFileDownloadsEnabled(auth: AuthHandle) -> Bool {
    guard (try? auth.beginAccountMutation()) != nil else { return false }
    return UserDefaults.standard.bool(forKey: nativeFileDownloadsKey)
  }
}
