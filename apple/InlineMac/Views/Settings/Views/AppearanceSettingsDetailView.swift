import SwiftUI

struct AppearanceSettingsDetailView: View {
  @ObservedObject private var settings = AppSettings.shared
  @State private var colorScheme: ColorSchemePreference = .automatic
  
  var body: some View {
    Form {
      Section("Theme") {
        Picker("Appearance", selection: $colorScheme) {
          Text("Automatic").tag(ColorSchemePreference.automatic)
          Text("Light").tag(ColorSchemePreference.light)
          Text("Dark").tag(ColorSchemePreference.dark)
        }
        .pickerStyle(.segmented)
      }
      
      Section("Keyboard") {
        Picker("Send messages with:", selection: $settings.sendsWithCmdEnter) {
          Text("Return").tag(false)
          Text("⌘ + Return").tag(true)
        }
        .pickerStyle(.menu)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .padding()
  }
}

enum ColorSchemePreference: String, CaseIterable {
  case automatic = "automatic"
  case light = "light"
  case dark = "dark"
}

#Preview {
  AppearanceSettingsDetailView()
}