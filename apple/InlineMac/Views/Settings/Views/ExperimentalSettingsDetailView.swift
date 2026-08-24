import SwiftUI

struct ExperimentalSettingsDetailView: View {
  @StateObject private var settings = AppSettings.shared

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
    }
    .settingsFormStyle()
  }
}

#Preview {
  ExperimentalSettingsDetailView()
}
