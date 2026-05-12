import SwiftUI

enum SidebarFooterMetrics {
  static let buttonSize: CGFloat = 26
  static let cornerRadius: CGFloat = 8
  static let verticalPadding: CGFloat = 6
  static let horizontalPadding: CGFloat = 12
  static let iconPointSize: CGFloat = 13
  static let iconFont: Font = .system(size: iconPointSize, weight: .medium)

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

struct SidebarFooterView: View {
  let isArchiveActive: Bool
  @Binding var showPreview: Bool

  let onToggleArchive: () -> Void
  let onSearch: () -> Void
  let onCreateSpace: () -> Void
  let onNewThread: () -> Void
  let onInvite: () -> Void

  @State private var isNotificationHovering = false

  private var iconTint: Color {
    Color(nsColor: .tertiaryLabelColor)
  }

  var body: some View {
    HStack(spacing: 0) {
      slot {
        SidebarFooterButton(
          symbolName: isArchiveActive ? "archivebox.fill" : "archivebox",
          accessibilityLabel: "Archive",
          tint: iconTint,
          action: onToggleArchive
        )
      }

      slot {
        SidebarFooterButton(
          symbolName: "magnifyingglass",
          accessibilityLabel: "Search",
          tint: iconTint,
          action: onSearch
        )
      }

      slot {
        SidebarFooterMenu(
          symbolName: "line.3.horizontal.decrease",
          accessibilityLabel: "View options",
          tint: iconTint
        ) {
          Button {
            showPreview.toggle()
          } label: {
            Text(showPreview ? "Hide Message Previews" : "Show Message Previews")
          }
        }
      }

      slot {
        NotificationSettingsButton(style: .sidebarFooter)
          .buttonStyle(SidebarFooterButtonStyle(isHovering: isNotificationHovering))
          .accessibilityLabel("Notifications")
          .help("Notifications")
          .onHover { isNotificationHovering = $0 }
      }

      slot {
        SidebarFooterMenu(
          symbolName: "plus",
          accessibilityLabel: "New",
          tint: iconTint
        ) {
          Button(action: onCreateSpace) {
            Label("Create Space", systemImage: "square.grid.2x2")
          }

          Button(action: onNewThread) {
            Label("New Thread", systemImage: "square.and.pencil")
          }

          Button(action: onInvite) {
            Label("Invite", systemImage: "person.badge.plus")
          }
        }
      }
    }
    .padding(.horizontal, SidebarFooterMetrics.horizontalPadding)
    .padding(.vertical, SidebarFooterMetrics.verticalPadding)
    .frame(maxWidth: .infinity, alignment: .center)
  }

  @ViewBuilder
  private func slot<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
      .frame(maxWidth: .infinity, alignment: .center)
  }
}

private struct SidebarFooterButton: View {
  let symbolName: String
  let accessibilityLabel: String
  let tint: Color
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      SidebarFooterIcon(symbolName: symbolName, tint: tint)
    }
    .buttonStyle(SidebarFooterButtonStyle(isHovering: isHovering))
    .accessibilityLabel(accessibilityLabel)
    .help(accessibilityLabel)
    .onHover { isHovering = $0 }
  }
}

private struct SidebarFooterMenu<MenuContent: View>: View {
  let symbolName: String
  let accessibilityLabel: String
  let tint: Color
  @ViewBuilder let content: () -> MenuContent

  @State private var isHovering = false

  var body: some View {
    Menu(content: content) {
      SidebarFooterIcon(symbolName: symbolName, tint: tint)
    }
    .menuStyle(.button)
    .buttonStyle(SidebarFooterButtonStyle(isHovering: isHovering))
    .menuIndicator(.hidden)
    .accessibilityLabel(accessibilityLabel)
    .help(accessibilityLabel)
    .onHover { isHovering = $0 }
  }
}

private struct SidebarFooterButtonStyle: ButtonStyle {
  @Environment(\.colorScheme) private var colorScheme

  let isHovering: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        RoundedRectangle(
          cornerRadius: SidebarFooterMetrics.cornerRadius,
          style: .continuous
        )
        .fill(
          SidebarFooterMetrics.backgroundColor(
            colorScheme: colorScheme,
            isHovering: isHovering,
            isPressed: configuration.isPressed
          )
        )
      )
  }
}

private struct SidebarFooterIcon: View {
  let symbolName: String
  let tint: Color

  var body: some View {
    Image(systemName: symbolName)
      .font(SidebarFooterMetrics.iconFont)
      .foregroundStyle(tint)
      .frame(
        width: SidebarFooterMetrics.buttonSize,
        height: SidebarFooterMetrics.buttonSize,
        alignment: .center
      )
      .contentShape(
        RoundedRectangle(
          cornerRadius: SidebarFooterMetrics.cornerRadius,
          style: .continuous
        )
      )
  }
}
