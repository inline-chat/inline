import InlineMacUI
import SwiftUI

struct NotificationsSettingsDetailView: View {
  @StateObject private var appSettings = AppSettings.shared

  var body: some View {
    Form {
      Section("Badges") {
        Toggle("Show Dock badge for unread DMs", isOn: $appSettings.showDockBadgeUnreadDMs)

        Picker("Unread badge style", selection: $appSettings.unreadBadgeStyle) {
          Text("Dot").tag(UnreadBadgeStyle.dot)
          Text("Numbered").tag(UnreadBadgeStyle.numbered)
        }
        .pickerStyle(.segmented)
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
