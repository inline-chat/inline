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
        Toggle("Send with Cmd+Enter", isOn: $appSettings.sendsWithCmdEnter)
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
