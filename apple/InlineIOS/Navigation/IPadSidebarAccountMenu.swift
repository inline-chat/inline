import InlineKit
import UIKit

/// Notifications and Settings for the iPad sidebar's options menu. The sidebar has no
/// account button or bell of its own.
enum IPadSidebarAccountMenu {
  static func section(
    notificationMode: NotificationMode,
    onSelectNotificationMode: @escaping (NotificationMode) -> Void,
    onSettings: @escaping () -> Void
  ) -> UIMenu {
    let modes: [NotificationMode] = [.all, .mentions, .onlyMentions, .none]
    let notifications = UIMenu(
      title: "Notifications",
      subtitle: String(localized: notificationMode.valueTitle),
      image: UIImage(systemName: notificationMode.systemImage),
      children: modes.map { mode in
        // `importantOnly` is the legacy form of "Any message to you".
        let isSelected = mode == notificationMode
          || (mode == .mentions && notificationMode == .importantOnly)
        return UIAction(
          title: String(localized: mode.valueTitle),
          image: UIImage(systemName: mode.systemImage),
          state: isSelected ? .on : .off
        ) { _ in
          onSelectNotificationMode(mode)
        }
      }
    )
    let settings = UIAction(title: "Settings", image: UIImage(systemName: "gearshape")) { _ in
      onSettings()
    }
    return UIMenu(options: .displayInline, children: [notifications, settings])
  }
}
