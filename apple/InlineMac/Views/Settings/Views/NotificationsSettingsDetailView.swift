import SwiftUI

struct NotificationsSettingsDetailView: View {
  @StateObject private var appSettings = AppSettings.shared

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $appSettings.showDockBadgeUnreadDMs) {
          SettingsRowLabel(
            "Dock Badge",
            description: "Show important unread chats on Inline's Dock icon."
          )
        }
      } header: {
        SettingsSectionHeader("Dock")
      }

      Section {
        Toggle(isOn: $appSettings.notificationSoundEnabled) {
          SettingsRowLabel("Notification Sounds")
        }
      } header: {
        SettingsSectionHeader("Sound")
      }
    }
    .settingsFormStyle()
  }
}

#Preview {
  NotificationsSettingsDetailView()
}
