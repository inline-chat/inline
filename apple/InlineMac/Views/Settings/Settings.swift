import InlineKit
import InlineUI
import SwiftUI

struct SettingsView: View {
  @State private var selectedTab: Tabs = .general
  @Environment(\.auth) var auth

  enum Tabs: String, CaseIterable, Identifiable {
    case general = "General"
    case account = "Account"

    var id: String { rawValue }
  }

  var body: some View {
    TabView {
      GeneralSettingsView().tabItem {
        Label("General", systemImage: "gear")
      }
      .tag(Tabs.general)

      // Logged in only options
      if auth.isLoggedIn {
        AccountSettingsView().tabItem {
          Label("Account", systemImage: "person.crop.circle")
        }
        .tag(Tabs.account)
      }

      AppearanceView().tabItem {
        Label("Appearance", systemImage: "paintbrush")
      }
    }
    .frame(minWidth: 300)
    .scenePadding()
    .navigationTitle("Settings")
  }
}

struct GeneralSettingsView: View {
  @State var launchAtLogin: Bool = false

  var body: some View {
    Form {
      Toggle("Launch at Login", isOn: $launchAtLogin)
    }
  }
}

struct AppearanceView: View {
  @ObservedObject private var settings = AppSettings.shared
  init() {}

  var body: some View {
    Form {
      Picker("Sends with:", selection: $settings.sendsWithCmdEnter) {
        Text("Return").tag(false)
        Text("Command + Return").tag(true)
      }.pickerStyle(.inline)
    }
  }
}

struct AccountSettingsView: View {
  @EnvironmentObject private var mainWindowViewModel: MainWindowViewModel
  @EnvironmentStateObject private var root: RootData
  @Environment(\.logOut) private var logOut

  init() {
    _root = EnvironmentStateObject { env in
      RootData(db: env.appDatabase, auth: env.auth)
    }
  }

  var body: some View {
    HStack {
      UserProfile()
      Button("Log Out", role: .destructive) {
        Task {
          await logOut()
        }
      }
    }
    .frame(minWidth: 300)
    .environmentObject(root)
  }

  struct UserProfile: View {
    @EnvironmentObject private var root: RootData

    var body: some View {
      if let user = root.currentUser {
        HStack {
          UserAvatar(user: user, size: 32)

          VStack(alignment: .leading) {
            Text(user.fullName)
              .font(.body)
            Text(user.email ?? user.username ?? "")
              .font(.footnote)
          }
        }.padding(.trailing)
      }
    }
  }
}

#Preview {
  SettingsView()
    .previewsEnvironment(.populated)
    .environmentObject(MainWindowViewModel())
}
