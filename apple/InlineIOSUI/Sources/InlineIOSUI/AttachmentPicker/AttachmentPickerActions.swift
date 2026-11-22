#if os(iOS)
import Foundation

// The attachment picker's actions and notifications, kept out of the SwiftUI sheet so UIKit
// callers on every iOS version can build them.

public extension Notification.Name {
  static let attachmentPickerRecentMediaDidChange = Notification.Name("attachmentPickerRecentMediaDidChange")
}

public enum AttachmentPickerRecentMediaChangeUserInfo {
  public static let localIdentifiersKey = "localIdentifiers"
}

/// The agent controls switch, offered only while the draft would reach an
/// agent. Off keeps Compose as the plain bar in every chat.
public struct AttachmentPickerAgentControls {
  public let isShown: Bool
  public let setShown: (Bool) -> Void

  public init(isShown: Bool, setShown: @escaping (Bool) -> Void) {
    self.isShown = isShown
    self.setShown = setShown
  }
}

public struct AttachmentPickerActions {
  public let showCommands: () -> Void
  public let isCommandsEnabled: Bool
  public let openCamera: () -> Void
  public let openLibrary: () -> Void
  public let openFiles: () -> Void
  public let openRecentItem: (AttachmentPickerModel.RecentItem) -> Void
  public let openRecentItems: ([AttachmentPickerModel.RecentItem]) -> Void
  public let manageLimitedAccess: () -> Void
  public let agentControls: AttachmentPickerAgentControls?

  public init(
    showCommands: @escaping () -> Void,
    isCommandsEnabled: Bool,
    openCamera: @escaping () -> Void,
    openLibrary: @escaping () -> Void,
    openFiles: @escaping () -> Void,
    openRecentItem: @escaping (AttachmentPickerModel.RecentItem) -> Void,
    openRecentItems: @escaping ([AttachmentPickerModel.RecentItem]) -> Void,
    manageLimitedAccess: @escaping () -> Void,
    agentControls: AttachmentPickerAgentControls? = nil
  ) {
    self.showCommands = showCommands
    self.isCommandsEnabled = isCommandsEnabled
    self.openCamera = openCamera
    self.openLibrary = openLibrary
    self.openFiles = openFiles
    self.openRecentItem = openRecentItem
    self.openRecentItems = openRecentItems
    self.manageLimitedAccess = manageLimitedAccess
    self.agentControls = agentControls
  }
}
#endif
