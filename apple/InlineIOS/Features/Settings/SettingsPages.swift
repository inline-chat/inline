import InlineKit
import InlineUI
import SwiftUI
import TextProcessing
import Translation
import UIKit

struct SettingsNavigationRow<Destination: View>: View {
  let title: LocalizedStringResource
  let systemImage: String
  let color: Color
  let destination: Destination

  var body: some View {
    NavigationLink {
      destination
    } label: {
      SettingsItem(icon: systemImage, iconColor: color, title: String(localized: title))
    }
  }
}

struct GeneralSettingsView: View {
  @AppStorage(InAppLinkPreferences.openLinksInAppKey)
  private var openLinksInApp = InAppLinkPreferences.defaultOpenLinksInApp
  @ObservedObject private var gestureSettings = INUserSettings.current.messageGestures
  @ObservedObject private var composeSettings = INUserSettings.current.compose

  var body: some View {
    List {
      Section {
        SettingsItem(icon: "safari.fill", iconColor: .indigo, title: "Open Links In App") {
          Toggle("Open Links In App", isOn: $openLinksInApp)
            .labelsHidden()
        }
      } footer: {
        Text("When off, links open in your default browser or the matching app.")
      }

      Section {
        SettingsItem(icon: "link", iconColor: .blue, title: String(localized: "Shorten Supported Links")) {
          Toggle("Shorten Supported Links", isOn: $composeSettings.replacePastedLinksWithTitles)
            .labelsHidden()
        }
      } footer: {
        Text("Turn supported pasted links into compact text links. Use Undo or Backspace to restore the URL.")
      }

      if UIDevice.current.userInterfaceIdiom == .pad {
        Section {
          SettingsItem(icon: "keyboard", iconColor: .blue, title: String(localized: "Send with Return")) {
            Toggle("Send with Return", isOn: $composeSettings.sendWithReturnOnIPad)
              .labelsHidden()
          }
        } footer: {
          Text("When enabled, Return sends and Shift-Return adds a new line on an external keyboard. Applies only to this iPad.")
        }
      }

      Section {
        SettingsItem(icon: "arrow.triangle.2.circlepath", iconColor: .blue, title: "Sync Message Gestures") {
          Toggle("Sync Message Gestures", isOn: $gestureSettings.syncEnabled)
            .labelsHidden()
        }
        SettingsItem(icon: "hand.tap", iconColor: .blue, title: "Double Tap") {
          Picker("Double Tap", selection: $gestureSettings.doubleTapAction) {
            ForEach(MessageGestureAction.allCases) { action in
              Text(action.title).tag(action)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
        }
        SettingsItem(icon: "hand.point.up.left", iconColor: .orange, title: "Hold") {
          Picker("Hold", selection: $gestureSettings.holdAction) {
            ForEach(MessageGestureAction.allCases.filter { $0 != .none }) { action in
              Text(action.title).tag(action)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
        }
        SettingsItem(icon: "arrow.left.arrow.right", iconColor: .green, title: "Swipe to Reply") {
          Picker("Swipe to Reply", selection: $gestureSettings.swipeToReplyDirection) {
            ForEach(MessageSwipeToReplyDirection.allCases) { direction in
              Text(direction.title).tag(direction)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
        }
      } header: {
        Text("Message Gestures")
      } footer: {
        Text("Sync double-tap, hold, and swipe direction across your devices. Turn off to customize this device. Turning it back on uses your synced choices.")
      }

      Section("Language & Translation") {
        Button {
          TranslationAlertDismiss.shared.resetAllDismissStates()
          ToastManager.shared.showToast(
            "Translation alerts reset",
            type: .success,
            systemImage: "checkmark.circle.fill"
          )
        } label: {
          SettingsItem(
            icon: "bell.badge.slash.fill",
            iconColor: .orange,
            title: "Reset Translation Alerts"
          )
        }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("General")
    .navigationBarTitleDisplayMode(.inline)
  }
}

struct AppearanceSettingsView: View {
  @AppStorage(EmojiSkinTonePreferenceStore.key)
  private var preferredEmojiSkinToneRawValue = EmojiSkinTone.standard.rawValue

  @AppStorage(ExperimentalHomePreferenceKeys.unreadBadgeStyle)
  private var unreadBadgeStyleRawValue = ExperimentalHomeUnreadBadgeStyle.defaultValue.rawValue

  var body: some View {
    List {
      Section {
        NavigationLink {
          ThemeSelectionView()
        } label: {
          SettingsItem(icon: "paintpalette.fill", iconColor: .blue, title: "Theme")
        }
      }

      Section("Chat List") {
        SettingsItem(icon: "circle.inset.filled", iconColor: .gray, title: "Unread Badges") {
          Picker("Unread Badges", selection: $unreadBadgeStyleRawValue) {
            ForEach(ExperimentalHomeUnreadBadgeStyle.allCases) { style in
              Label(style.title, systemImage: style.systemImage)
                .tag(style.rawValue)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
        }
      }

      if #available(iOS 27.0, *) {
        ChatToolbarBackgroundModeSection()
      }

      Section("Emoji") {
        SettingsItem(icon: "hand.raised.fill", iconColor: .orange, title: "Preferred Skin Tone") {
          Picker("Preferred Skin Tone", selection: $preferredEmojiSkinToneRawValue) {
            ForEach(EmojiSkinTone.allCases) { tone in
              Text(tone.settingsLabel)
                .tag(tone.rawValue)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
        }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Appearance")
    .navigationBarTitleDisplayMode(.inline)
  }
}

@available(iOS 27.0, *)
private struct ChatToolbarBackgroundModeSection: View {
  @AppStorage(ChatToolbarBackgroundMode.key)
  private var mode = ChatToolbarBackgroundMode.initialValue

  var body: some View {
    Section {
      SettingsItem(
        icon: "rectangle.topthird.inset.filled",
        iconColor: .blue,
        title: "Toolbar Background"
      ) {
        Picker("Toolbar Background", selection: $mode) {
          Text("Soft")
            .tag(ChatToolbarBackgroundMode.soft)
          Text("Hard")
            .tag(ChatToolbarBackgroundMode.hard)
        }
        .labelsHidden()
        .pickerStyle(.menu)
      }
    } header: {
      Text("Chat")
    } footer: {
      Text("Soft fades gradually into the chat. Hard uses a clearer, separated toolbar background.")
    }
  }
}

struct NotificationsSettingsView: View {
  @EnvironmentObject private var notificationSettings: NotificationSettingsManager

  var body: some View {
    List {
      Section("Notify Me For") {
        Picker("Notify Me For", selection: notificationMode) {
          Label("All", systemImage: "bell.fill")
            .tag(NotificationMode.all)
          Label("Any message to you", systemImage: "at")
            .tag(NotificationMode.mentions)
          Label("Only mentions", systemImage: "at.badge.minus")
            .tag(NotificationMode.onlyMentions)
          Label("None", systemImage: "bell.slash.fill")
            .tag(NotificationMode.none)
        }
        .pickerStyle(.inline)
        .labelsHidden()
      }

      Section("Sound") {
        SettingsItem(icon: "speaker.slash.fill", iconColor: .red, title: "Disable Sounds") {
          Toggle("Disable Sounds", isOn: $notificationSettings.silent)
            .labelsHidden()
        }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Notifications")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var notificationMode: Binding<NotificationMode> {
    Binding(
      get: {
        notificationSettings.mode == .importantOnly ? .mentions : notificationSettings.mode
      },
      set: { mode in
        notificationSettings.mode = mode
        notificationSettings.disableDmNotifications = mode == .onlyMentions
      }
    )
  }
}

struct PrivacySettingsView: View {
  @ObservedObject private var privacy = INUserSettings.current.privacy

  var body: some View {
    List {
      Section {
        SettingsItem(
          icon: "globe",
          iconColor: .blue,
          title: "Appear in Global Search"
        ) {
          Toggle("Appear in Global Search", isOn: $privacy.appearInGlobalSearch)
            .labelsHidden()
        }
      } footer: {
        Text("Allow other people to find you by username in global search.")
      }

      Section {
        NavigationLink {
          TimeZonePrivacySettingsView()
        } label: {
          SettingsItem(
            icon: "clock.fill",
            iconColor: .orange,
            title: "Time Zone"
          ) {
            Text(privacy.effectiveTimeZoneRule.summary)
              .foregroundStyle(.secondary)
          }
        }
      } footer: {
        Text("Choose who can see your local time.")
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Privacy")
    .navigationBarTitleDisplayMode(.inline)
  }
}

struct TimeZonePrivacySettingsView: View {
  @ObservedObject private var privacy = INUserSettings.current.privacy
  @State private var isEditingExceptions = false

  var body: some View {
    let rule = privacy.effectiveTimeZoneRule
    List {
      Section {
        Picker("Who Can See My Local Time", selection: audience) {
          Text("Everyone").tag(PrivacyRuleValue.Audience.everyone)
          Text("Nobody").tag(PrivacyRuleValue.Audience.nobody)
        }
        .pickerStyle(.inline)
      } header: {
        Text("Who Can See My Local Time")
      }

      Section {
        Button {
          isEditingExceptions = true
        } label: {
          HStack {
            Text(rule.exceptionsTitle)
              .foregroundStyle(.primary)
            Spacer()
            Text(exceptionsCount(rule))
              .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
              .font(.footnote.weight(.semibold))
              .foregroundStyle(.tertiary)
          }
        }
      } header: {
        Text("Exceptions")
      } footer: {
        Text(rule.audience == .everyone
          ? "Add people who shouldn’t see your local time."
          : "Add people who can see your local time.")
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Time Zone")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $isEditingExceptions) {
      PrivacyPeopleEditor(
        title: rule.exceptionsTitle,
        footer: rule.audience == .everyone
          ? "These people won’t see your local time."
          : "Only these people will see your local time.",
        selectedIDs: rule.exceptions
      ) { ids in
        var updated = privacy.effectiveTimeZoneRule
        updated.exceptions = ids
        privacy.setTimeZoneRule(updated)
      }
    }
  }

  private var audience: Binding<PrivacyRuleValue.Audience> {
    Binding(
      get: { privacy.effectiveTimeZoneRule.audience },
      set: { audience in
        var rule = privacy.effectiveTimeZoneRule
        rule.audience = audience
        privacy.setTimeZoneRule(rule)
      }
    )
  }

  private func exceptionsCount(_ rule: PrivacyRuleValue) -> String {
    let count = rule.exceptions.count
    return count == 0 ? "Add" : (count == 1 ? "1 person" : "\(count) people")
  }
}

struct DataStorageSettingsView: View {
  var body: some View {
    List {
      Section {
        NavigationLink {
          AutoDownloadSettingsView()
        } label: {
          SettingsItem(
            icon: "arrow.down.circle.fill",
            iconColor: .blue,
            title: "Auto-Download"
          )
        }
      }

      ClearCacheSettingsSection()

      ResetLocalDataSettingsSection()
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Data & Storage")
    .navigationBarTitleDisplayMode(.inline)
  }
}

struct ClearCacheSettingsSection: View {
  @State private var isClearing = false
  @State private var showClearCacheAlert = false
  @State private var clearCacheError: Error?
  @State private var showClearCacheError = false

  var body: some View {
    Section("Storage") {
      Button {
        showClearCacheAlert = true
      } label: {
        SettingsItem(icon: "eraser.fill", iconColor: .indigo, title: "Clear Cache") {
          if isClearing {
            ProgressView()
          }
        }
      }
      .disabled(isClearing)
    }
    .alert("Clear Cache", isPresented: $showClearCacheAlert) {
      Button("Cancel", role: .cancel) {}
      Button("Clear", role: .destructive, action: clearCache)
    } message: {
      Text("Removes downloaded photos, videos, voice messages, and files from this device. Chats and messages stay available.")
    }
    .alert("Error Clearing Cache", isPresented: $showClearCacheError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(clearCacheError?.localizedDescription ?? "An unknown error occurred")
    }
  }

  private func clearCache() {
    isClearing = true
    Task {
      do {
        try await FileCache.shared.clearCache()
        await ImagePrefetcher.shared.clearCache()
        isClearing = false
        ToastManager.shared.showToast(
          "Downloads cleared",
          description: "Chats and messages were not removed.",
          type: .success,
          systemImage: "checkmark.circle.fill"
        )
      } catch {
        clearCacheError = error
        showClearCacheError = true
        isClearing = false
      }
    }
  }
}
