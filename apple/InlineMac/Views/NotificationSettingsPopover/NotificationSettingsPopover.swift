import AppKit
import InlineKit
import SwiftUI

/// A button that opens the notification settings popover used in home sidebar
struct NotificationSettingsButton: View {
  enum Style {
    case standard
    case sidebarFooter
  }

  private let style: Style
  @EnvironmentObject private var notificationSettings: NotificationSettingsManager

  @State private var presented = false
  @State private var customizingZen = false

  init(style: Style = .standard) {
    self.style = style
  }

  private var buttonSize: CGFloat {
    switch style {
      case .standard:
        Theme.sidebarTitleIconSize
      case .sidebarFooter:
        MainSidebarFooterMetrics.buttonSize
    }
  }

  var body: some View {
    button
      .popover(isPresented: $presented, arrowEdge: .trailing) {
        popover
          .padding(.vertical, 10)
          .padding(.horizontal, 8)
      }
  }

  @ViewBuilder
  private var button: some View {
    Button {
      presented.toggle()
    } label: {
      iconImage
        .frame(
          width: buttonSize,
          height: buttonSize,
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
  private var iconImage: some View {
    let image = Image(systemName: notificationIcon)
    switch style {
      case .standard:
        image
          .font(.system(size: 16, weight: .regular))
          .foregroundStyle(.tertiary)
      case .sidebarFooter:
        image
          .font(MainSidebarFooterMetrics.iconFont)
          .foregroundStyle(Color(NSColor.tertiaryLabelColor))
    }
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
      case .importantOnly: "apple.meditate"
      case .onlyMentions: "at"
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
          description: "Receive notifications for every message",
          selected: notificationSettings.mode == .all,
          value: NotificationMode.all,
          onChange: {
            notificationSettings.mode = $0
            notificationSettings.disableDmNotifications = false

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

          }
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
          },
          iconFontSize: 12
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
          },
          customizeAction: {
            // Customize action for Zen Mode
            customizingZen = true
          }
        )
        */

        NotificationSettingsItem(
          systemImage: "bell.slash.fill",
          title: "None",
          description: "Zero notifications",
          selected: notificationSettings.mode == .none,
          value: NotificationMode.none,
          onChange: {
            notificationSettings.mode = $0
            notificationSettings.disableDmNotifications = false
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
        Picker("Rules", selection: $notificationSettings.usesDefaultRules) {
          Text("Default").tag(true)
          Text("Custom").tag(false)
        }
        .pickerStyle(.segmented)

        Text("Notify me when...")
          .font(.subheadline)
          .foregroundStyle(.secondary)

        if notificationSettings.usesDefaultRules {
          ScrollView {
            Text(defaultRules)
              .font(.body)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(height: 100)
          .padding(.horizontal, 6)
          .padding(.vertical, 6)
          .background(.secondary.opacity(0.2))
          .cornerRadius(10)
        } else {
          TextEditor(text: $notificationSettings.customRules)
            .font(.body)
            .foregroundStyle(.primary)
            .frame(height: 100)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .scrollContentBackground(.hidden)
            .background(.secondary.opacity(0.2))
            .cornerRadius(10)
        }

      }.padding(.horizontal, 8)

      // Done button at the bottom
      HStack {
        Spacer()
        Button("Done") {
          customizingZen = false
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .buttonBorderShape(.capsule)
      }
      .padding(.horizontal, 8)
      .padding(.top, 8)
    }
  }

  let defaultRules = """
  - Something urgent has come up (e.g., a bug or an incident).
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
  var iconFontSize: CGFloat? = nil

  @State private var hovered = false

  var body: some View {
    HStack(spacing: 8) {
      Button {
        onChange(value)
      } label: {
        HStack(spacing: 8) {
          Circle()
            .fill(selected ? Color.accent : .secondary.opacity(0.3))
            .frame(width: 30, height: 30)
            .overlay {
              Image(systemName: systemImage)
                .font(.system(size: iconFontSize ?? 16, weight: .regular))
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
              .lineLimit(1)
          }

          Spacer()
        }
      }
      .buttonStyle(.plain)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())

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
    .frame(maxWidth: .infinity, alignment: .leading)
    .animation(.easeOut(duration: 0.08), value: selected)
    .padding(4)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(hovered ? Color.secondary.opacity(0.2) : Color.clear)
        .animation(.easeOut(duration: 0.1), value: hovered)
    )
    .onHover { hovered in
      self.hovered = hovered
    }
  }
}

#Preview {
  NotificationSettingsButton()
    .previewsEnvironmentForMac(.populated)
}
