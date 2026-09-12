import InlineKit
import SwiftUI

enum DialogNotificationSettingsPresentation {
  static let globalDescription: LocalizedStringResource =
    "Follows the parent chat’s settings, or your global settings for a top-level chat."
  static let overrideDescription: LocalizedStringResource =
    "Overrides inherited notification settings for this chat."
  static let overrideOptions: [DialogNotificationSettingSelection] = [.all, .mentions, .none]

  static func title(
    for selection: DialogNotificationSettingSelection,
    globalMode: NotificationMode
  ) -> LocalizedStringResource {
    switch selection {
    case .global:
      "Default"
    case .all:
      "All"
    case .mentions:
      "Mentions"
    case .none:
      "None"
    }
  }

  static func iconName(
    for selection: DialogNotificationSettingSelection,
    globalMode: NotificationMode
  ) -> String {
    switch selection {
    case .global:
      "bell"
    case .all:
      "bell.fill"
    case .mentions:
      "at"
    case .none:
      "bell.slash.fill"
    }
  }
}

/// Menu-native notification choices. Using direct menu toggles instead of an
/// inline Picker preserves the two explanatory sections in nested menus.
struct DialogNotificationSettingsMenuContent: View {
  @Binding var selection: DialogNotificationSettingSelection
  let globalMode: NotificationMode

  var body: some View {
    Section {
      option(.global)
    } header: {
      Text(DialogNotificationSettingsPresentation.globalDescription)
    }

    Section("Overrides for this chat") {
      ForEach(DialogNotificationSettingsPresentation.overrideOptions, id: \.self) { option in
        self.option(option)
      }
    }
  }

  private func option(_ option: DialogNotificationSettingSelection) -> some View {
    Toggle(isOn: optionBinding(option)) {
      DialogNotificationPickerOptionLabel(
        selection: option,
        globalMode: globalMode,
        title: DialogNotificationSettingsPresentation.title(
          for: option,
          globalMode: globalMode
        )
      )
    }
    .accessibilityHint(Text(
      option == .global
        ? DialogNotificationSettingsPresentation.globalDescription
        : DialogNotificationSettingsPresentation.overrideDescription
    ))
  }

  private func optionBinding(_ option: DialogNotificationSettingSelection) -> Binding<Bool> {
    Binding(
      get: { selection == option },
      set: { isSelected in
        guard isSelected else { return }
        selection = option
      }
    )
  }
}

struct DialogNotificationPickerOptionLabel: View {
  let selection: DialogNotificationSettingSelection
  let globalMode: NotificationMode
  let title: LocalizedStringResource

  var body: some View {
    Label {
      Text(title)
    } icon: {
      Image(systemName: DialogNotificationSettingsPresentation.iconName(
        for: selection,
        globalMode: globalMode
      ))
    }
  }
}
