import Combine
import InlineCompatUI
import InlineGrid
import InlineIOSFoundation
import InlineKit
import Translation
import UIKit

/// General page (SwiftUI `GeneralSettingsView`): links, compose, message gestures, Grid sounds,
/// translation alerts and Developer Mode.
@MainActor
final class GeneralSettingsViewController: SettingsFormViewController {
  init(shell: MainShellController) {
    super.init(shell: shell, title: String(localized: "General"))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    reloadOnChange(INUserSettings.current.compose.objectWillChange)
    reloadOnChange(INUserSettings.current.messageGestures.objectWillChange)
  }

  @FormSectionsBuilder
  override func makeSections() -> [FormSection] {
    let compose = INUserSettings.current.compose
    let gestures = INUserSettings.current.messageGestures
    let defaults = UserDefaults.standard

    FormSection("links", footer: String(localized: "When off, links open in your default browser or the matching app.")) {
      FormRow.toggle(
        "openLinksInApp",
        String(localized: "Open Links In App"),
        icon: .tile("safari.fill", .systemIndigo),
        isOn: InAppLinkPreferences.opensLinksInApp(userDefaults: defaults)
      ) { isOn in
        InAppLinkPreferences.setOpensLinksInApp(isOn, userDefaults: defaults)
      }
    }

    FormSection(
      "shortenLinks",
      footer: String(localized: "Turn supported pasted links into compact text links. Use Undo or Backspace to restore the URL.")
    ) {
      FormRow.toggle(
        "shortenLinks",
        String(localized: "Shorten Supported Links"),
        icon: .tile("link", .systemBlue),
        isOn: compose.replacePastedLinksWithTitles
      ) { isOn in
        compose.replacePastedLinksWithTitles = isOn
      }
    }

    if UIDevice.current.userInterfaceIdiom == .pad {
      FormSection(
        "sendWithReturn",
        footer: String(localized: "When enabled, Return sends and Shift-Return adds a new line on an external keyboard. Applies only to this iPad.")
      ) {
        FormRow.toggle(
          "sendWithReturn",
          String(localized: "Send with Return"),
          icon: .tile("keyboard", .systemBlue),
          isOn: compose.sendWithReturnOnIPad
        ) { isOn in
          compose.sendWithReturnOnIPad = isOn
        }
      }
    }

    FormSection(
      "gestures",
      header: String(localized: "Message Gestures"),
      footer: String(localized: "Sync double-tap, hold, and swipe direction across your devices. Turn off to customize this device. Turning it back on uses your synced choices.")
    ) {
      FormRow.toggle(
        "syncGestures",
        String(localized: "Sync Message Gestures"),
        icon: .tile("arrow.triangle.2.circlepath", .systemBlue),
        isOn: gestures.syncEnabled
      ) { isOn in
        gestures.syncEnabled = isOn
      }
      FormRow.navigation(
        "doubleTap",
        String(localized: "Double Tap"),
        value: gestures.doubleTapAction.title,
        icon: .tile("hand.tap", .systemBlue)
      ) { [weak self] in
        self?.push(Self.gesturePicker(
          title: String(localized: "Double Tap"),
          actions: MessageGestureAction.allCases,
          selected: { gestures.doubleTapAction },
          onSelect: { gestures.doubleTapAction = $0 }
        ))
      }
      FormRow.navigation(
        "hold",
        String(localized: "Hold"),
        value: gestures.holdAction.title,
        icon: .tile("hand.point.up.left", .systemOrange)
      ) { [weak self] in
        self?.push(Self.gesturePicker(
          title: String(localized: "Hold"),
          actions: MessageGestureAction.allCases.filter { $0 != .none },
          selected: { gestures.holdAction },
          onSelect: { gestures.holdAction = $0 }
        ))
      }
      FormRow.navigation(
        "swipeToReply",
        String(localized: "Swipe to Reply"),
        value: gestures.swipeToReplyDirection.title,
        icon: .tile("arrow.left.arrow.right", .systemGreen)
      ) { [weak self] in
        self?.push(SettingsPickerViewController(
          title: String(localized: "Swipe to Reply"),
          options: MessageSwipeToReplyDirection.allCases.map {
            SettingsPickerOption(id: $0.rawValue, title: $0.title)
          },
          selectedID: { gestures.swipeToReplyDirection.rawValue },
          onSelect: { id, _ in
            if let direction = MessageSwipeToReplyDirection(rawValue: id) {
              gestures.swipeToReplyDirection = direction
            }
          }
        ))
      }
    }

    gridSection()

    FormSection("translation", header: String(localized: "Language & Translation")) {
      FormRow.action(
        "resetTranslationAlerts",
        String(localized: "Reset Translation Alerts"),
        icon: .tile("bell.slash.fill", .systemOrange),
        role: .normal
      ) {
        TranslationAlertDismiss.shared.resetAllDismissStates()
        ToastManager.shared.showToast(
          String(localized: "Translation alerts reset"),
          type: .success,
          systemImage: "checkmark.circle.fill"
        )
      }
    }

    FormSection(
      "developer",
      header: String(localized: "Developer"),
      footer: String(localized: "Show the Debug page, plus chat and user IDs in the chat menu and Chat Info, for bots, integrations, and agents.")
    ) {
      FormRow.toggle(
        "developerMode",
        String(localized: "Developer Mode"),
        icon: .tile("hammer.fill", .systemGray),
        isOn: defaults.bool(forKey: DeveloperMode.key)
      ) { isOn in
        defaults.set(isOn, forKey: DeveloperMode.key)
      }
    }
  }

  /// Grid microphone sounds, for people who have Grid in a space (same gate as Home's Grid entry).
  private func gridSection() -> [FormSection] {
    guard #available(iOS 18.0, *) else { return [] }
    let rooms = GridIOSRuntime.shared.rooms
    guard GridHomeEntryProjection(store: rooms, spaceID: nil).isEligible else { return [] }
    return [
      FormSection(
        "grid",
        header: String(localized: "Grid"),
        footer: String(localized: "Play a short sound when you mute or unmute your microphone.")
      ) {
        FormRow.toggle(
          "microphoneSounds",
          String(localized: "Microphone Sounds"),
          icon: .tile("mic.fill", .systemGreen),
          isOn: rooms.playsMicrophoneSounds
        ) { isOn in
          rooms.playsMicrophoneSounds = isOn
        }
      },
    ]
  }

  private static func gesturePicker(
    title: String,
    actions: [MessageGestureAction],
    selected: @escaping @MainActor () -> MessageGestureAction,
    onSelect: @escaping @MainActor (MessageGestureAction) -> Void
  ) -> SettingsPickerViewController {
    SettingsPickerViewController(
      title: title,
      options: actions.map { SettingsPickerOption(id: $0.rawValue, title: $0.title) },
      selectedID: { selected().rawValue },
      onSelect: { id, _ in
        if let action = MessageGestureAction(rawValue: id) { onSelect(action) }
      }
    )
  }
}
