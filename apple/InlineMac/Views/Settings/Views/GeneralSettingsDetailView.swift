import SwiftUI

struct GeneralSettingsDetailView: View {
  @StateObject private var appSettings = AppSettings.shared

  var body: some View {
    Form {
      Section {
#if DEBUG_BUILD
        Toggle(isOn: .constant(false)) {
          SettingsRowLabel(
            "Launch at Login",
            description: "Unavailable in local debug builds."
          )
        }
          .disabled(true)
#else
        Toggle(isOn: $appSettings.launchAtLogin) {
          SettingsRowLabel("Launch at Login")
        }
#endif
      } header: {
        SettingsSectionHeader("Startup")
      }

      Section {
        Toggle(isOn: $appSettings.automaticSpellCorrection) {
          SettingsRowLabel(
            "Automatic Spell Correction",
            description: "Correct misspelled words while composing messages."
          )
        }

        Toggle(isOn: $appSettings.checkSpellingWhileTyping) {
          SettingsRowLabel(
            "Check Spelling While Typing",
            description: "Underline misspelled words while composing messages."
          )
        }

        LabeledContent {
          Picker("Send Messages", selection: $appSettings.sendsWithCmdEnter) {
            Text("Return").tag(false)
            Text("⌘ + Return").tag(true)
          }
          .labelsHidden()
          .pickerStyle(.menu)
        } label: {
          SettingsRowLabel("Send Messages")
        }
      } header: {
        SettingsSectionHeader("Writing")
      }

      Section {
        LabeledContent {
          Picker("Double-click", selection: $appSettings.messageDoubleClickAction) {
            ForEach(MessageGestureAction.allCases) { action in
              Text(action.title).tag(action)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
        } label: {
          SettingsRowLabel("Double-click")
        }

        LabeledContent {
          Picker("Hold", selection: $appSettings.messageHoldAction) {
            ForEach(MessageGestureAction.allCases) { action in
              Text(action.title).tag(action)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
        } label: {
          SettingsRowLabel("Hold")
        }

        Toggle(isOn: $appSettings.translationUIEnabled) {
          SettingsRowLabel(
            "Translation Controls",
            description: "Show translation actions for supported messages."
          )
        }

      } header: {
        SettingsSectionHeader("Messages")
      }

      Section {
        LabeledContent {
          Picker("Sidebar Cleanup", selection: $appSettings.sidebarCleanupInterval) {
            ForEach(SidebarCleanupInterval.allCases) { interval in
              Text(interval.title).tag(interval)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
        } label: {
          SettingsRowLabel(
            "Sidebar Cleanup",
            dynamicDescription: appSettings.sidebarCleanupInterval.detailText
          )
        }
      } header: {
        SettingsSectionHeader("Sidebar")
      }
    }
    .settingsFormStyle()
  }
}

#Preview {
  GeneralSettingsDetailView()
}
