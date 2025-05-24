import SwiftUI
import InlineKit

/// A button that opens the notification settings popover used in home sidebar
struct NotificationSettingsButton: View {
  @EnvironmentObject private var notificationSettings: NotificationSettingsManager

  @State private var presented = false

  var body: some View {
    button
      .popover(isPresented: $presented, arrowEdge: .trailing) {
        popover
        // .frame(width: 300, height: 400)
      }
  }

  @ViewBuilder
  private var button: some View {
    Button {
      presented.toggle()
    } label: {
      Image(systemName: notificationIcon)
        .font(.system(size: 16, weight: .regular))
        .foregroundStyle(.tertiary)
        .frame(
          width: Theme.sidebarTitleIconSize,
          height: Theme.sidebarTitleIconSize,
          alignment: .center
        )
        .transition(.asymmetric(
          insertion: .scale.combined(with: .opacity),
          removal: .scale.combined(with: .opacity)
        ))
        .animation(.easeOut(duration: 0.2), value: notificationIcon)
    }
    .buttonStyle(.plain)
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
    VStack(alignment: .leading, spacing: 4) {
      // Header
      HStack {
        VStack(alignment: .leading, spacing: 0) {
          Text("Notifications")
            .font(.headline)

          Text("Control how you receive notifications")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }.padding(.horizontal, 6)

      Divider().foregroundStyle(.tertiary)

      VStack(alignment: .leading, spacing: 1) {
        NotificationSettingsItem(
          systemImage: "bell.fill",
          title: "All",
          description: "Receive all notifications",
          selected: notificationSettings.mode == .all,
          value: .all,
          onChange: { notificationSettings.mode = $0 },
        )

        NotificationSettingsItem(
          systemImage: "at",
          title: "Mentions",
          description: "Mentions of your name or username",
          selected: notificationSettings.mode == .mentions,
          value: .mentions,
          onChange: { notificationSettings.mode = $0 },
        )

        NotificationSettingsItem(
          systemImage: "slowmo",
          title: "Important Only",
          description: "Only things that need your attention",
          selected: notificationSettings.mode == .importantOnly,
          value: .importantOnly,
          onChange: { notificationSettings.mode = $0 },
        )

        NotificationSettingsItem(
          systemImage: "bell.slash.fill",
          title: "None",
          description: "No notifications",
          selected: notificationSettings.mode == .none,
          value: .none,
          onChange: { notificationSettings.mode = $0 },
        )
      }
    }
    .padding(.vertical, 10)
    .padding(.horizontal, 8)
    .frame(width: 260)
  }
}

private struct NotificationSettingsItem<Value: Equatable>: View {
  var systemImage: String
  var title: String
  var description: String
  var selected: Bool
  var value: Value
  var onChange: (Value) -> Void

  @State private var hovered = false

  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(selected ? Color.accent : .secondary.opacity(0.3))
        .frame(width: 30, height: 30)
        .overlay {
          Image(systemName: systemImage)
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(selected ? Color.white : .secondary.opacity(0.9))
            .frame(
              width: 28,
              height: 28,
              alignment: .center
            )
        }

      VStack(alignment: .leading, spacing: 0) {
        Text(title)
          .font(.body)
        Text(description)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .padding(.top, -1)
      }
      Spacer()
    }
    .animation(.easeOut(duration: 0.05), value: selected)
    .padding(4)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(hovered ? Color.secondary.opacity(0.2) : Color.clear)
        .animation(.easeOut(duration: 0.1), value: hovered)
    )
    .onTapGesture {
      onChange(value)
    }
    .onHover { hovered in
      self.hovered = hovered
    }
  }
}

#Preview {
  NotificationSettingsButton()
    .previewsEnvironmentForMac(.populated)
}
