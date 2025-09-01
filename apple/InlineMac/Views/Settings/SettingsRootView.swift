import InlineKit
import InlineUI
import SwiftUI

struct SettingsRootView: View {
  @EnvironmentStateObject private var root: RootData
  @State private var selectedCategory: SettingsCategory = .general

  init() {
    _root = EnvironmentStateObject { env in
      RootData(db: env.appDatabase, auth: env.auth)
    }
  }

  @Environment(\.auth) var auth

  var body: some View {
    NavigationSplitView {
      SettingsSidebarView(selectedCategory: $selectedCategory)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
    } detail: {
      SettingsDetailView(category: selectedCategory)
    }
    .navigationTitle("Settings")
    .navigationSplitViewStyle(.balanced)
    .environmentObject(root)
  }
}

struct SettingsDetailView: View {
  let category: SettingsCategory

  var body: some View {
    Group {
      switch category {
        case .general:
          GeneralSettingsDetailView()
        case .appearance:
          AppearanceSettingsDetailView()
        case .account:
          AccountSettingsDetailView()
        case .notifications:
          NotificationsSettingsDetailView()
      }
    }
    .navigationTitle(category.title)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

#Preview {
  SettingsRootView()
    .previewsEnvironment(.populated)
}
