import SwiftUI

struct ExperimentalSettingsDetailView: View {
  @StateObject private var settings = AppSettings.shared

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $settings.appKitSidebarEnabled) {
          SettingsRowLabel(
            "AppKit Sidebar",
            description: "Use the collection-view sidebar with nested reply threads and native scrolling and reordering."
          )
        }
        .toggleStyle(.switch)
      } header: {
        SettingsSectionHeader("Experimental")
      }
    }
    .settingsFormStyle()
  }
}

#Preview {
  ExperimentalSettingsDetailView()
}
