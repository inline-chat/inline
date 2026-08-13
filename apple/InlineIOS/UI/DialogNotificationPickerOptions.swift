import InlineKit
import SwiftUI

enum DialogNotificationSettingsPresentation {
  static let globalDescription: LocalizedStringResource =
    "Follows your global setting for every chat."
  static let overrideDescription: LocalizedStringResource =
    "Overrides your global setting for this chat."
  static let overrideOptions: [DialogNotificationSettingSelection] = [.all, .mentions, .none]

  static func title(
    for selection: DialogNotificationSettingSelection,
    globalMode: NotificationMode
  ) -> LocalizedStringResource {
    switch selection {
    case .global:
      globalTitle(for: globalMode)
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
      switch globalMode {
      case .all:
        "bell.fill"
      case .mentions, .importantOnly, .onlyMentions:
        "at"
      case .none:
        "bell.slash.fill"
      }
    case .all:
      "bell.fill"
    case .mentions:
      "at"
    case .none:
      "bell.slash.fill"
    }
  }

  private static func globalTitle(for mode: NotificationMode) -> LocalizedStringResource {
    switch mode {
    case .all:
      "All"
    case .mentions, .importantOnly:
      "Any message to you"
    case .onlyMentions:
      "Only mentions"
    case .none:
      "None"
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
