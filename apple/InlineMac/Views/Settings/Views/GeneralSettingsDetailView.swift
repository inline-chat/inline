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
            .launchAtLogin,
            description: "Unavailable in local debug builds."
          )
        }
        .settingsSearchAnchor(.launchAtLogin)
          .disabled(true)
#else
        Toggle(isOn: $appSettings.launchAtLogin) {
          SettingsRowLabel(.launchAtLogin)
        }
        .settingsSearchAnchor(.launchAtLogin)
#endif
      } header: {
        SettingsSectionHeader("Startup")
      }

      Section {
        Toggle(isOn: $appSettings.automaticSpellCorrection) {
          SettingsRowLabel(
            .automaticSpellCorrection,
            description: "Correct misspelled words while composing messages."
          )
        }
        .settingsSearchAnchor(.automaticSpellCorrection)

        Toggle(isOn: $appSettings.checkSpellingWhileTyping) {
          SettingsRowLabel(
            .checkSpellingWhileTyping,
            description: "Underline misspelled words while composing messages."
          )
        }
        .settingsSearchAnchor(.checkSpellingWhileTyping)

        Toggle(isOn: $composeSettings.replacePastedLinksWithTitles) {
          SettingsRowLabel(
            .shortenSupportedLinks,
            description: "Turn supported pasted links into compact text links. Press Escape, Undo, or Backspace to restore the URL."
          )
        }
        .settingsSearchAnchor(.shortenSupportedLinks)

        LabeledContent {
          Picker("Send Messages", selection: $appSettings.sendsWithCmdEnter) {
            Text("Return").tag(false)
            Text("⌘ + Return").tag(true)
          }
          .labelsHidden()
          .pickerStyle(.menu)
        } label: {
          SettingsRowLabel(.sendMessages)
        }
        .settingsSearchAnchor(.sendMessages)
      } header: {
        SettingsSectionHeader("Writing")
      }

      Section {
        Toggle(isOn: $gestureSettings.syncEnabled) {
          SettingsRowLabel(
            .syncMessageGestures,
            description: "Sync double-click, hold, and swipe direction across your devices. Turn off to customize this Mac. Turning it back on uses your synced choices."
          )
        }
        .settingsSearchAnchor(.syncMessageGestures)

        LabeledContent {
          Picker("Double-click", selection: $gestureSettings.doubleTapAction) {
            ForEach(MessageGestureAction.allCases) { action in
              Text(action.title).tag(action)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
        } label: {
          SettingsRowLabel(.doubleClick)
        }
        .settingsSearchAnchor(.doubleClick)

        LabeledContent {
          Picker("Hold", selection: $gestureSettings.holdAction) {
            ForEach(MessageGestureAction.allCases.filter { $0 != .none }) { action in
              Text(action.title).tag(action)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
        } label: {
          SettingsRowLabel(.hold)
        }
        .settingsSearchAnchor(.hold)

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
            .swipeToReply,
            description: "Choose which direction to swipe a message when replying."
          )
        }
        .settingsSearchAnchor(.swipeToReply)

        Toggle(isOn: $appSettings.translationUIEnabled) {
          SettingsRowLabel(
            .translationControls,
            description: "Show translation actions for supported messages."
          )
        }
        .settingsSearchAnchor(.translationControls)

        Toggle(isOn: $appSettings.openReplyThreadsInSidePane) {
          SettingsRowLabel(
            .openReplyThreadsInSidePane,
            description: "Keep the current chat visible when opening a reply thread."
          )
        }
        .settingsSearchAnchor(.openReplyThreadsInSidePane)
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
            .openChatsCleanup,
            dynamicDescription: appSettings.sidebarCleanupInterval.detailText
          )
        }
        .settingsSearchAnchor(.openChatsCleanup)
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
