import SwiftUI

struct ExperimentalSettingsDetailView: View {
  @StateObject private var settings = AppSettings.shared

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $settings.swiftUIReplyThreadInspectorEnabled) {
          SettingsRowLabel(
            "Native Reply Inspector",
            description: "Show side-pane reply threads in SwiftUI's native inspector and window toolbar."
          )
        }
      } header: {
        SettingsSectionHeader("Threads")
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
    }
    .settingsFormStyle()
  }
}
