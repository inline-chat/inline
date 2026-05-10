import InlineKit
import SwiftUI

struct ExperimentalView: View {
  @AppStorage("enableExperimentalView") private var enableExperimentalView = false
  @AppStorage(ExperimentalFeatureFlags.voiceMessagesKey) private var enableVoiceMessages = false

  var body: some View {
    List {
      Section("Experimental") {
        SettingsItem(
          icon: "sparkles",
          iconColor: .purple,
          title: "Enable experimental view"
        ) {
          Toggle("", isOn: $enableExperimentalView)
            .labelsHidden()
            .accessibilityLabel("Enable experimental view")
        }

        SettingsItem(
          icon: "waveform",
          iconColor: .red,
          title: "Enable voice messages"
        ) {
          Toggle("", isOn: $enableVoiceMessages)
            .labelsHidden()
            .accessibilityLabel("Enable voice messages")
        }

        Text("Experimental voice features and UI changes may require an app restart.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Experimental")
    .navigationBarTitleDisplayMode(.inline)
  }
}

#Preview("Experimental") {
  NavigationView {
    ExperimentalView()
  }
}
