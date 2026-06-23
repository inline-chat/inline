import InlineKit
import SwiftUI

struct ExperimentalView: View {
  @AppStorage("enableExperimentalView") private var enableExperimentalView = false
  @AppStorage(ExperimentalFeatureFlags.voiceMessagesKey) private var enableVoiceMessages = false
  @AppStorage(ExperimentalFeatureFlags.richTextMessagesKey) private var enableRichTextMessages = false

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

        SettingsItem(
          icon: "text.alignleft",
          iconColor: .blue,
          title: "Enable rich text messages"
        ) {
          Toggle("", isOn: $enableRichTextMessages)
            .labelsHidden()
            .accessibilityLabel("Enable rich text messages")
        }

        Text("Rich rendering is gated for beta; older clients keep using fallback text.")
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
