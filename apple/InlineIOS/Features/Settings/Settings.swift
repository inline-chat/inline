import Auth
import GRDBQuery
import InlineKit
import SwiftUI
import TextProcessing

struct SettingsView: View {
  let onSelectSpace: (Int64) -> Void

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
          title: "Privacy",
          systemImage: "hand.raised.fill",
          color: .blue,
          destination: PrivacySettingsView()
        )
        SettingsNavigationRow(
          title: "Data & Storage",
          systemImage: "externaldrive.fill",
          color: .indigo,
          destination: DataStorageSettingsView()
        )
        SettingsNavigationRow(
          title: "Connectors",
          systemImage: "app.connected.to.app.below.fill",
          color: .purple,
          destination: ConnectorsView()
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
        if SettingsBuildAudience.showsDebugTools {
          SettingsNavigationRow(
            title: "Debug",
            systemImage: "ladybug.fill",
            color: .green,
            destination: DebugView()
          )
        }
      }

      Section {
        SettingsNavigationRow(
          title: "Help",
          systemImage: "questionmark.circle.fill",
          color: .blue,
          destination: HelpSettingsView(onSelectSpace: onSelectSpace)
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

      ToolbarItem(placement: .principal) {
        Text("Settings")
          .font(.headline)
      }
    }
  }

  private func dismissSettings() {
    router.dismissSheet()
    dismiss()
  }
}

enum SettingsBuildAudience {
  static var showsDebugTools: Bool {
    #if DEBUG || DEBUG_BUILD
    true
    #else
    Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    #endif
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

#Preview("Settings") {
  SettingsView(onSelectSpace: { _ in })
    .environmentObject(RootData(db: AppDatabase.empty(), auth: Auth.shared))
    .environmentObject(OnboardingNavigation())
    .environmentObject(MainViewRouter())
    .environmentObject(FileUploadViewModel())
    .environmentObject(INUserSettings.current.notification)
    .environment(Router(initialTab: .chats))
}
