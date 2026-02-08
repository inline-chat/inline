import SwiftUI

enum MainSidebarFooterMetrics {
  static let buttonSize: CGFloat = 26
  static let cornerRadius: CGFloat = 8
  static let verticalPadding: CGFloat = 6

  static let iconPointSize: CGFloat = 13
  static let iconWeight: Font.Weight = .medium

  static let height: CGFloat = buttonSize + (verticalPadding * 2)
  static let iconFont: Font = .system(size: iconPointSize, weight: iconWeight)

  static func backgroundColor(
    colorScheme: ColorScheme,
    isHovering: Bool,
    isPressed: Bool
  ) -> Color {
    if isPressed {
      return colorScheme == .dark
        ? Color.white.opacity(0.24)
        : Color.black.opacity(0.10)
    }

    if isHovering {
      return colorScheme == .dark
        ? Color.white.opacity(0.18)
        : Color.black.opacity(0.06)
    }

    return .clear
  }
}

struct MainSidebarFooterView: View {
  let isArchiveActive: Bool
  let isPreviewEnabled: Bool
  let horizontalPadding: CGFloat

  let onToggleArchive: () -> Void
  let onSearch: () -> Void
  let onNewSpace: () -> Void
  let onInvite: () -> Void
  let onNewThread: () -> Void
  let onSetCompact: () -> Void
  let onSetPreview: () -> Void

  private var iconTint: Color {
    Color(nsColor: .tertiaryLabelColor)
  }

  var body: some View {
    HStack(spacing: 0) {
      slot {
        FooterIconButton(
          symbolName: isArchiveActive ? "archivebox.fill" : "archivebox",
          accessibilityLabel: "Archive",
          tint: iconTint,
          action: onToggleArchive
        )
      }

      slot {
        FooterIconButton(
          symbolName: "magnifyingglass",
          accessibilityLabel: "Search",
          tint: iconTint,
          action: onSearch
        )
      }

      slot {
        FooterIconMenu(
          symbolName: "plus",
          accessibilityLabel: "New",
          tint: iconTint
        ) {
          Button(action: onNewSpace) {
            Label("New Space", systemImage: "plus")
          }
          Button(action: onInvite) {
            Label("Invite", systemImage: "person.badge.plus")
          }
          Button(action: onNewThread) {
            Label("New Thread", systemImage: "bubble.left.and.bubble.right")
          }
        }
      }

      slot {
        FooterIconMenu(
          symbolName: "line.3.horizontal.decrease",
          accessibilityLabel: "View options",
          tint: iconTint
        ) {
          Button(action: onSetCompact) {
            menuRow(
              title: "Compact",
              systemImage: "rectangle.compress.vertical",
              isSelected: !isPreviewEnabled
            )
          }

          Button(action: onSetPreview) {
            menuRow(
              title: "Show previews",
              systemImage: "rectangle.expand.vertical",
              isSelected: isPreviewEnabled
            )
          }
        }
      }

      slot {
        FooterDecoratedControl(accessibilityLabel: "Notifications") {
          NotificationSettingsButton(style: .sidebarFooter)
        }
      }
    }
    .padding(.horizontal, horizontalPadding)
    .padding(.vertical, MainSidebarFooterMetrics.verticalPadding)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }

  @ViewBuilder
  private func slot<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
      .frame(maxWidth: .infinity, alignment: .center)
  }

  private func menuRow(title: String, systemImage: String, isSelected: Bool) -> some View {
    HStack(spacing: 8) {
      Group {
        if isSelected {
          Image(systemName: "checkmark")
        } else {
          Color.clear
        }
      }
      .frame(width: 12, height: 12, alignment: .center)
      .accessibilityHidden(true)
      Label(title, systemImage: systemImage)
    }
  }
}

private struct FooterIconButton: View {
  let symbolName: String
  let accessibilityLabel: String
  let tint: Color
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: symbolName)
        .font(MainSidebarFooterMetrics.iconFont)
        .foregroundStyle(tint)
        .frame(
          width: MainSidebarFooterMetrics.buttonSize,
          height: MainSidebarFooterMetrics.buttonSize,
          alignment: .center
        )
        .contentShape(
          RoundedRectangle(
            cornerRadius: MainSidebarFooterMetrics.cornerRadius,
            style: .continuous
          )
        )
    }
    .buttonStyle(SidebarFooterButtonStyle(isHovering: isHovering))
    .accessibilityLabel(accessibilityLabel)
    .help(accessibilityLabel)
    .onHover { isHovering = $0 }
  }
}

private struct FooterIconMenu<MenuContent: View>: View {
  let symbolName: String
  let accessibilityLabel: String
  let tint: Color
  @ViewBuilder let content: () -> MenuContent

  @State private var isHovering = false

  var body: some View {
    Menu(content: content) {
      Image(systemName: symbolName)
        .font(MainSidebarFooterMetrics.iconFont)
        .foregroundStyle(tint)
        .frame(
          width: MainSidebarFooterMetrics.buttonSize,
          height: MainSidebarFooterMetrics.buttonSize,
          alignment: .center
        )
        .contentShape(
          RoundedRectangle(
            cornerRadius: MainSidebarFooterMetrics.cornerRadius,
            style: .continuous
          )
        )
    }
    .menuStyle(.button)
    .buttonStyle(SidebarFooterButtonStyle(isHovering: isHovering))
    .menuIndicator(.hidden)
    .accessibilityLabel(accessibilityLabel)
    .help(accessibilityLabel)
    .onHover { isHovering = $0 }
  }
}

private struct FooterDecoratedControl<Content: View>: View {
  @Environment(\.colorScheme) private var colorScheme

  let accessibilityLabel: String
  @ViewBuilder let content: () -> Content

  @State private var isHovering = false
  @GestureState private var isPressed = false

  var body: some View {
    content()
      .frame(
        width: MainSidebarFooterMetrics.buttonSize,
        height: MainSidebarFooterMetrics.buttonSize,
        alignment: .center
      )
      .background(
        RoundedRectangle(
          cornerRadius: MainSidebarFooterMetrics.cornerRadius,
          style: .continuous
        )
        .fill(
          MainSidebarFooterMetrics.backgroundColor(
            colorScheme: colorScheme,
            isHovering: isHovering,
            isPressed: isPressed
          )
        )
      )
      .contentShape(
        RoundedRectangle(
          cornerRadius: MainSidebarFooterMetrics.cornerRadius,
          style: .continuous
        )
      )
      .accessibilityLabel(accessibilityLabel)
      .help(accessibilityLabel)
      .onHover { isHovering = $0 }
      .simultaneousGesture(
        DragGesture(minimumDistance: 0)
          .updating($isPressed) { _, state, _ in
            state = true
          }
      )
  }
}

private struct SidebarFooterButtonStyle: ButtonStyle {
  @Environment(\.colorScheme) private var colorScheme

  let isHovering: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        RoundedRectangle(
          cornerRadius: MainSidebarFooterMetrics.cornerRadius,
          style: .continuous
        )
        .fill(
          MainSidebarFooterMetrics.backgroundColor(
            colorScheme: colorScheme,
            isHovering: isHovering,
            isPressed: configuration.isPressed
          )
        )
      )
  }
}
