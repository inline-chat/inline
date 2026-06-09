import InlineProtocol

enum NotificationSettingsCompat {
  static func mode(from protocolMode: InlineProtocol.NotificationSettings.Mode, disableDmNotifications: Bool) -> NotificationMode {
    if protocolMode == .importantOnly {
      return .mentions
    }

    if protocolMode == .onlyMentions || (protocolMode == .mentions && disableDmNotifications) {
      return .onlyMentions
    }

    switch protocolMode {
      case .all:
        return .all
      case .mentions:
        return .mentions
      case .none:
        return .none
      case .unspecified, .importantOnly, .onlyMentions, .UNRECOGNIZED:
        return .all
    }
  }

  static func mode(from cachedMode: NotificationMode, disableDmNotifications: Bool) -> NotificationMode {
    if cachedMode == .importantOnly {
      return .mentions
    }

    if cachedMode == .onlyMentions || (cachedMode == .mentions && disableDmNotifications) {
      return .onlyMentions
    }

    return cachedMode
  }

  static func protocolMode(from mode: NotificationMode) -> InlineProtocol.NotificationSettings.Mode {
    switch mode {
      case .all:
        return .all
      case .mentions, .importantOnly:
        return .mentions
      case .none:
        return .none
      case .onlyMentions:
        return .onlyMentions
    }
  }
}
