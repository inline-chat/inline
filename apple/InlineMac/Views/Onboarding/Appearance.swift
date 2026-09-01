import AppKit
import InlineKit
import InlineMacUI
import MacTheme
import SwiftUI

struct OnboardingAppearance: View {
  @EnvironmentObject private var onboarding: OnboardingViewModel
  @Environment(OnboardingProfileSetupModel.self) private var profile

  @State private var selectedStyle = AppSettings.shared.messageRenderStyle

  var body: some View {
    let previewIdentity = profile.messagePreviewIdentity

    VStack(spacing: 0) {
      Spacer()

      OnboardingAppearanceHeader()

      OnboardingMessageStylePreview(
        style: selectedStyle,
        identity: previewIdentity
      )
      .id(selectedStyle)
      .transition(.opacity)
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .accessibilityHidden(true)
      .padding(.top, 20)

      HStack(spacing: 4) {
        OnboardingAppearanceStyleChoice(
          style: .minimal,
          isSelected: selectedStyle == .minimal,
          action: { selectStyle(.minimal) }
        )

        OnboardingAppearanceStyleChoice(
          style: .bubble,
          isSelected: selectedStyle == .bubble,
          action: { selectStyle(.bubble) }
        )
      }
      .padding(.top, 10)

      InlineButton {
        AppSettings.shared.messageRenderStyle = selectedStyle
        onboarding.finishSetup()
      } label: {
        Text("Continue")
          .padding(.horizontal, 16)
      }
      .padding(.top, 10)

      Spacer()
    }
    .padding(32)
    .frame(minHeight: 520)
  }

  private func selectStyle(_ style: MessageRenderStyle) {
    withAnimation(.easeInOut(duration: 0.18)) {
      selectedStyle = style
    }
  }
}

private struct OnboardingAppearanceHeader: View {
  var body: some View {
    Text("Pick your message style")
      .font(.title2.weight(.semibold))
      .foregroundStyle(.primary)
  }
}

private struct OnboardingAppearanceStyleChoice: View {
  private static let controlSize = CGSize(width: 92, height: 34)
  private static let controlCornerRadius: CGFloat = 10

  @State private var isHovered = false

  let style: MessageRenderStyle
  let isSelected: Bool
  let action: () -> Void

  private var title: LocalizedStringResource {
    switch style {
    case .minimal: "Minimal"
    case .bubble: "Bubble"
    }
  }

  private var accentColor: Color {
    Color(nsColor: .controlAccentColor)
  }

