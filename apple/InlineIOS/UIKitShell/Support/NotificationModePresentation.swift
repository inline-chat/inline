import InlineKit
import UIKit

extension NotificationMode {
  var systemImage: String {
    switch self {
    case .all: "bell"
    case .none: "bell.slash"
    case .mentions, .importantOnly, .onlyMentions: "at"
    }
  }

  var title: String {
    switch self {
    case .all: String(localized: "All")
    case .mentions, .importantOnly: String(localized: "Any message to you")
    case .onlyMentions: String(localized: "Only mentions")
    case .none: String(localized: "None")
    }
  }

  /// The four choices people pick from (`importantOnly` is the legacy "Any message to you").
  static let pickerModes: [NotificationMode] = [.all, .mentions, .onlyMentions, .none]

  func isSelected(in current: NotificationMode) -> Bool {
    self == current || (self == .mentions && current == .importantOnly)
  }
}

enum NotificationModeMenu {
  /// Global notification mode picker, used by the home bell and the iPad options menu.
  @MainActor
  static func menu(settings: NotificationSettingsManager) -> UIMenu {
    UIMenu(
      title: String(localized: "Notifications"),
      subtitle: settings.mode.title,
      image: UIImage(systemName: settings.mode.systemImage),
      options: .singleSelection,
      children: NotificationMode.pickerModes.map { mode in
        UIAction(
          title: mode.title,
          image: UIImage(systemName: mode.systemImage),
          state: mode.isSelected(in: settings.mode) ? .on : .off
        ) { _ in
          settings.mode = mode
        }
      }
    )
  }
}
