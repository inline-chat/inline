import InlineKit
import InlineIOSUI
import SwiftUI

struct ExperimentalView: View {
  @AppStorage(ExperimentalFeatureFlags.mentionableAgentsKey)
  private var mentionableAgentsEnabled = false

  @AppStorage(ExperimentalFeatureFlags.nativeFileDownloadsKey)
  private var nativeFileDownloadsEnabled = false

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

      Section {
        SettingsItem(
          icon: "at",
          iconColor: .purple,
          title: "Skilled Agents"
        ) {
          Toggle("Skilled Agents", isOn: $mentionableAgentsEnabled)
            .labelsHidden()
        }
      } footer: {
        Text("Show Skilled Agent creation, profiles, and @mention autocomplete. Server and Bot API support remain available when this is off.")
      }

      Section {
        SettingsItem(icon: "arrow.down.document", iconColor: .blue, title: "Native File Downloads") {
          Toggle("Native File Downloads", isOn: $nativeFileDownloadsEnabled)
            .labelsHidden()
        }
      } footer: {
        Text("Download message documents over encrypted realtime. Requires a V3 session and server support. Other media still use CDN. Turn off to retry failed downloads using CDN.")
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
    .onChange(of: mentionableAgentsEnabled) { _, _ in
      BotAgentDirectory.shared.clear()
      NotificationCenter.default.post(name: .mentionableAgentsExperimentChanged, object: nil)
    }
  }
}

#Preview("Experimental") {
  NavigationStack {
    ExperimentalView()
  }
}
