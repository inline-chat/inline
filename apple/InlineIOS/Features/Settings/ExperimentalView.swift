import SwiftUI

struct ExperimentalView: View {
  // Example future toggle:
  // @AppStorage("experimental.exampleFeature") private var enableExampleFeature = false

  var body: some View {
    List {
      Section("Experimental") {
        Text("Experimental toggles will appear here.")
          .foregroundStyle(.secondary)

        // Example future toggle:
        // SettingsItem(
        //   icon: "sparkles",
        //   iconColor: .purple,
        //   title: "Enable example feature"
        // ) {
        //   Toggle("", isOn: $enableExampleFeature)
        //     .labelsHidden()
        //     .accessibilityLabel("Enable example feature")
        // }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Experimental")
    .navigationBarTitleDisplayMode(.inline)
  }
}

#Preview("Experimental") {
  NavigationView {
    ExperimentalView()
  }
}
