import AppKit
import SwiftUI

struct UpdatesSettingsDetailView: View {
  @StateObject private var appSettings = AppSettings.shared
  var body: some View {
    Form {
      #if SPARKLE
      Section("Automatic Updates") {
        Picker("Automatic Updates", selection: $appSettings.autoUpdateMode) {
          ForEach(AutoUpdateMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.menu)

        Picker("Update Channel", selection: $appSettings.autoUpdateChannel) {
          ForEach(AutoUpdateChannel.allCases) { channel in
            Text(channel.title).tag(channel)
          }
        }
        .pickerStyle(.menu)
      }

      Section {
        Button("Check for Updates...") {
          checkForUpdates()
        }
      }
      #else
      Section {
        Text("Updates are unavailable in this build.")
          .foregroundStyle(.secondary)
      }
      #endif
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }

  #if SPARKLE
  private func checkForUpdates() {
    (NSApp.delegate as? AppDelegate)?.checkForUpdates(nil)
  }
  #endif
}

#Preview {
  UpdatesSettingsDetailView()
}
