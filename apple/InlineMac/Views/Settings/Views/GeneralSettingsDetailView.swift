import SwiftUI

struct GeneralSettingsDetailView: View {
  @StateObject private var appSettings = AppSettings.shared

  var body: some View {
    Form {
      Section("Startup") {
#if DEBUG_BUILD
        Toggle("Launch at Login", isOn: .constant(false))
          .disabled(true)
        Text("Disabled for local debug builds.")
          .font(.caption)
          .foregroundStyle(.secondary)
#else
        Toggle("Launch at Login", isOn: $appSettings.launchAtLogin)
#endif
      }

      Section("Files") {
        Toggle(
          "Automatically save downloaded files to Downloads",
          isOn: $appSettings.autoSaveDownloadedFilesToDownloadsFolder
        )
      }

      Section("Compose") {
        Toggle("Automatic Spell Correction", isOn: $appSettings.automaticSpellCorrection)
        Toggle("Check Spelling While Typing", isOn: $appSettings.checkSpellingWhileTyping)
      }

      Section("Translation") {
        Toggle("Show translation controls", isOn: $appSettings.translationUIEnabled)
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
