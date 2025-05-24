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
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
      }
  }

  @ViewBuilder
  private var button: some View {
    Button {
      presented.toggle()
    } label: {
      Image(systemName: notificationIcon)
        .tint(Color.secondary)
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
      case .importantOnly: "slowmo"
    }
  }

  @ViewBuilder
  private var popover: some View {
    VStack(alignment: .leading, spacing: 16) {
      // Header
      VStack(alignment: .leading, spacing: 4) {
        Text("Control how you receive notifications")
          .font(.subheadline)
          .foregroundStyle(.secondary)
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
            close()
          },
        )

        NotificationSettingsItem(
          systemImage: "at",
          title: "Mentions",
          description: "Mentions of your name or username",
          selected: notificationSettings.mode == .mentions,
          value: NotificationMode.mentions,
          onChange: {
            notificationSettings.mode = $0
            close()
          },
        )

        NotificationSettingsItem(
          systemImage: "slowmo",
          title: "Important Only",
          description: "Only things that need your attention",
          selected: notificationSettings.mode == .importantOnly,
          value: NotificationMode.importantOnly,
          onChange: {
            notificationSettings.mode = $0
            close()
          },
        )

        NotificationSettingsItem(
          systemImage: "bell.slash.fill",
          title: "None",
          description: "No notifications",
          selected: notificationSettings.mode == .none,
          value: NotificationMode.none,
          onChange: {
            notificationSettings.mode = $0
            close()
          },
        )
      }
      .padding(.horizontal, 16)

      Spacer()
    }
    .padding(.vertical, 20)
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

  var body: some View {
    Button {
      onChange(value)
    } label: {
      HStack(spacing: 12) {
        Circle()
          .fill(selected ? Color.accentColor : Color(.systemGray5))
          .frame(width: 36, height: 36)
          .overlay {
            Image(systemName: systemImage)
              .font(.system(size: 18, weight: .medium))
              .foregroundStyle(selected ? Color.white : Color(.systemGray))
          }

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.body)
            .fontWeight(.medium)
            .foregroundStyle(.primary)
          Text(description)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        if selected {
          Image(systemName: "checkmark")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.blue)
        }
      }
      .padding(.vertical, 8)
      .padding(.horizontal, 12)
      .background(
        RoundedRectangle(cornerRadius: 12)
          .fill(selected ? Color.accentColor.opacity(0.1) : Color(.systemGray6))
      )
    }
    .buttonStyle(.plain)
    .animation(.easeOut(duration: 0.08), value: selected)
  }
}
