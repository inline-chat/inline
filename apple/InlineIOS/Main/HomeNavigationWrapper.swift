import GRDB
import InlineKit
import InlineUI
import Logger
import SwiftUI

struct HomeNavigationWrapper: View {
  @EnvironmentObject private var nav: Navigation
  @EnvironmentObject private var api: ApiClient
  @EnvironmentObject private var dataManager: DataManager
  @Environment(\.appDatabase) private var database

  @State private var text = ""
  @State private var searchResults: [UserInfo] = []
  @State private var isSearchingState = false
  @StateObject private var searchDebouncer = Debouncer(delay: 0.3)

  var body: some View {
    TabView(selection: $nav.selectedTab) {
      NavigationStack(path: $nav.archivedPath) {
        ArchivedChatsView()
          .navigationDestination(for: Navigation.Destination.self) { destination in
            nav.destinationView(for: destination)
          }
          .navigationBarTitleDisplayMode(.inline)
          .navigationBarBackButtonHidden()
      }
      .tabItem {
        Label("Archived", systemImage: "archivebox.fill")
      }
      .tag(TabItem.archived)

      NavigationStack(path: $nav.chatsPath) {
        HomeView()
          .navigationDestination(for: Navigation.Destination.self) { destination in
            nav.destinationView(for: destination)
          }
          .navigationBarTitleDisplayMode(.inline)
          .navigationBarBackButtonHidden()
      }
      .tabItem {
        Label("Chats", systemImage: "bubble.left.and.bubble.right.fill")
      }
      .tag(TabItem.chats)

      NavigationStack(path: $nav.spacesPath) {
        SpacesView()
          .navigationDestination(for: Navigation.Destination.self) { destination in
            nav.destinationView(for: destination)
          }
          .navigationBarTitleDisplayMode(.inline)
          .navigationBarBackButtonHidden()
      }
      .tabItem {
        Label("Spaces", systemImage: "building.2.fill")
      }
      .tag(TabItem.spaces)
    }
    .tint(Color(ThemeManager.shared.selected.accent))
    .onChange(of: nav.selectedTab) { _ in
      nav.saveNavigationState()
    }
  }
}

#Preview {
  HomeNavigationWrapper()
    .environmentObject(Navigation.shared)
}
