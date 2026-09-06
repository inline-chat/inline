import InlineKit
import SwiftUI

struct ExperimentalSettingsDetailView: View {
  @StateObject private var settings = AppSettings.shared
  @AppStorage(ExperimentalFeatureFlags.nativeFileDownloadsKey)
  private var nativeFileDownloadsEnabled = false
  @AppStorage(ExperimentalFeatureFlags.quickForwardKey)
  private var quickForwardEnabled = false

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
        Toggle(isOn: $quickForwardEnabled) {
          SettingsRowLabel(
            "Quick Forward",
            description: "Work in progress. Forward multiple messages with an optional message without opening another chat."
          )
        }
        Toggle(isOn: $settings.richContentRendererEnabled) {
          SettingsRowLabel(
            "Rich Content Renderer",
            description: "Render supported agent Markdown as native rich-content blocks in messages."
          )
        }
        Toggle(isOn: $settings.richTextInlineMathEnabled) {
          SettingsRowLabel(
            "Inline Math Attachments",
            description: "Replace supported inline LaTeX with native formula attachments. Display formulas always render normally."
          )
        }
        Toggle(isOn: $settings.richTextMultiSurfaceSelectionEnabled) {
          SettingsRowLabel(
            "Rich Message Multi-Block Selection",
            description: "Select and copy across text blocks within one rich message."
          )
        }
      } header: {
        SettingsSectionHeader("Messages")
      }
    }
    .settingsFormStyle()
  }
}

#Preview {
  ExperimentalSettingsDetailView()
}
