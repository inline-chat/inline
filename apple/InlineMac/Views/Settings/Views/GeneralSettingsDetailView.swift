import SwiftUI

struct GeneralSettingsDetailView: View {
  @StateObject private var appSettings = AppSettings.shared

  var body: some View {
    Form {
      // Section("Startup") {
      //   Toggle("Launch at Login", isOn: $launchAtLogin)
      // }

      Section("Compose") {
        Toggle("Automatic Spell Correction", isOn: $appSettings.automaticSpellCorrection)
        Toggle("Check Spelling While Typing", isOn: $appSettings.checkSpellingWhileTyping)
      }
      
      Section("Keyboard") {
        Picker("Send messages with:", selection: $appSettings.sendsWithCmdEnter) {
          Text("Return").tag(false)
          Text("⌘ + Return").tag(true)
        }
        .pickerStyle(.menu)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }
}

#Preview {
  GeneralSettingsDetailView()
}
