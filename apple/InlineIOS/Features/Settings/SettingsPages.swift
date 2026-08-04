import InlineKit
import SwiftUI
import TextProcessing
import Translation

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

  var body: some View {
    List {
      Section {
        NavigationLink {
          ThemeSelectionView()
        } label: {
          SettingsItem(icon: "paintpalette.fill", iconColor: .blue, title: "Theme")
        }
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
