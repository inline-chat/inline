import SwiftUI

struct NotificationsSettingsDetailView: View {
  @StateObject private var appSettings = AppSettings.shared

  var body: some View {
    Form {
      Section("Sound") {
        Toggle("Disable notification sound", isOn: $appSettings.disableNotificationSound)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .padding()
  }
}

#Preview {
  NotificationsSettingsDetailView()
}