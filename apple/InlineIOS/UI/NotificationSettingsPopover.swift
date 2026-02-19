import InlineKit
import SwiftUI

/// A button that opens the notification settings popover for iOS
struct NotificationSettingsButton: View {
  @EnvironmentObject private var notificationSettings: NotificationSettingsManager

  @State private var presented = false

  var body: some View {
    button
      .sheet(isPresented: $presented) {
        NavigationView {
          popover
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
              ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") {
                  presented = false
                }
              }
            }
      }
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
      Image(systemName: notificationIcon)
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
        .transition(.asymmetric(
          insertion: .scale.combined(with: .opacity),
          removal: .scale.combined(with: .opacity)
        ))
        .animation(.easeOut(duration: 0.2), value: notificationIcon)
    }
  }

  var notificationIcon: String {
    switch notificationSettings.mode {
      case .all: "bell"
      case .none: "bell.slash"
      case .mentions: "at"
      case .importantOnly: "apple.meditate"
      case .onlyMentions: "bubble.left.and.bubble.right"
    }
  }

  @ViewBuilder
  private var popover: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        // Header
        VStack(alignment: .leading, spacing: 4) {
          Text("Control how you receive notifications")
            .font(.subheadline)
            .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16)

        VStack(alignment: .leading, spacing: 8) {
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
            },
          )

          NotificationSettingsItem(
            systemImage: "at",
            title: "Any message to you",
            description: "Mentions, direct messages, and replies to you",
            selected: notificationSettings.mode == .mentions,
            value: NotificationMode.mentions,
            onChange: {
              notificationSettings.mode = $0
              notificationSettings.disableDmNotifications = false
              close()
            },
          )

          NotificationSettingsItem(
            systemImage: "bubble.left.and.bubble.right.fill",
            title: "Only mentions",
            description: "Mentions and nudges still notify you",
            selected: notificationSettings.mode == .onlyMentions,
            value: NotificationMode.onlyMentions,
            onChange: { mode in
              notificationSettings.mode = mode
              notificationSettings.disableDmNotifications = true
              close()
            },
            iconFontSize: 14
          )

          /*
          NotificationSettingsItem(
            systemImage: "apple.meditate",
            title: "Zen",
            description: "Only important messages",
            selected: notificationSettings.mode == .importantOnly,
            value: NotificationMode.importantOnly,
            onChange: {
              notificationSettings.mode = $0
              notificationSettings.disableDmNotifications = false
              close()
            },
          )
          */

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
            },
          )
        }
        .padding(.horizontal, 16)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 20)
    }
    .background(Color(.systemBackground))
  }

  private func close() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
      // Delay closing to allow animations to finish
      presented = false
    }
  }
}

private struct NotificationSettingsItem<Value: Equatable>: View {
  var systemImage: String
  var title: String
  var description: String
  var selected: Bool
  var value: Value
  var onChange: (Value) -> Void
  var customizeAction: (() -> Void)?
  var menuContent: AnyView?
  var iconFontSize: CGFloat? = nil
  let theme = ThemeManager.shared.selected

  var body: some View {
    HStack(spacing: 12) {
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
              .multilineTextAlignment(.leading)
              .fixedSize(horizontal: false, vertical: true)
          }
          .layoutPriority(1)

          Spacer()

          if selected {
            Image(systemName: "checkmark")
              .font(.system(size: 16, weight: .semibold))
              .foregroundStyle(Color(theme.accent))
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if let menuContent {
        Menu {
          menuContent
        } label: {
          Circle()
            .frame(width: 28, height: 28)
            .foregroundStyle(Color(.systemGray5))
            .overlay {
              Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) options")
      } else if let customizeAction {
        Button(action: customizeAction) {
          Circle()
            .frame(width: 28, height: 28)
            .foregroundStyle(Color(.systemGray5))
            .overlay {
              Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 12)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(selected ? Color(theme.accent).opacity(0.1) : ThemeManager.shared.cardBackgroundColor)
    )
    .animation(.easeOut(duration: 0.08), value: selected)
  }
}