  var body: some View {
    let controlShape = RoundedRectangle(
      cornerRadius: Self.controlCornerRadius,
      style: .continuous
    )

    Button(action: action) {
      HStack(spacing: 7) {
        ZStack {
          Circle()
            .fill(isSelected ? accentColor : .clear)

          Circle()
            .strokeBorder(
              isSelected ? accentColor : Color.secondary.opacity(0.55),
              lineWidth: 1
            )

          if isSelected {
            Image(systemName: "checkmark")
              .font(.system(size: 9, weight: .bold))
              .foregroundStyle(.white)
              .transition(.scale.combined(with: .opacity))
          }
        }
        .frame(width: 16, height: 16)
        .animation(.easeInOut(duration: 0.16), value: isSelected)

        Text(title)
          .font(.body)
          .foregroundStyle(.primary)
      }
      .frame(width: Self.controlSize.width, height: Self.controlSize.height)
      .background(Color.gray.opacity(isHovered ? 0.14 : 0), in: controlShape)
      .contentShape(controlShape)
      .animation(.easeOut(duration: 0.14), value: isHovered)
    }
    .buttonStyle(OnboardingAppearanceButtonStyle())
    .onHover { isHovered = $0 }
    .accessibilityLabel(Text(title))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

// Preserved as a dormant reference to the superseded two-preview layout.
private struct LegacyOnboardingAppearanceOption: View {
  let style: MessageRenderStyle
  let identity: OnboardingPreviewIdentity
  let isSelected: Bool
  let action: () -> Void

  private var title: LocalizedStringResource {
    switch style {
    case .minimal: "Minimal"
    case .bubble: "Bubble"
    }
  }

  private var accentColor: Color {
    Color(nsColor: .controlAccentColor)
  }

  var body: some View {
    Button(action: action) {
      VStack(spacing: 12) {
        OnboardingMessageStylePreview(
          style: style,
          identity: identity
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(
              isSelected ? accentColor : .primary.opacity(0.12),
              lineWidth: isSelected ? 2 : 1
            )
        }
        .accessibilityHidden(true)

        HStack(spacing: 7) {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isSelected ? accentColor : .secondary)

          Text(title)
            .font(.body)
            .foregroundStyle(.primary)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(OnboardingAppearanceButtonStyle())
    .accessibilityLabel(Text(title))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

private struct OnboardingAppearanceButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
  }
}

// Preserved as a dormant reference while the two option previews are designed.
private struct LegacyOnboardingAppearance: View {
  @EnvironmentObject private var onboarding: OnboardingViewModel
  @Environment(OnboardingProfileSetupModel.self) private var profile
  @Environment(\.colorScheme) private var colorScheme

  @State private var messageStyle = AppSettings.shared.messageRenderStyle
  @State private var sidebarSize = AppSettings.shared.sidebarItemSize
  @State private var unreadBadgeStyle = AppSettings.shared.unreadBadgeStyle
  @State private var appTheme = AppSettings.shared.appTheme

  var body: some View {
    OnboardingStepLayout(
      title: "Make Inline feel like yours"
    ) {
      VStack(spacing: 14) {
        HStack(alignment: .center, spacing: 14) {
          OnboardingAppWindowPreview(
            messageStyle: messageStyle,
            sidebarSize: sidebarSize,
            unreadBadgeStyle: unreadBadgeStyle,
            appTheme: appTheme,
            variant: colorScheme == .dark ? .dark : .light
          )

          OnboardingAppearanceControls(
            messageStyle: $messageStyle,
            sidebarSize: $sidebarSize,
            unreadBadgeStyle: $unreadBadgeStyle,
            appTheme: $appTheme
          )
        }

        HStack(spacing: 12) {
          Button("Skip") { finish(applyChoices: false) }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)

          InlineButton { finish(applyChoices: true) } label: {
            Text("Finish").padding(.horizontal, 16)
          }
        }
        .padding(.top, 2)
      }
    }
  }

  private func finish(applyChoices: Bool) {
    if applyChoices {
      AppSettings.shared.messageRenderStyle = messageStyle
      AppSettings.shared.sidebarItemSize = sidebarSize
      AppSettings.shared.unreadBadgeStyle = unreadBadgeStyle
      AppSettings.shared.appTheme = appTheme
    }

    onboarding.finishSetup()
  }
}

private struct OnboardingAppearanceControls: View {
  @Binding var messageStyle: MessageRenderStyle
  @Binding var sidebarSize: SidebarItemSize
  @Binding var unreadBadgeStyle: UnreadBadgeStyle
  @Binding var appTheme: AppThemePreset

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      OnboardingChoiceSection(title: "Messages") {
        HStack(spacing: 6) {
          OnboardingTextChoiceButton(
            title: "Bubble",
            isSelected: messageStyle == .bubble,
            action: { messageStyle = .bubble }
          )
          OnboardingTextChoiceButton(
            title: "Minimal",
            isSelected: messageStyle == .minimal,
            action: { messageStyle = .minimal }
          )
        }
      }

      OnboardingChoiceSection(title: "Sidebar") {
        HStack(spacing: 6) {
          OnboardingTextChoiceButton(
            title: "Compact",
            isSelected: sidebarSize == .compact,
            action: { sidebarSize = .compact }
          )
          OnboardingTextChoiceButton(
            title: "Standard",
            isSelected: sidebarSize == .standard,
            action: { sidebarSize = .standard }
          )
        }
      }

      OnboardingChoiceSection(title: "Unread badge") {
        HStack(spacing: 6) {
          OnboardingTextChoiceButton(
            title: "Dot",
            isSelected: unreadBadgeStyle == .dot,
            action: { unreadBadgeStyle = .dot }
          )
          OnboardingTextChoiceButton(
            title: "Number",
            isSelected: unreadBadgeStyle == .numbered,
            action: { unreadBadgeStyle = .numbered }
          )
        }
      }

      OnboardingChoiceSection(title: "Theme") {
        Menu {
          ForEach(AppThemePreset.allCases) { theme in
            Button {
              appTheme = theme
            } label: {
              if appTheme == theme {
                Label(theme.title, systemImage: "checkmark")
              } else {
                Text(theme.title)
              }
            }
          }
        } label: {
          HStack(spacing: 6) {
            Text(appTheme.title)
              .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.down")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          .foregroundStyle(.primary)
          .padding(.horizontal, 8)
          .frame(height: 24)
          .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .stroke(.primary.opacity(0.08), lineWidth: 1)
          }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
      }
    }
    .frame(width: 156)
  }
}

private struct OnboardingChoiceSection<Content: View>: View {
  let title: LocalizedStringKey
  let content: Content

  init(title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption2)
        .foregroundStyle(.secondary)
      content
    }
  }
}

private struct OnboardingTextChoiceButton: View {
  let title: LocalizedStringResource
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.caption2)
        .fontWeight(isSelected ? .semibold : .regular)
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .background(
          isSelected ? Color.accentColor.opacity(0.13) : .primary.opacity(0.045),
          in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(
              isSelected ? Color.accentColor.opacity(0.65) : .primary.opacity(0.08),
              lineWidth: 1
            )
        }
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

private struct OnboardingAppWindowPreview: View {
  let messageStyle: MessageRenderStyle
  let sidebarSize: SidebarItemSize
  let unreadBadgeStyle: UnreadBadgeStyle
  let appTheme: AppThemePreset
  let variant: ThemeAppearanceVariant

