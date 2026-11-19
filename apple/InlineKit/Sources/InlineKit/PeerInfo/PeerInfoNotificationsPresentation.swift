import Foundation

/// How the Notifications button under the chat info header reads.
///
/// Inline stores four choices per chat: Default (inherit from the parent chat
/// or the global setting), All, Mentions and None. The button names the choice
/// in effect, so muting through Default (a muted parent, say) still shows as
/// muted, and leaves the choice itself to the menu.
public struct PeerInfoNotificationsPresentation: Equatable, Sendable {
  public var selection: DialogNotificationSettingSelection
  /// What actually notifies once Default is resolved.
  public var effectiveMode: NotificationMode
  public var globalMode: NotificationMode

  public init(selection: DialogNotificationSettingSelection, globalMode: NotificationMode) {
    self.selection = selection
    self.globalMode = globalMode
    effectiveMode = selection.resolveEffectiveMode(globalMode: globalMode)
  }

  /// Nothing notifies.
  public var isMuted: Bool { effectiveMode == .none }

  /// Button title: what this chat does right now.
  public var title: String {
    switch effectiveMode {
    case .none: String(localized: "Muted")
    case .mentions, .onlyMentions, .importantOnly: String(localized: "Mentions")
    case .all: String(localized: "Notify")
    }
  }

  /// Smaller line under the title: where that comes from.
  public var detail: String? {
    selection == .global ? String(localized: "Default") : nil
  }

  public var systemImage: String {
    switch effectiveMode {
    case .none: "bell.slash.fill"
    case .mentions, .onlyMentions, .importantOnly: "at"
    case .all: "bell"
    }
  }

  /// VoiceOver label: "Notifications, Mentions only, from default".
  public var accessibilityValue: String {
    let mode = switch effectiveMode {
    case .none: String(localized: "Muted")
    case .mentions, .onlyMentions, .importantOnly: String(localized: "Mentions only")
    case .all: String(localized: "All messages")
    }
    return selection == .global ? String(localized: "\(mode), from default") : mode
  }

  /// One tap away from the most common change: mute a chat that notifies, or
  /// turn a muted one back on.
  public var quickToggleSelection: DialogNotificationSettingSelection {
    guard isMuted else { return .none }
    let defaultIsMuted = DialogNotificationSettingSelection.global.resolveEffectiveMode(globalMode: globalMode) == .none
    return defaultIsMuted ? .all : .global
  }
}
