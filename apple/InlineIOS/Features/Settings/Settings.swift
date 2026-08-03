import Auth
import GRDBQuery
import InlineKit
import SwiftUI
import TextProcessing

struct SettingsView: View {
  @Query(CurrentUser()) var currentUser: UserInfo?
  @Environment(Router.self) private var router
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    List {
      Section {
        NavigationLink {
          ExperimentalProfileView()
        } label: {
          if let currentUser {
            ProfileRow(userInfo: currentUser)
          } else {
            SettingsItem(icon: "person.crop.circle", iconColor: .blue, title: "Account")
          }
        }
      }

      Section {
        SettingsNavigationRow(
          title: "General",
          systemImage: "gear",
          color: .gray,
          destination: GeneralSettingsView()
        )
        SettingsNavigationRow(
          title: "Appearance",
          systemImage: "paintbrush.fill",
          color: .blue,
          destination: AppearanceSettingsView()
        )
        SettingsNavigationRow(
          title: "Notifications",
          systemImage: "bell.fill",
          color: .red,
          destination: NotificationsSettingsView()
        )
        SettingsNavigationRow(
          title: "Data & Storage",
          systemImage: "externaldrive.fill",
          color: .indigo,
          destination: DataStorageSettingsView()
        )
        SettingsNavigationRow(
          title: "Active Sessions",
          systemImage: "laptopcomputer.and.iphone",
          color: .blue,
          destination: AccountSessionsSettingsView()
        )
      }

      Section {
        SettingsNavigationRow(
          title: "Bots",
          systemImage: "cpu",
          color: .purple,
          destination: BotsSettingsView()
        )
      }

      Section {
        SettingsNavigationRow(
          title: "Experimental",
          systemImage: "testtube.2",
          color: .orange,
          destination: ExperimentalView()
        )
        SettingsNavigationRow(
          title: "Debug",
          systemImage: "ladybug.fill",
          color: .green,
          destination: DebugView()
        )
      }

      Section {
        SettingsNavigationRow(
          title: "About Inline",
          systemImage: "info.circle.fill",
          color: .blue,
          destination: AboutSettingsView()
        )
      } footer: {
        SettingsReleaseSummary()
          .frame(maxWidth: .infinity)
          .padding(.top, 8)
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Settings")
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(true)
    .hideTabBarIfNeeded()
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button {
          dismissSettings()
        } label: {
          Image(systemName: "xmark")
            .fontWeight(.semibold)
        }
      }
    }
  }

  private func dismissSettings() {
    router.dismissSheet()
    dismiss()
  }
}

extension EmojiSkinTone {
  var settingsLabel: LocalizedStringResource {
    switch self {
    case .standard:
      "👋 Default"
    case .light:
      "👋🏻 Light"
    case .mediumLight:
      "👋🏼 Medium-Light"
    case .medium:
      "👋🏽 Medium"
    case .mediumDark:
      "👋🏾 Medium-Dark"
    case .dark:
      "👋🏿 Dark"
    }
  }
}

struct AutoDownloadSettingsView: View {
  @ObservedObject private var autoDownload = INUserSettings.current.autoDownload

  var body: some View {
    List {
      Section("Auto-Download") {
        thresholdRow(
          icon: "photo.on.rectangle.angled",
          iconColor: .blue,
          title: "Media",
          value: binding(\.mediaMaxMB)
        )
        thresholdRow(
          icon: "doc.fill",
          iconColor: .indigo,
          title: "Files",
          value: binding(\.fileMaxMB)
        )
        thresholdRow(
          icon: "waveform",
          iconColor: .red,
          title: "Voice Messages",
          value: binding(\.voiceMaxMB)
        )
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Auto-Download")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func binding(_ keyPath: ReferenceWritableKeyPath<AutoDownloadSettingsManager, Int>) -> Binding<Int> {
    Binding {
      autoDownload[keyPath: keyPath]
    } set: { value in
      autoDownload[keyPath: keyPath] = AutoDownloadSettingsManager.clamped(value)
    }
  }

  private func thresholdRow(
    icon: String,
    iconColor: Color,
    title: String,
    value: Binding<Int>
  ) -> some View {
    SettingsItem(
      icon: icon,
      iconColor: iconColor,
      title: title
    ) {
      HStack(spacing: 8) {
        Text(thresholdLabel(value.wrappedValue))
          .foregroundStyle(.secondary)
          .monospacedDigit()

        Stepper("", value: value, in: 0 ... AutoDownloadSettingsManager.maxAllowedMB, step: 1)
          .labelsHidden()
          .accessibilityLabel(title)
          .accessibilityValue(thresholdLabel(value.wrappedValue))
      }
    }
  }

  private func thresholdLabel(_ value: Int) -> String {
    value <= 0 ? "Off" : "\(value) MB"
  }
}

#Preview("Settings") {
  SettingsView()
    .environmentObject(RootData(db: AppDatabase.empty(), auth: Auth.shared))
    .environmentObject(OnboardingNavigation())
    .environmentObject(MainViewRouter())
    .environmentObject(FileUploadViewModel())
    .environmentObject(INUserSettings.current.notification)
    .environment(Router(initialTab: .chats))
}