  var body: some View {
    let palette = Theme.resolvedPalette(preset: appTheme, variant: variant)
    let accent = Color(nsColor: palette.accent.nsColor)
    let prominent = Color(nsColor: palette.prominent.nsColor)
    let bubble = Color(nsColor: palette.bubble.nsColor)
    let windowBackground = Color(nsColor: palette.background.nsColor)

    HStack(spacing: 0) {
      OnboardingSidebarSnapshot(
        size: sidebarSize,
        unreadBadgeStyle: unreadBadgeStyle,
        accent: accent,
        prominent: prominent
      )
      .frame(width: 88)
      .background(accent.opacity(variant == .dark ? 0.08 : 0.05))

      OnboardingMessagesSnapshot(
        style: messageStyle,
        bubble: bubble,
        prominent: prominent
      )
      .background(windowBackground)
    }
    .frame(width: 330, height: 184)
    .background(windowBackground)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(.primary.opacity(0.1), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.07), radius: 5, y: 2)
  }
}

private struct OnboardingSidebarSnapshot: View {
  let size: SidebarItemSize
  let unreadBadgeStyle: UnreadBadgeStyle
  let accent: Color
  let prominent: Color

  var body: some View {
    VStack(spacing: size == .compact ? 2 : 4) {
      OnboardingSidebarRow(
        selected: true,
        size: size,
        unreadBadgeStyle: unreadBadgeStyle,
        accent: accent,
        prominent: prominent
      )
      OnboardingSidebarRow(
        selected: false,
        size: size,
        unreadBadgeStyle: unreadBadgeStyle,
        accent: accent,
        prominent: prominent
      )
      OnboardingSidebarRow(
        selected: false,
        size: size,
        unreadBadgeStyle: unreadBadgeStyle,
        accent: accent,
        prominent: prominent,
        showsUnread: false
      )
      Spacer(minLength: 0)
    }
    .padding(6)
  }
}

private struct OnboardingSidebarRow: View {
  let selected: Bool
  let size: SidebarItemSize
  let unreadBadgeStyle: UnreadBadgeStyle
  let accent: Color
  let prominent: Color
  var showsUnread = true

  var body: some View {
    HStack(spacing: 5) {
      if unreadBadgeStyle == .dot {
        Circle()
          .fill(showsUnread ? prominent : .clear)
          .frame(width: 4, height: 4)
      }

      Circle()
        .fill(.secondary.opacity(0.24))
        .frame(width: size == .compact ? 12 : 16, height: size == .compact ? 12 : 16)

      VStack(alignment: .leading, spacing: 2) {
        RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.42)).frame(width: 30, height: 3)
        if size == .standard {
          RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.2)).frame(width: 39, height: 3)
        }
      }

      Spacer(minLength: 0)

      if unreadBadgeStyle == .numbered, showsUnread {
        Text("3")
          .font(.system(size: 6.5, weight: .bold))
          .foregroundStyle(.white)
          .frame(width: 11, height: 11)
          .background(prominent, in: Circle())
      }
    }
    .padding(.horizontal, 3)
    .frame(height: size == .compact ? 20 : 27)
    .background(selected ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
  }
}

private struct OnboardingMessagesSnapshot: View {
  let style: MessageRenderStyle
  let bubble: Color
  let prominent: Color

  var body: some View {
    VStack(spacing: style == .bubble ? 10 : 8) {
      OnboardingMessageRow(style: style, outgoing: false, bubble: bubble, prominent: prominent)
      OnboardingMessageRow(style: style, outgoing: true, bubble: bubble, prominent: prominent)
      Spacer(minLength: 0)
    }
    .padding(14)
  }
}

private struct OnboardingMessageRow: View {
  let style: MessageRenderStyle
  let outgoing: Bool
  let bubble: Color
  let prominent: Color

  @ViewBuilder
  var body: some View {
    if style == .minimal {
      HStack(alignment: .top, spacing: 6) {
        Circle()
          .fill(prominent.opacity(0.32))
          .frame(width: 14, height: 14)

        OnboardingMessageLines(outgoing: outgoing)
        Spacer(minLength: 0)
      }
    } else {
      HStack(alignment: .bottom, spacing: 6) {
        if outgoing { Spacer(minLength: 24) }

        if outgoing == false {
          Circle()
            .fill(prominent.opacity(0.32))
            .frame(width: 14, height: 14)
        }

        OnboardingMessageLines(outgoing: outgoing)
          .padding(7)
          .background(
            outgoing ? bubble : .primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
          )

        if outgoing == false { Spacer(minLength: 24) }
      }
    }
  }
}

private struct OnboardingMessageLines: View {
  let outgoing: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      RoundedRectangle(cornerRadius: 2)
        .fill(.primary.opacity(0.42))
        .frame(width: 38, height: 3)
      RoundedRectangle(cornerRadius: 2)
        .fill(.secondary.opacity(0.24))
        .frame(width: outgoing ? 65 : 88, height: 3)
      RoundedRectangle(cornerRadius: 2)
        .fill(.secondary.opacity(0.18))
        .frame(width: outgoing ? 48 : 68, height: 3)
    }
  }
}

#Preview {
  OnboardingAppearance()
    .environmentObject(MainWindowViewModel())
    .environmentObject(OnboardingViewModel())
    .environment(OnboardingProfileSetupModel())
    .frame(width: 900, height: 650)
}
