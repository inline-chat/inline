import InlineIOSUI
import SwiftUI

struct ExperimentalView: View {
  @AppStorage(MessageView2Feature.preferenceKey)
  private var messageView2Enabled = false

  var body: some View {
    List {
      Section {
        LabeledContent {
          Text("Enabled")
            .foregroundStyle(.secondary)
        } label: {
          VStack(alignment: .leading, spacing: 3) {
            Text("New Home")
            Text("Use the Open, All Chats, and Search tabs.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
      } footer: {
        Text("New Home is now the standard experience for everyone.")
      }

      if SettingsBuildAudience.showsDebugTools {
        Section {
          SettingsItem(
            icon: "text.bubble.fill",
            iconColor: .orange,
            title: "Message View 2"
          ) {
            Toggle("Message View 2", isOn: $messageView2Enabled)
              .labelsHidden()
          }
        } footer: {
          Text("Uses the experimental iOS message renderer. Reopen the chat after changing this setting.")
        }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Experimental")
    .navigationBarTitleDisplayMode(.inline)
  }
}

#Preview("Experimental") {
  NavigationStack {
    ExperimentalView()
  }
}
