import InlineKit
import InlineIOSUI
import SwiftUI

struct ExperimentalView: View {
  @AppStorage(ExperimentalFeatureFlags.nativeFileDownloadsKey)
  private var nativeFileDownloadsEnabled = false

  @AppStorage(ExperimentalFeatureFlags.richMessageCopyEditingKey)
  private var richMessageCopyEditingEnabled = false

  @AppStorage(MessageView2Feature.preferenceKey)
  private var messageView2Enabled = false

  var body: some View {
    List {
      // Use the same purpose-based groups as macOS; see AGENTS.md when adding experiments.
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
      } header: {
        Text("Appearance & Navigation")
      } footer: {
        Text("New Home is now the standard experience for everyone.")
      }

      Section {
        SettingsItem(icon: "arrow.down.document", iconColor: .blue, title: "Native File Downloads") {
          Toggle("Native File Downloads", isOn: $nativeFileDownloadsEnabled)
            .labelsHidden()
        }
      } header: {
        Text("Files")
      } footer: {
        Text("Download message documents over encrypted realtime. Requires a V3 session and server support. Other media still use CDN. Turn off to retry failed downloads using CDN.")
      }

      Section {
        SettingsItem(icon: "textformat", iconColor: .purple, title: "Rich Copy & Markdown Editing") {
          Toggle("Rich Copy & Markdown Editing", isOn: $richMessageCopyEditingEnabled)
            .labelsHidden()
        }
      } header: {
        Text("Messages")
      } footer: {
        Text("Preserve formatting when copying messages. Show Markdown syntax when pasting formatted text or editing a message.")
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
        } header: {
          Text("Developer Tools")
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
