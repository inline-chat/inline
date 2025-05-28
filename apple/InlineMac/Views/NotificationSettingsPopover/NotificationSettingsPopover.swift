import InlineKit
import SwiftUI

/// A button that opens the notification settings popover used in home sidebar
struct NotificationSettingsButton: View {
  @EnvironmentObject private var notificationSettings: NotificationSettingsManager

  @State private var presented = false
  @State private var customizingZen = false

  var body: some View {
    button
      .popover(isPresented: $presented, arrowEdge: .trailing) {
        popover
          .padding(.vertical, 10)
          .padding(.horizontal, 8)
          .frame(width: 320)
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

  @ViewBuilder
  private var popover: some View {
    if customizingZen {
      customize
        .transition(.opacity)
    } else {
      picker
        .transition(.opacity)
    }
  }

  var notificationIcon: String {
    switch notificationSettings.mode {
      case .all: "bell"
      case .none: "bell.slash"
      case .mentions: "at"
      case .importantOnly: "moon.stars.fill"
    }
  }

  @ViewBuilder
  private var picker: some View {
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
          value: NotificationMode.all,
          onChange: {
            notificationSettings.mode = $0

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

          },
        )

        NotificationSettingsItem(
          systemImage: "moon.stars.fill",
          title: "Zen Mode",
          description: "Only what's important to you via AI",
          selected: notificationSettings.mode == .importantOnly,
          value: NotificationMode.importantOnly,
          onChange: {
            notificationSettings.mode = $0
          },
          customizeAction: {
            // Customize action for Zen Mode
            withAnimation(.easeOut(duration: 0.2)) {
              customizingZen = true
            }
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
          },
        )
      }
    }
  }

  @ViewBuilder
  private var customize: some View {
    VStack(alignment: .leading, spacing: 4) {
      // Header
      HStack {
        VStack(alignment: .leading, spacing: 0) {
          Text("Customize Zen Mode")
            .font(.headline)

          Text("Tell AI what do you want to be notified about")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }.padding(.horizontal, 6)

      Divider().foregroundStyle(.tertiary)
        .padding(.vertical, 6)

      VStack(alignment: .leading, spacing: 8) {
        Toggle(isOn: $notificationSettings.requiresMention) {
          HStack {
            Text("Require mentioning me")
            Spacer()
          }
        }
        .toggleStyle(.switch)
        .frame(maxWidth: .infinity, alignment: .leading)

        Picker("Rules", selection: $notificationSettings.usesDefaultRules) {
          Text("Default").tag(true)
          Text("Custom").tag(false)
        }
        .pickerStyle(.segmented)

        Text("Notify me when...")
          .font(.subheadline)
          .foregroundStyle(.secondary)

        TextEditor(
          text: notificationSettings.usesDefaultRules ? .constant(defaultRules) : $notificationSettings
            .customRules
        )
        .font(.body)
        .foregroundStyle(notificationSettings.usesDefaultRules ? .secondary : .primary)
        .frame(height: 100)
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .scrollContentBackground(.hidden)
        .background(.secondary.opacity(0.2))
        .cornerRadius(10)

      }.padding(.horizontal, 8)

      // Done button at the bottom
      Button(action: {
        withAnimation(.easeOut(duration: 0.2)) {
          customizingZen = false
        }
      }) {
        Spacer()
        Text("Done")
          .font(.body.weight(.bold))
          .foregroundStyle(.primary)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)
          .cornerRadius(8)
        Spacer()
      }
      .buttonStyle(.borderedProminent)
      .padding(.horizontal, 8)
      .padding(.top, 8)
    }
  }

  let defaultRules = """
  - Something urgent has came up (eg. a bug or an incident). 
  - I must wake up for something.
  """

  private func close() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
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
      if let customizeAction {
        Button(action: customizeAction) {
          Circle()
            .frame(width: 28, height: 28)
            .foregroundStyle(.secondary.opacity(0.1))
            .overlay {
              Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tertiary)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
      }
    }
    .animation(.easeOut(duration: 0.08), value: selected)
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
