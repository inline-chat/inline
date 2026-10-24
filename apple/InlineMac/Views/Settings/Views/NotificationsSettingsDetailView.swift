import SwiftUI

struct NotificationsSettingsDetailView: View {
  @StateObject private var appSettings = AppSettings.shared

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $appSettings.showDockBadgeUnreadDMs) {
          SettingsRowLabel(
            .dockBadge,
            description: "Show important unread chats on Inline's Dock icon."
          )
        }
        .settingsSearchAnchor(.dockBadge)
      } header: {
        SettingsSectionHeader("Dock")
      }

      Section {
        Toggle(isOn: $appSettings.notificationSoundEnabled) {
          SettingsRowLabel(.notificationSounds)
        }
        .settingsSearchAnchor(.notificationSounds)
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
