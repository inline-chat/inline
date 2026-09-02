import InlineKit
import SwiftUI

struct ExperimentalSettingsDetailView: View {
  @StateObject private var settings = AppSettings.shared
  @AppStorage(ExperimentalFeatureFlags.mentionableAgentsKey)
  private var mentionableAgentsEnabled = false
  @AppStorage(ExperimentalFeatureFlags.nativeFileDownloadsKey)
  private var nativeFileDownloadsEnabled = false

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $nativeFileDownloadsEnabled) {
          SettingsRowLabel(
            "Native File Downloads",
            description: "Download message documents over encrypted realtime. Other media still use CDN."
          )
        }
      } header: {
        SettingsSectionHeader("Files")
      } footer: {
        Text("Requires a V3 session and server support. Turn off to retry failed downloads using CDN.")
      }

      Section {
        Toggle(isOn: $settings.richContentRendererEnabled) {
          SettingsRowLabel(
            "Rich Content Renderer",
            description: "Render supported agent Markdown as native rich-content blocks in messages."
          )
        }
        Toggle(isOn: $settings.richTextNativeMathEnabled) {
          SettingsRowLabel(
            "Native Math Rendering",
            description: "Render supported LaTeX as native formulas. When off, formulas remain readable and copyable as source."
          )
        }
      } header: {
        SettingsSectionHeader("Messages")
      }

      Section {
        Toggle(isOn: $mentionableAgentsEnabled) {
          SettingsRowLabel(
            "Skilled Agents",
            description: "Show Skilled Agent creation, profiles, and @mention autocomplete in the app."
          )
        }
      } header: {
        SettingsSectionHeader("Skilled Agents")
      } footer: {
        Text("Server and Bot API support remain available when this is off.")
      }
    }
    .settingsFormStyle()
    .onChange(of: mentionableAgentsEnabled) { _, _ in
      BotAgentDirectory.shared.clear()
      NotificationCenter.default.post(name: .mentionableAgentsExperimentChanged, object: nil)
    }
  }
}

#Preview {
  ExperimentalSettingsDetailView()
}
