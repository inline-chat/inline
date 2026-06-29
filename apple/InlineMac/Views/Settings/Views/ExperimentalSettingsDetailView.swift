import SwiftUI

struct ExperimentalSettingsDetailView: View {
  // Example future toggle:
  // @AppStorage("experimental.exampleFeature") private var enableExampleFeature = false

  var body: some View {
    Form {
      Section("Experimental") {
        Text("Experimental toggles will appear here.")
          .foregroundStyle(.secondary)

        // Example future toggle:
        // Toggle("Enable example feature", isOn: $enableExampleFeature)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }
}

#Preview {
  ExperimentalSettingsDetailView()
}
