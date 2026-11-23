import Combine
import InlineCompatUI
import InlineIOSFoundation
import InlineKit
import UIKit

/// Notifications page (SwiftUI `NotificationsSettingsView`): global mode and sounds.
@MainActor
final class NotificationsSettingsViewController: SettingsFormViewController {
  init(shell: MainShellController) {
    super.init(shell: shell, title: String(localized: "Notifications"))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    reloadOnChange(INUserSettings.current.notification.objectWillChange)
  }

  @FormSectionsBuilder
  override func makeSections() -> [FormSection] {
    let settings = INUserSettings.current.notification

    FormSection("mode", header: String(localized: "Notify Me For")) {
      for mode in NotificationMode.pickerModes {
        FormRow.check(
          "mode-\(mode.rawValue)",
          mode.title,
          icon: FormIcon(systemName: Self.symbol(for: mode)),
          isSelected: mode.isSelected(in: settings.mode)
        ) {
          guard !mode.isSelected(in: settings.mode) else { return }
          CompatHaptics.selection()
          settings.mode = mode
          // Same pairing as the SwiftUI picker: "Only mentions" also mutes DMs.
          settings.disableDmNotifications = mode == .onlyMentions
        }
      }
    }

    FormSection("sound", header: String(localized: "Sound")) {
      FormRow.toggle(
        "silent",
        String(localized: "Disable Sounds"),
        icon: .tile("speaker.slash.fill", .systemRed),
        isOn: settings.silent
      ) { isOn in
        settings.silent = isOn
      }
    }
  }

  /// The SwiftUI picker's symbols (filled variants, distinct icon for "Only mentions").
  private static func symbol(for mode: NotificationMode) -> String {
    switch mode {
    case .all: "bell.fill"
    case .mentions, .importantOnly: "at"
    case .onlyMentions: "at.badge.minus"
    case .none: "bell.slash.fill"
    }
  }
}
