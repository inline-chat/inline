import SwiftUI

struct ExperimentalSettingsDetailView: View {
  var body: some View {
    Form {
      Section {
        SettingsEmptyRow(
          "No Experimental Features",
          description: "Experimental controls will appear here when they are available.",
          systemImage: "testtube.2"
        )
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
