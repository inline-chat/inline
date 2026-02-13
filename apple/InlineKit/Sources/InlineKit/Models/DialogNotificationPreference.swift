import InlineProtocol

public extension Dialog {
  var notificationSelection: DialogNotificationSettingSelection {
    guard let notificationSettings else {
      return .global
    }

    switch notificationSettings.mode {
      case .all:
        return .all
      case .mentions:
        return .mentions
      case .none:
        return .none
      case .unspecified, .UNRECOGNIZED:
        return .global
    }
  }
}

public extension DialogNotificationSettingSelection {
  func resolveEffectiveMode(globalMode: NotificationMode) -> NotificationMode {
    switch self {
      case .global:
        return globalMode
      case .all:
        return .all
      case .mentions:
        return .mentions
      case .none:
        return .none
    }
  }

  var title: String {
    switch self {
      case .global:
        "Use Global"
      case .all:
        "All"
      case .mentions:
        "Mentions"
      case .none:
        "None"
    }
  }

  var iconName: String {
    switch self {
      case .global:
        "bell"
      case .all:
        "bell.fill"
      case .mentions:
        "at"
      case .none:
        "bell.slash"
    }
  }

  var menuDescription: String {
    switch self {
      case .global:
        "Use your global notification settings for this chat."
      case .all:
        "Notify for every message in this chat."
      case .mentions:
        "Notify when you are mentioned or replied to."
      case .none:
        "Mute notifications for this chat."
    }
  }
}
