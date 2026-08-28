import Foundation
import InlineMacUI
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
  let showsArchive: Bool
  @Binding var itemSize: SidebarItemSize
  @Binding var sortMode: SidebarSortMode
  @Binding var cleanupInterval: SidebarCleanupInterval
  @Binding var sidebarMode: SidebarMode

  let onToggleArchive: () -> Void
  let onSearch: () -> Void
  let onCreateSpace: () -> Void
  let onNewFolder: (() -> Void)?
  let onNewThread: () -> Void
  let onInvite: () -> Void
  let onOpenDocs: () -> Void
  let onOpenTownHall: () -> Void
  let onDMFounder: () -> Void
  let onCheckForUpdates: (() -> Void)?
  let onOpenWhatsNew: () -> Void
  let onOpenStatus: () -> Void

  @State private var isNotificationHovering = false

  private var iconTint: Color {
    Color(nsColor: .tertiaryLabelColor)
  }

  var body: some View {
    HStack(spacing: 0) {
      if showsArchive {
        slot {
          SidebarFooterButton(
            symbolName: isArchiveActive ? "archivebox.fill" : "archivebox",
            accessibilityLabel: "Archive",
            tint: iconTint,
            action: onToggleArchive
          )
        }
      }

      slot {
        SidebarFooterButton(
          symbolName: "magnifyingglass",
          accessibilityLabel: "Search",
          tint: iconTint,
          shortcut: .command("K"),
          action: onSearch
        )
      }

      slot {
        SidebarFooterMenu(
          symbolName: "questionmark",
          accessibilityLabel: "Help",
          tint: iconTint
        ) {
          Button(action: onOpenDocs) {
            Label("Docs", systemImage: "book.closed")
            Text("Get started, set up agents, and develop")
          }

          Button(action: onOpenTownHall) {
            Label("Join Town Hall", systemImage: "person.3")
            Text("Inline’s early users community")
          }

          Button(action: onDMFounder) {
            Label("DM the Founder", systemImage: "bubble.left")
            Text("Start a DM with @mo")
          }

          Divider()

          if let onCheckForUpdates {
            Button(action: onCheckForUpdates) {
              Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
            }
          }

          Button(action: onOpenWhatsNew) {
            Label("What’s New", systemImage: "sparkles")
          }

          Button(action: onOpenStatus) {
            Label("Status", systemImage: "antenna.radiowaves.left.and.right")
          }

          if let versionSummary = SidebarHelpVersionSummary.current {
            Divider()

            Button(versionSummary, action: {})
              .disabled(true)
          }
        }
      }

      slot {
        SidebarViewOptionsMenuButton(
          itemSize: $itemSize,
          sortMode: $sortMode,
          cleanupInterval: $cleanupInterval,
          sidebarMode: $sidebarMode
        )
        .frame(
          width: SidebarFooterMetrics.buttonSize,
          height: SidebarFooterMetrics.buttonSize
        )
      }

      slot {
        NotificationSettingsButton(style: .sidebarFooter)
          .buttonStyle(SidebarFooterButtonStyle(isHovering: isNotificationHovering))
          .accessibilityLabel("Notifications")
          .inlineTooltip(
            "Notifications",
            placement: .above
          )
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

          Button(action: { onNewFolder?() }, label: {
            Label("New Folder", systemImage: "folder.badge.plus")
            if onNewFolder == nil {
              Text("Available from Home")
            }
          })
          .disabled(onNewFolder == nil)

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

private enum SidebarHelpVersionSummary {
  private static let version = bundleValue(for: "CFBundleShortVersionString")
  private static let buildNumber = bundleValue(for: "CFBundleVersion")
  private static let buildDate = Bundle.main.executableURL.flatMap { executableURL in
    try? executableURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
  }

  static var current: String? {
    guard let version, let buildNumber, let buildDate else { return nil }

    return [
      "Version \(version)",
      "Build \(buildNumber)",
      ageDescription(since: buildDate, now: .now),
    ].joined(separator: " • ")
  }

  private static func bundleValue(for key: String) -> String? {
    guard
      let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
      !value.isEmpty
    else { return nil }

    return value
  }

  private static func ageDescription(since date: Date, now: Date) -> String {
    let totalHours = max(0, Int(now.timeIntervalSince(date) / 3_600))
    let days = totalHours / 24
    let hours = totalHours % 24

    if days == 0 {
      return "\(hours) \(hours == 1 ? "hour" : "hours") ago"
    }

    let dayUnit = days == 1 ? "day" : "days"
    let hourUnit = hours == 1 ? "hour" : "hours"
    return "\(days) \(dayUnit), \(hours) \(hourUnit) ago"
  }
}

private struct SidebarFooterButton: View {
  let symbolName: String
  let accessibilityLabel: String
  let tint: Color
  var shortcut: InlineTooltipShortcut?
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      SidebarFooterIcon(symbolName: symbolName, tint: tint)
    }
    .buttonStyle(SidebarFooterButtonStyle(isHovering: isHovering))
    .accessibilityLabel(accessibilityLabel)
    .inlineTooltip(
      verbatim: accessibilityLabel,
      shortcut: shortcut,
      placement: .above
    )
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
    .labelStyle(.titleAndIcon)
    .menuStyle(.button)
    .buttonStyle(SidebarFooterButtonStyle(isHovering: isHovering))
    .menuIndicator(.hidden)
    .accessibilityLabel(accessibilityLabel)
    .inlineTooltip(
      verbatim: accessibilityLabel,
      placement: .above
    )
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
