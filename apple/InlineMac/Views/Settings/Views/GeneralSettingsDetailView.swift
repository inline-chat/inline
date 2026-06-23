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

      Section("Compose") {
        Toggle("Automatic Spell Correction", isOn: $appSettings.automaticSpellCorrection)
        Toggle("Check Spelling While Typing", isOn: $appSettings.checkSpellingWhileTyping)
      }

      Section("Message Actions") {
        Picker("Double-click", selection: $appSettings.messageDoubleClickAction) {
          ForEach(MessageGestureAction.allCases) { action in
            Text(action.title).tag(action)
          }
        }
        .pickerStyle(.menu)

        Picker("Hold", selection: $appSettings.messageHoldAction) {
          ForEach(MessageGestureAction.allCases) { action in
            Text(action.title).tag(action)
          }
        }
        .pickerStyle(.menu)
      }

      Section("Translation") {
        Toggle("Show translation controls", isOn: $appSettings.translationUIEnabled)
      }

      Section("Sidebar") {
        LabeledContent {
          Picker("Sidebar Cleanup", selection: $appSettings.sidebarCleanupInterval) {
            ForEach(SidebarCleanupInterval.allCases) { interval in
              Text(interval.title).tag(interval)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
        } label: {
          VStack(alignment: .leading, spacing: 3) {
            Text("Sidebar Cleanup")
            Text(appSettings.sidebarCleanupInterval.detailText)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
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
