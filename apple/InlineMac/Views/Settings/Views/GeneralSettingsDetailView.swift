import InlineKit
import InlineUI
import SwiftUI

struct GeneralSettingsDetailView: View {
  @StateObject private var appSettings = AppSettings.shared
  @ObservedObject private var gestureSettings = INUserSettings.current.messageGestures
  @ObservedObject private var composeSettings = INUserSettings.current.compose

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

        Toggle(isOn: $composeSettings.replacePastedLinksWithTitles) {
          SettingsRowLabel(
            "Shorten Supported Links",
            description: "Turn supported pasted links into compact text links. Press Escape, Undo, or Backspace to restore the URL."
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
        Toggle(isOn: $gestureSettings.syncEnabled) {
          SettingsRowLabel(
            "Sync Message Gestures",
            description: "Sync double-click, hold, and swipe direction across your devices. Turn off to customize this Mac. Turning it back on uses your synced choices."
          )
        }

        LabeledContent {
          Picker("Double-click", selection: $gestureSettings.doubleTapAction) {
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
          Picker("Hold", selection: $gestureSettings.holdAction) {
            ForEach(MessageGestureAction.allCases.filter { $0 != .none }) { action in
              Text(action.title).tag(action)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
        } label: {
          SettingsRowLabel("Hold")
        }

        LabeledContent {
          Picker("Swipe to Reply", selection: $gestureSettings.swipeToReplyDirection) {
            ForEach(MessageSwipeToReplyDirection.allCases) { direction in
              Text(direction.title).tag(direction)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
        } label: {
          SettingsRowLabel(
            "Swipe to Reply",
            description: "Choose which direction to swipe a message when replying."
          )
        }

        Toggle(isOn: $appSettings.translationUIEnabled) {
          SettingsRowLabel(
            "Translation Controls",
            description: "Show translation actions for supported messages."
          )
        }

        Toggle(isOn: $appSettings.openReplyThreadsInSidePane) {
          SettingsRowLabel(
            "Open Reply Threads in Side Pane",
            description: "Keep the current chat visible when opening a reply thread."
          )
        }
      } header: {
        SettingsSectionHeader("Messages")
      }

      Section {
        LabeledContent {
          Picker("Open Chats Cleanup", selection: $appSettings.sidebarCleanupInterval) {
            ForEach(SidebarCleanupInterval.allCases) { interval in
              Text(interval.title).tag(interval)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
        } label: {
          SettingsRowLabel(
            "Open Chats Cleanup",
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
