import InlineKit
import SwiftUI

/// A button that opens the notification settings sheet for iOS.
struct NotificationSettingsButton: View {
  @EnvironmentObject private var notificationSettings: NotificationSettingsManager

  private let iconColor: Color
  private let iconFont: Font?
  @State private var presented = false

  init(iconColor: Color = .primary, iconFont: Font? = nil) {
    self.iconColor = iconColor
    self.iconFont = iconFont
  }

  var body: some View {
    button
      .sheet(isPresented: $presented) {
        NotificationSettingsPopoverContent(onSelection: close)
          .presentationDragIndicator(.visible)
          .presentationDetents([.medium, .large])
          .presentationContentInteraction(.scrolls)
      }
  }

  @ViewBuilder
  private var button: some View {
    Button {
      presented.toggle()
    } label: {
      Group {
        if let iconFont {
          Image(systemName: notificationIcon)
            .font(iconFont)
        } else {
          Image(systemName: notificationIcon)
        }
      }
      .foregroundStyle(iconColor)
      .contentShape(Rectangle())
      .transition(.asymmetric(
        insertion: .scale.combined(with: .opacity),
        removal: .scale.combined(with: .opacity)
      ))
      .animation(.easeOut(duration: 0.2), value: notificationIcon)
    }
  }

  var notificationIcon: String {
    notificationSettings.mode.systemImage
  }

  private func close() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
      // Delay closing to allow animations to finish
      presented = false
    }
  }
}

extension NotificationMode {
  var systemImage: String {
    switch self {
    case .all: "bell"
    case .none: "bell.slash"
    case .mentions, .importantOnly, .onlyMentions: "at"
    }
  }

  var valueTitle: LocalizedStringResource {
    switch self {
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

struct NotificationSettingsPopoverContent: View {
  let onSelection: () -> Void

  var body: some View {
    NavigationStack {
      NotificationSettingsList(onSelection: onSelection)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }
  }
}

private struct NotificationSettingsList: View {
  @EnvironmentObject private var notificationSettings: NotificationSettingsManager

  let onSelection: () -> Void

  var body: some View {
    List {
      Section("Control how you receive notifications") {
        NotificationSettingsItem(
          systemImage: "bell.fill",
          title: "All",
          description: "Receive all notifications",
          selected: notificationSettings.mode == .all,
          value: NotificationMode.all,
          onChange: {
            notificationSettings.mode = $0
            notificationSettings.disableDmNotifications = false
            close()
          }
        )

        NotificationSettingsItem(
          systemImage: "at",
          title: "Any message to you",
          description: "Mentions, direct messages, and replies to you",
          selected: notificationSettings.mode == .mentions || notificationSettings.mode == .importantOnly,
          value: NotificationMode.mentions,
          onChange: {
            notificationSettings.mode = $0
            notificationSettings.disableDmNotifications = false
            close()
          }
        )

        NotificationSettingsItem(
          systemImage: "at",
          title: "Only mentions",
          description: "Mentions and nudges still notify you",
          selected: notificationSettings.mode == .onlyMentions,
          value: NotificationMode.onlyMentions,
          onChange: { mode in
            notificationSettings.mode = mode
            notificationSettings.disableDmNotifications = true
            close()
          }
        )

        NotificationSettingsItem(
          systemImage: "bell.slash.fill",
          title: "None",
          description: "No notifications",
          selected: notificationSettings.mode == .none,
          value: NotificationMode.none,
          onChange: {
            notificationSettings.mode = $0
            notificationSettings.disableDmNotifications = false
            close()
          }
        )
      }
    }
    .listStyle(.insetGrouped)
  }

  private func close() {
    onSelection()
  }
}

private struct NotificationSettingsItem<Value: Equatable>: View {
  var systemImage: String
  var title: String
  var description: String
  var selected: Bool
  var value: Value
  var onChange: (Value) -> Void
  var iconFontSize: CGFloat?
  let theme = ThemeManager.shared.selected

  var body: some View {
    Button {
      onChange(value)
    } label: {
      HStack(spacing: 12) {
        Circle()
          .fill(selected ? Color(theme.accent) : Color(.systemGray5))
          .frame(width: 36, height: 36)
          .overlay {
            Image(systemName: systemImage)
              .font(.system(size: iconFontSize ?? 18, weight: .medium))
              .foregroundStyle(selected ? Color.white : Color(.systemGray))
          }

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.body)
            .fontWeight(.medium)

          Text(description)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .layoutPriority(1)

        Spacer(minLength: 8)

        Image(systemName: "checkmark")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(Color(theme.accent))
          .opacity(selected ? 1 : 0)
          .frame(width: 18, alignment: .trailing)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .animation(.easeOut(duration: 0.08), value: selected)
  }
}
