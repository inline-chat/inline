import InlineKit
import SwiftUI

struct ExperimentalSettingsDetailView: View {
  @StateObject private var settings = AppSettings.shared
  @AppStorage(ExperimentalFeatureFlags.mentionableAgentsKey)
  private var mentionableAgentsEnabled = false

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $settings.nativeSidebarRowsEnabled) {
          SettingsRowLabel(
            "Native AppKit Sidebar Rows",
            description: "Switch between the current SwiftUI rows and the experimental native AppKit renderer."
          )
        }
      } header: {
        SettingsSectionHeader("Sidebar")
      }

      Section {
        Toggle(isOn: $settings.richContentRendererEnabled) {
          SettingsRowLabel(
            "Rich Content Renderer",
            description: "Render supported agent Markdown as native rich-content blocks in messages."
          )
        }
      } header: {
        SettingsSectionHeader("Messages")
      }

      Section {
        Toggle(isOn: $mentionableAgentsEnabled) {
          SettingsRowLabel(
            "Mentionable Agents",
            description: "Show Agent creation, profiles, and @mention autocomplete in the app."
          )
        }
      } header: {
        SettingsSectionHeader("Agents")
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
