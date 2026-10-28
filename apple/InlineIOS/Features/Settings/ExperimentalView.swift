import Auth
import InlineKit
import InlineIOSUI
import SwiftUI

struct ExperimentalView: View {
  @ObservedObject private var auth = Auth.shared
  @AppStorage(ExperimentalFeatureFlags.nativeFileDownloadsKey)
  private var nativeFileDownloadsEnabled = false

  @AppStorage(ExperimentalFeatureFlags.richMessageCopyEditingKey)
  private var richMessageCopyEditingEnabled = false

  @AppStorage(NextMessageViewFeature.preferenceKey)
  private var nextMessageViewEnabled = false

  @AppStorage(MessageContextMenuFeature.preferenceKey)
  private var customContextMenuEnabled = false

  var body: some View {
    List {
      // Use the same purpose-based groups as macOS; see AGENTS.md when adding experiments.
      Section {
        SettingsItem(icon: "arrow.down.document", iconColor: .blue, title: "Native File Downloads") {
          Toggle("Native File Downloads", isOn: $nativeFileDownloadsEnabled)
            .labelsHidden()
            .disabled(!nativeFileDownloadsAvailable && !nativeFileDownloadsEnabled)
        }
      } header: {
        Text("Files")
      } footer: {
        if nativeFileDownloadsAvailable {
          Text("Download documents and videos over the realtime connection. Other media use standard downloads. Turn off to use standard downloads for everything.")
        } else if nativeFileDownloadsEnabled {
          Text("Sign in to use native file downloads. Turn off to clear the saved preference.")
        } else {
          Text("Sign in to use native file downloads.")
        }
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
            title: "Next Message View"
          ) {
            Toggle("Next Message View", isOn: $nextMessageViewEnabled)
              .labelsHidden()
          }
          SettingsItem(
            icon: "contextualmenu.and.cursorarrow",
            iconColor: .indigo,
            title: "Custom Context Menu"
          ) {
            Toggle("Custom Context Menu", isOn: $customContextMenuEnabled)
              .labelsHidden()
          }
        } header: {
          Text("Developer Tools")
        } footer: {
          Text("Next Message View uses the next iOS message view as it is built. Custom Context Menu opens Inline's own message menu: it scrolls with long messages and lets you select text in the preview, best with Next Message View. Reopen the chat after changing these settings.")
        }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Experimental")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var nativeFileDownloadsAvailable: Bool {
    auth.getIsLoggedIn()
  }
}

#Preview("Experimental") {
  NavigationStack {
    ExperimentalView()
  }
}
