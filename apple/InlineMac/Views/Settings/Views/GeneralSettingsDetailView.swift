import SwiftUI
import InlineKit

struct GeneralSettingsDetailView: View {
  @StateObject private var appSettings = AppSettings.shared
  @ObservedObject private var autoDownload = INUserSettings.current.autoDownload

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

      Section("Auto-Download") {
        thresholdStepper("Media", value: binding(\.mediaMaxMB))
        thresholdStepper("Files", value: binding(\.fileMaxMB))
        thresholdStepper("Voice Messages", value: binding(\.voiceMaxMB))
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

  private func binding(_ keyPath: ReferenceWritableKeyPath<AutoDownloadSettingsManager, Int>) -> Binding<Int> {
    Binding {
      autoDownload[keyPath: keyPath]
    } set: { value in
      autoDownload[keyPath: keyPath] = AutoDownloadSettingsManager.clamped(value)
    }
  }

  private func thresholdStepper(_ title: String, value: Binding<Int>) -> some View {
    Stepper(value: value, in: 0 ... AutoDownloadSettingsManager.maxAllowedMB, step: 1) {
      HStack {
        Text(title)
        Spacer()
        Text(thresholdLabel(value.wrappedValue))
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
    }
  }

  private func thresholdLabel(_ value: Int) -> String {
    value <= 0 ? "Off" : "\(value) MB"
  }
}

#Preview {
  GeneralSettingsDetailView()
}
