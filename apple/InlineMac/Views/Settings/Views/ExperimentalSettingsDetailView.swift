import SwiftUI

struct ExperimentalSettingsDetailView: View {
  @StateObject private var appSettings = AppSettings.shared

  var body: some View {
    Form {
      Section("Experimental") {
        Toggle("Enable voice messages", isOn: $appSettings.enableVoiceMessages)
        Toggle("Enable rich text messages", isOn: $appSettings.enableRichTextMessages)

        Text("Rich rendering is gated for beta; older clients keep using fallback text. Toggling it reloads visible messages.")
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
