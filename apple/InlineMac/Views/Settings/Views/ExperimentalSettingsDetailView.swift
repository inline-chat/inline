import SwiftUI

struct ExperimentalSettingsDetailView: View {
  @StateObject private var appSettings = AppSettings.shared

  var body: some View {
    Form {
      Section("Experimental") {
        Toggle("Enable voice messages", isOn: $appSettings.enableVoiceMessages)

        Text("Voice features may require an app restart.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }
}

#Preview {
  ExperimentalSettingsDetailView()
}
