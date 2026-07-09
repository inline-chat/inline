import InlineMacUI
import SwiftUI

struct AppearanceSettingsDetailView: View {
  @StateObject private var appSettings = AppSettings.shared

  var body: some View {
    Form {
      Section {
        LabeledContent {
          AppearancePicker(selection: $appSettings.appearance)
        } label: {
          SettingsRowLabel("Appearance")
        }

        Toggle(isOn: $appSettings.usesCompactToolbar) {
          SettingsRowLabel(
            "Compact Toolbar",
            description: "Use less vertical space in chat window toolbars."
          )
        }
      } header: {
        SettingsSectionHeader("Interface")
      }

      Section {
        LabeledContent {
          Picker("Item Size", selection: $appSettings.sidebarItemSize) {
            ForEach(SidebarItemSize.allCases) { size in
              Text(size.title).tag(size)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .fixedSize()
        } label: {
          SettingsRowLabel("Item Size")
        }
      } header: {
        SettingsSectionHeader("Sidebar")
      }

      Section {
        LabeledContent {
          Picker("Message Style", selection: $appSettings.messageRenderStyle) {
            ForEach(MessageRenderStyle.allCases, id: \.self) { style in
              Text(style.title).tag(style)
            }
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .frame(width: 220, alignment: .trailing)
        } label: {
          SettingsRowLabel(
            "Message Style",
            description: "Choose how messages are arranged in newly opened chats."
          )
        }
      } header: {
        SettingsSectionHeader("Messages")
      }

      Section {
        LabeledContent {
          UnreadBadgeStylePicker(selection: $appSettings.unreadBadgeStyle)
        } label: {
          SettingsRowLabel("Unread Badge Style")
        }
      } header: {
        SettingsSectionHeader("Badges")
      }
    }
    .settingsFormStyle()
  }
}

private struct AppearancePicker: View {
  @Binding var selection: AppAppearance

  var body: some View {
    HStack(spacing: 12) {
      ForEach(AppAppearance.pickerOrder) { appearance in
        AppearanceOption(
          appearance: appearance,
          isSelected: selection == appearance
        ) {
          selection = appearance
        }
      }
    }
  }
}

private struct AppearanceOption: View {
  let appearance: AppAppearance
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 5) {
        AppearanceThumbnail(appearance: appearance)
          .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .strokeBorder(
                isSelected ? Color.accentColor : Color.clear,
                lineWidth: 3
              )
          }

        Text(appearance.title)
          .font(.caption)
          .fontWeight(isSelected ? .semibold : .regular)
          .foregroundStyle(isSelected ? Color.primary : Color.secondary)
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(appearance.title)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

private struct AppearanceThumbnail: View {
  let appearance: AppAppearance

  var body: some View {
    ZStack {
      AppearanceWindowPreview(palette: .light)

      if appearance == .dark || appearance == .system {
        AppearanceWindowPreview(palette: .dark)
          .mask(alignment: .trailing) {
            Rectangle()
              .frame(width: appearance == .system ? 42 : 84)
          }
      }
    }
    .frame(width: 84, height: 54)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color.black.opacity(0.14), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
  }
}

private struct AppearanceWindowPreview: View {
  let palette: AppearancePreviewPalette

  var body: some View {
    ZStack(alignment: .topLeading) {
      palette.contentBackground

      HStack(spacing: 0) {
        palette.sidebarBackground
          .frame(width: 28)

        VStack(alignment: .leading, spacing: 4) {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(palette.accent)
            .frame(width: 38, height: 7)

          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(palette.secondaryContent)
            .frame(width: 46, height: 5)
        }
        .padding(.top, 22)
        .padding(.leading, 7)
      }

      Rectangle()
        .fill(palette.titlebarBackground)
        .frame(height: 15)

      HStack(spacing: 3) {
        Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
        Circle().fill(Color(red: 1, green: 0.75, blue: 0.10))
        Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.35))
      }
      .frame(width: 18, height: 4)
      .padding(.leading, 5)
      .padding(.top, 5)

      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(palette.accent)
        .frame(width: 20, height: 6)
        .padding(.leading, 4)
        .padding(.top, 23)
    }
    .frame(width: 84, height: 54)
  }
}

private struct AppearancePreviewPalette {
  let titlebarBackground: Color
  let sidebarBackground: Color
  let contentBackground: Color
  let secondaryContent: Color
  let accent: Color

  static let light = Self(
    titlebarBackground: Color(red: 0.86, green: 0.91, blue: 0.97),
    sidebarBackground: Color(red: 0.90, green: 0.92, blue: 0.94),
    contentBackground: .white,
    secondaryContent: Color.black.opacity(0.13),
    accent: Color(red: 0.05, green: 0.45, blue: 0.96)
  )

  static let dark = Self(
    titlebarBackground: Color(red: 0.10, green: 0.17, blue: 0.32),
    sidebarBackground: Color(red: 0.12, green: 0.13, blue: 0.16),
    contentBackground: Color(red: 0.08, green: 0.09, blue: 0.11),
    secondaryContent: Color.white.opacity(0.18),
    accent: Color(red: 0.08, green: 0.42, blue: 0.96)
  )
}

private struct UnreadBadgeStylePicker: View {
  @Binding var selection: UnreadBadgeStyle

  var body: some View {
    HStack(spacing: 8) {
      ForEach(UnreadBadgeStyle.allCases) { style in
        UnreadBadgeStyleOption(
          style: style,
          isSelected: selection == style
        ) {
          selection = style
        }
      }
    }
  }
}

private struct UnreadBadgeStyleOption: View {
  let style: UnreadBadgeStyle
  let isSelected: Bool
  let action: () -> Void

  private var title: LocalizedStringResource {
    switch style {
    case .dot:
      "Dot"
    case .numbered:
      "Numbered"
    }
  }

  var body: some View {
    Button(action: action) {
      VStack(spacing: 5) {
        HStack(spacing: 7) {
          if style == .dot {
            badge
          }

          Circle()
            .fill(Color.secondary.opacity(0.22))
            .frame(width: 22, height: 22)
            .overlay {
              Image(systemName: "person.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

          VStack(alignment: .leading, spacing: 3) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
              .fill(Color.primary.opacity(0.48))
              .frame(width: 31, height: 5)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
              .fill(Color.secondary.opacity(0.22))
              .frame(width: 40, height: 4)
          }

          Spacer(minLength: 0)

          if style == .numbered {
            badge
          }
        }
        .padding(.horizontal, 12)
        .frame(width: 122, height: 38)
        .background(Color.primary.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(
              isSelected ? Color.accentColor : Color.clear,
              lineWidth: 2
            )
        }

        Text(title)
          .font(.caption)
          .fontWeight(isSelected ? .semibold : .regular)
          .foregroundStyle(isSelected ? Color.primary : Color.secondary)
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(title))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var badge: some View {
    UnreadBadge(
      unreadCount: 3,
      prominent: true,
      style: style,
      dotSize: 7
    )
  }
}

#Preview {
  AppearanceSettingsDetailView()
}
