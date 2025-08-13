import SwiftUI

struct GeneralSettingsDetailView: View {
  @StateObject private var appSettings = AppSettings.shared
  @State private var launchAtLogin = false
  @State private var showNotifications = true
  @State private var enableSounds = true

  var body: some View {
    Form {
      Section("Startup") {
        Toggle("Launch at Login", isOn: $launchAtLogin)
      }
      
      Section("Text Input") {
        Toggle("Automatic Spell Correction", isOn: $appSettings.automaticSpellCorrection)
        Toggle("Check Spelling While Typing", isOn: $appSettings.checkSpellingWhileTyping)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .padding()
  }
}

#Preview {
  GeneralSettingsDetailView()
}
