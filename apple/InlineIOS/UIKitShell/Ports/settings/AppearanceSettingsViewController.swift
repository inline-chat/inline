import Combine
import InlineCompatUI
import InlineIOSFoundation
import InlineKit
import InlineTheme
import TextProcessing
import UIKit

/// Appearance page (SwiftUI `AppearanceSettingsView`): theme, unread badges, chat toolbar
/// background (iOS 27+, like SwiftUI) and preferred emoji skin tone.
@MainActor
final class AppearanceSettingsViewController: SettingsFormViewController {
  init(shell: MainShellController) {
    super.init(shell: shell, title: String(localized: "Appearance"))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    reloadOnChange(ThemeManager.shared.$selectedPreset.dropFirst())
  }

  @FormSectionsBuilder
  override func makeSections() -> [FormSection] {
    let preset = ThemeManager.shared.selectedPreset
    let home = shell.home
    let badgeStyle = home.unreadBadgeStyle

    // The SwiftUI page pushes a card grid (`ThemeSelectionView`); a checkmark list here.
    FormSection("theme", header: String(localized: "Theme")) {
      for theme in ThemeManager.themes {
        FormRow.check("theme-\(theme.id)", theme.name, isSelected: theme.id == preset.rawValue) {
          guard theme.id != ThemeManager.shared.selectedPreset.rawValue else { return }
          ThemeManager.shared.switchToTheme(withID: theme.id)
          CompatHaptics.impact(.light)
        }
      }
    }

    FormSection("chatList", header: String(localized: "Chat List")) {
      FormRow.navigation(
        "unreadBadges",
        String(localized: "Unread Badges"),
        value: badgeStyle.title,
        icon: .tile("circle.inset.filled", .systemGray)
      ) { [weak self] in
        self?.push(SettingsPickerViewController(
          title: String(localized: "Unread Badges"),
          options: ExperimentalHomeUnreadBadgeStyle.allCases.map {
            SettingsPickerOption(id: $0.rawValue, title: $0.title, icon: FormIcon(systemName: $0.systemImage))
          },
          selectedID: { home.unreadBadgeStyle.rawValue },
          onSelect: { id, _ in
            guard let style = ExperimentalHomeUnreadBadgeStyle(rawValue: id) else { return }
            UserDefaults.standard.set(style.rawValue, forKey: ExperimentalHomePreferenceKeys.unreadBadgeStyle)
            // HomeShellState does not persist this one itself.
            home.unreadBadgeStyle = style
          }
        ))
      }
    }

    toolbarSection()

    FormSection("emoji", header: String(localized: "Emoji")) {
      FormRow.navigation(
        "skinTone",
        String(localized: "Preferred Skin Tone"),
        value: Self.skinToneLabel(EmojiSkinTonePreferenceStore.current()),
        icon: .tile("hand.raised.fill", .systemOrange)
      ) { [weak self] in
        self?.push(SettingsPickerViewController(
          title: String(localized: "Preferred Skin Tone"),
          options: EmojiSkinTone.allCases.map {
            SettingsPickerOption(id: $0.rawValue, title: Self.skinToneLabel($0))
          },
          selectedID: { EmojiSkinTonePreferenceStore.current().rawValue },
          onSelect: { id, _ in
            if let tone = EmojiSkinTone(rawValue: id) { EmojiSkinTonePreferenceStore.set(tone) }
          }
        ))
      }
    }
  }

  /// Only iOS 27+ draws the hard toolbar (see `ChatViewController.installHeader`).
  private func toolbarSection() -> [FormSection] {
    guard #available(iOS 27.0, *), CompatRuntime.allows(.iOS27) else { return [] }
    let mode = ChatToolbarBackgroundMode.initialValue
    return [FormSection(
      "chat",
      header: String(localized: "Chat"),
      footer: String(localized: "Soft fades gradually into the chat. Hard uses a clearer, separated toolbar background.")
    ) {
      FormRow.navigation(
        "toolbarBackground",
        String(localized: "Toolbar Background"),
        value: Self.toolbarLabel(mode),
        icon: .tile("rectangle.topthird.inset.filled", .systemBlue)
      ) { [weak self] in
        self?.push(SettingsPickerViewController(
          title: String(localized: "Toolbar Background"),
          footer: String(localized: "Reopen the chat after changing it."),
          options: [ChatToolbarBackgroundMode.soft, .hard].map {
            SettingsPickerOption(id: $0.rawValue, title: Self.toolbarLabel($0))
          },
          selectedID: { ChatToolbarBackgroundMode.initialValue.rawValue },
          onSelect: { id, _ in
            UserDefaults.standard.set(id, forKey: ChatToolbarBackgroundMode.key)
          }
        ))
      }
    }]
  }

  private static func toolbarLabel(_ mode: ChatToolbarBackgroundMode) -> String {
    switch mode {
    case .soft: String(localized: "Soft")
    case .hard: String(localized: "Hard")
    }
  }

  /// Same labels as the SwiftUI page (`EmojiSkinTone.settingsLabel` is iOS 17+ there).
  private static func skinToneLabel(_ tone: EmojiSkinTone) -> String {
    switch tone {
    case .standard: String(localized: "👋 Default")
    case .light: String(localized: "👋🏻 Light")
    case .mediumLight: String(localized: "👋🏼 Medium-Light")
    case .medium: String(localized: "👋🏽 Medium")
    case .mediumDark: String(localized: "👋🏾 Medium-Dark")
    case .dark: String(localized: "👋🏿 Dark")
    }
  }
}
