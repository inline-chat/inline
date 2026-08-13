#if DEBUG || DEBUG_BUILD
import InlineKit
import SwiftUI
import UserNotifications

struct DeveloperPlaygroundNotificationView: View {
  @State private var senderName = "Ava Lin"
  @State private var message = "The notification avatar should match the user state."
  @State private var isThread = false
  @State private var soundEnabled = false
  @State private var authorizationStatus = UNAuthorizationStatus.notDetermined
  @State private var resultText: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        DeveloperPlaygroundNotificationHeader(
          authorizationStatus: authorizationStatus,
          requestAuthorization: {
            Task {
              _ = try? await MacPermissions.requestNotifications()
              await refreshAuthorizationStatus()
            }
          },
          openSettings: {
            MacPermissions.openSystemSettings(.notifications)
          }
        )
        DeveloperPlaygroundNotificationConfiguration(
          senderName: $senderName,
          message: $message,
          isThread: $isThread,
          soundEnabled: $soundEnabled
        )
        DeveloperPlaygroundNotificationModes(
          canTrigger: canTrigger,
          trigger: { mode in
            Task { _ = await trigger(mode) }
          },
          triggerAll: {
            Task {
              for mode in MacNotificationPlaygroundAvatarMode.allCases {
                _ = await trigger(mode)
              }
            }
          }
        )

        if let resultText {
          Text(verbatim: resultText)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: 780, alignment: .topLeading)
      .padding(24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(nsColor: .windowBackgroundColor))
    .task {
      await refreshAuthorizationStatus()
    }
  }

  private var canTrigger: Bool {
    authorizationStatus == .authorized || authorizationStatus == .provisional
  }

  @discardableResult
  private func trigger(_ mode: MacNotificationPlaygroundAvatarMode) async -> Bool {
    let didSchedule = await MacNotifications.shared.showPlaygroundNotification(
      avatarMode: mode,
      senderName: senderName.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Ava Lin",
      body: message.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Test notification",
      isThread: isThread,
      soundEnabled: soundEnabled
    )
    resultText = didSchedule
      ? "Triggered \(mode.title.lowercased()) notification."
      : "The notification could not be scheduled."
    return didSchedule
  }

  private func refreshAuthorizationStatus() async {
    authorizationStatus = await MacPermissions.notificationSettings().authorizationStatus
  }
}

private struct DeveloperPlaygroundNotificationHeader: View {
  let authorizationStatus: UNAuthorizationStatus
  let requestAuthorization: () -> Void
  let openSettings: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Notifications")
        .font(.title2.weight(.semibold))
      Text("Trigger real macOS notifications for each authoritative avatar state.")
        .foregroundStyle(.secondary)

      HStack(spacing: 8) {
        Label {
          Text(verbatim: authorizationTitle)
        } icon: {
          Image(systemName: authorizationIconName)
        }
          .foregroundStyle(authorizationStatus == .authorized ? Color.green : Color.secondary)

        if authorizationStatus == .notDetermined {
          Button("Allow Notifications", action: requestAuthorization)
        } else if authorizationStatus == .denied {
          Button("Open Settings", action: openSettings)
        }
      }
      .font(.caption)
      .padding(.top, 6)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var authorizationTitle: String {
    switch authorizationStatus {
    case .authorized, .provisional, .ephemeral:
      "Notifications allowed"
    case .denied:
      "Notifications denied"
    case .notDetermined:
      "Permission not requested"
    @unknown default:
      "Notification permission unknown"
    }
  }

  private var authorizationIconName: String {
    let isAllowed = authorizationStatus == .authorized || authorizationStatus == .provisional
    return isAllowed ? "checkmark.circle.fill" : "exclamationmark.circle"
  }
}

private struct DeveloperPlaygroundNotificationConfiguration: View {
  @Binding var senderName: String
  @Binding var message: String
  @Binding var isThread: Bool
  @Binding var soundEnabled: Bool

  var body: some View {
    GroupBox("Content") {
      Form {
        TextField("Sender", text: $senderName)
        TextField("Message", text: $message)
        Toggle("Team chat presentation", isOn: $isThread)
        Toggle("Play sound", isOn: $soundEnabled)
      }
      .formStyle(.columns)
      .padding(8)
    }
  }
}

private struct DeveloperPlaygroundNotificationModes: View {
  let canTrigger: Bool
  let trigger: (MacNotificationPlaygroundAvatarMode) -> Void
  let triggerAll: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Avatar outcomes")
            .font(.headline)
          Text("These states must not be substituted for one another.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Button("Trigger All Three", action: triggerAll)
          .disabled(!canTrigger)
      }

      ForEach(MacNotificationPlaygroundAvatarMode.allCases, id: \.self) { mode in
        DeveloperPlaygroundNotificationModeRow(
          mode: mode,
          action: {
            trigger(mode)
          }
        )
        .disabled(!canTrigger)
      }
    }
  }
}

private struct DeveloperPlaygroundNotificationModeRow: View {
  let mode: MacNotificationPlaygroundAvatarMode
  let action: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: mode.iconName)
        .font(.title3)
        .foregroundStyle(mode.tint)
        .frame(width: 32, height: 32)
        .background(mode.tint.opacity(0.12), in: Circle())

      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: mode.title)
          .font(.subheadline.weight(.medium))
        Text(verbatim: mode.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Button("Trigger", action: action)
    }
    .padding(14)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
    }
  }
}

private extension MacNotificationPlaygroundAvatarMode {
  var title: String {
    switch self {
    case .photo: "Photo"
    case .initials: "Initials"
    case .none: "No avatar"
    }
  }

  var detail: String {
    switch self {
    case .photo:
      "A configured and available image attachment (an offline portrait fixture is used)."
    case .initials:
      "No profile photo is configured, so the shared initials style is authoritative."
    case .none:
      "A configured photo is unavailable, so no substitute avatar is attached."
    }
  }

  var iconName: String {
    switch self {
    case .photo: "photo.fill"
    case .initials: "person.text.rectangle"
    case .none: "person.crop.circle.badge.xmark"
    }
  }

  var tint: Color {
    switch self {
    case .photo: .blue
    case .initials: .purple
    case .none: .secondary
    }
  }
}

private extension String {
  var nonEmpty: String? {
    isEmpty ? nil : self
  }
}
#endif
