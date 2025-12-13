import SwiftUI

struct NotificationsSettingsDetailView: View {
  @StateObject private var appSettings = AppSettings.shared

  var body: some View {
    Form {
      Section("Badges") {
        Toggle("Show Dock badge for unread DMs", isOn: $appSettings.showDockBadgeUnreadDMs)
      }
      Section("Sound") {
        Toggle("Disable notification sound", isOn: $appSettings.disableNotificationSound)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }
}

#Preview {
  NotificationsSettingsDetailView()
}
