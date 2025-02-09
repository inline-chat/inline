import GRDB
import InlineKit
import InlineUI
import SwiftUI

/// The main view of the application showing spaces and direct messages
enum TabType {
  case spaces, chats
}

struct MainView: View {
  // MARK: - Environment

  @EnvironmentObject private var nav: Navigation
  @EnvironmentObject private var onboardingNav: OnboardingNavigation
  @EnvironmentObject private var api: ApiClient
  @EnvironmentObject private var ws: WebSocketManager
  @EnvironmentObject private var dataManager: DataManager
  @EnvironmentObject private var userData: UserData
  @EnvironmentObject private var notificationHandler: NotificationHandler
  @EnvironmentObject private var mainViewRouter: MainViewRouter
  @EnvironmentObject private var home: HomeViewModel

  @Environment(\.appDatabase) private var database
  @Environment(\.scenePhase) private var scene
  @Environment(\.auth) private var auth
  @Environment(\.scenePhase) var scenePhase

  @EnvironmentStateObject var root: RootData
  @EnvironmentStateObject private var spaceList: SpaceListViewModel

  // MARK: - State

  @State private var text = ""
  @State private var searchResults: [User] = []
  @State private var isSearching = false
  @StateObject private var searchDebouncer = Debouncer(delay: 0.3)
  @State private var selectedTab: TabType = .chats

  var user: User? {
    root.currentUserInfo?.user
  }

  // MARK: - Initialization

  init() {
    _root = EnvironmentStateObject { env in
      RootData(db: env.appDatabase, auth: Auth.shared)
    }
    _spaceList = EnvironmentStateObject { env in
      SpaceListViewModel(db: env.appDatabase)
    }
  }

  // MARK: - Body

  var body: some View {
    VStack(spacing: 0) {
      // Custom tab bar
      HStack(spacing: 8) {
        TabButton(title: "Chats", type: .chats, selectedTab: $selectedTab)
        TabButton(title: "Spaces", type: .spaces, selectedTab: $selectedTab)
        Spacer()
      }
      .padding(.horizontal)
      .padding(.bottom, 8)

      // Existing content with filtering based on selected tab
      if !searchResults.isEmpty {
        searchResultsView
      } else {
        List {
          // Archived chats section - only show in chats tab
          if selectedTab == .chats, !home.chats.filter({ $0.dialog.archived == true }).isEmpty {
            Button {
              nav.push(.archivedChats)
            } label: {
              HStack {
                Circle()
                  .fill(
                    LinearGradient(
                      colors: [
                        Color(.systemGray6),
                        Color(.systemGray5),
                      ], startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                  )
                  .frame(width: 42, height: 42)
                  .overlay(alignment: .center) {
                    Image(systemName: "tray.full.fill")
                      .foregroundColor(.secondary)
                      .font(.title3)
                  }
                  .padding(.trailing, 6)
                let archivedCount = home.chats.filter { $0.dialog.archived == true }.count
                VStack(alignment: .leading) {
                  Text("Archived Chats")
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                  Text("\(archivedCount) chats")
                    .contentTransition(.numericText())
                    .animation(.default, value: archivedCount)
                    .font(.callout)
                    .foregroundColor(.secondary)
                }
                Spacer()
              }
              .frame(height: 48)
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
            }
          }

          ForEach(filteredItems) { item in
            switch item {
              case let .space(spaceItem):
                Button {
                  nav.push(.space(id: spaceItem.id))
                } label: {
                  SpaceRowView(spaceItem: spaceItem)
                }

              case let .chat(chatItem):
                Button {
                  nav.push(.chat(peer: .user(id: chatItem.user.id)))
                } label: {
                  ChatRowView(item: .home(chatItem))
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                  Button(role: .destructive) {
                    Task {
                      try await dataManager.updateDialog(
                        peerId: .user(id: chatItem.user.id),
                        archived: true
                      )
                    }
                  } label: {
                    Image(systemName: "tray.and.arrow.down.fill")
                  }
                  .tint(Color(.systemGray2))

                  Button {
                    Task {
                      try await dataManager.updateDialog(
                        peerId: .user(id: chatItem.user.id),
                        pinned: !(chatItem.dialog.pinned ?? false)
                      )
                    }
                  } label: {
                    Image(systemName: chatItem.dialog.pinned ?? false ? "pin.slash.fill" : "pin.fill")
                  }
                  .tint(.indigo)
                }
                .listRowBackground(chatItem.dialog.pinned ?? false ? Color(.systemGray6).opacity(0.5) : Color.clear)
            }
          }
        }
        .listStyle(.plain)
//        .animation(.default, value: home.chats)
      }
    }
    .background(Color(.systemBackground))
    .searchable(text: $text, prompt: "Search in users")
    .onAppear {
      markAsOnline()
    }
    .onChange(of: scenePhase) { phase in
      if phase == .active {
        Task {
          ws.ensureConnected()
          markAsOnline()
        }
      } else if phase == .inactive {
        markAsOffline()
      } else if phase == .background {
        markAsOffline()
      }
    }
    .onChange(of: text) { _, newValue in
      searchDebouncer.input = newValue
    }
    .onReceive(searchDebouncer.$debouncedInput) { debouncedValue in
      guard let value = debouncedValue else { return }
      searchUsers(query: value)
    }
    .toolbar {
      toolbarContent
    }
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden()
    .task {
      await initalFetch()
    }
  }

  // MARK: - Content Views

  @ViewBuilder
  var searchResultsView: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 12) {
        ForEach(searchResults) { user in
          Button {
            navigateToUser(user)
          } label: {
            HStack {
              UserAvatar(user: user, size: 36)
                .padding(.trailing, 6)

              VStack(alignment: .leading) {
                Text((user.firstName ?? "") + (user.lastName ?? ""))
                  .fontWeight(.medium)
                  .foregroundColor(.primary)

                Text("@\(user.username ?? "")")
                  .foregroundColor(.secondary)
              }
            }
          }
        }
      }
      .padding(.horizontal, 16)
    }
  }

  // MARK: - Helper Methods

  private func initalFetch() async {
    notificationHandler.setAuthenticated(value: true)

    do {
      _ = try await dataManager.fetchMe()
    } catch {
      Log.shared.error("Failed to getMe", error: error)
      return
    }

    // Continue with existing tasks if user exists
    do {
      try await dataManager.getPrivateChats()
    } catch {
      Log.shared.error("Failed to getPrivateChats", error: error)
    }

    do {
      try await dataManager.getSpaces()
    } catch {
      Log.shared.error("Failed to getSpaces", error: error)
    }
  }

  private func navigateToUser(_ user: User) {
    Task {
      do {
        let peer = try await dataManager.createPrivateChat(userId: user.id)
        nav.push(.chat(peer: peer))
      } catch {
        Log.shared.error("Failed to create chat", error: error)
      }
    }
  }

  var toolbarContent: some ToolbarContent {
    Group {
      ToolbarItem(id: "UserAvatar", placement: .topBarLeading) {
        HStack {
          if let user {
            UserAvatar(user: user, size: 26)
              .padding(.trailing, 4)
          }
          HStack(alignment: .center, spacing: 4) {
            Text(user?.firstName ?? user?.lastName ?? user?.email ?? "User")
              .font(.title3)
              .fontWeight(.semibold)
            Text("(you)")
              .font(.body)
              .fontWeight(.semibold)
              .foregroundStyle(.secondary)
          }
        }
      }

      ToolbarItem(id: "status", placement: .principal) {
        ConnectionStateIndicator(state: ws.connectionState)
      }

      ToolbarItem(id: "MainToolbarTrailing", placement: .topBarTrailing) {
        HStack(spacing: 2) {
          Button {
            nav.push(.createSpace)
          } label: {
            Image(systemName: "plus")
              .tint(Color.secondary)
              .frame(width: 38, height: 38)
              .contentShape(Rectangle())
          }
          Button {
            nav.push(.settings)
          } label: {
            Image(systemName: "gearshape")
              .tint(Color.secondary)
              .frame(width: 38, height: 38)
              .contentShape(Rectangle())
          }
        }
      }
    }
  }

  fileprivate func handleLogout() {
    auth.logOut()
    do {
      try AppDatabase.clearDB()
    } catch {
      Log.shared.error("Failed to delete DB and logout", error: error)
    }
    nav.popToRoot()
  }

  private func searchUsers(query: String) {
    guard !query.isEmpty else {
      searchResults = []
      isSearching = false
      return
    }

    isSearching = true
    Task {
      do {
        let result = try await api.searchContacts(query: query)

        try await database.dbWriter.write { db in
          for apiUser in result.users {
            try apiUser.saveFull(db)
          }
        }

        try await database.reader.read { db in
          searchResults =
            try User
              .filter(Column("username").like("%\(query.lowercased())%"))
              .fetchAll(db)
        }

        await MainActor.run {
          isSearching = false
        }
      } catch {
        Log.shared.error("Error searching users", error: error)
        await MainActor.run {
          searchResults = []
          isSearching = false
        }
      }
    }
  }

  private func markAsOnline() {
    Task {
      try? await dataManager.updateStatus(online: true)
    }
  }

  private func markAsOffline() {
    Task {
      try? await dataManager.updateStatus(online: false)
    }
  }

  var combinedItems: [CombinedItem] {
    var items: [CombinedItem] = []

    // Add non-archived chats
    items.append(
      contentsOf: home.chats
        .filter { $0.dialog.archived == nil || $0.dialog.archived == false }
        .map { .chat($0) }
    )

    // Add spaces
    items.append(contentsOf: spaceList.spaceItems.map { .space($0) })

    // Sort items: pinned chats first, then spaces, then unpinned chats
    return items.sorted { item1, item2 in
      let pinned1: Bool
      let pinned2: Bool

      switch (item1, item2) {
        case let (.chat(chat1), .chat(chat2)):
          pinned1 = chat1.dialog.pinned ?? false
          pinned2 = chat2.dialog.pinned ?? false
          if pinned1 != pinned2 { return pinned1 }
          return item1.date > item2.date
        case let (.chat(chat), .space(_)):
          pinned1 = chat.dialog.pinned ?? false
          return pinned1 // if chat is pinned, it goes above space
        case let (.space(_), .chat(chat)):
          pinned2 = chat.dialog.pinned ?? false
          return !pinned2 // if chat is not pinned, space goes above
        case (.space, .space):
          return item1.date > item2.date
      }
    }
  }

  var filteredItems: [CombinedItem] {
    switch selectedTab {
      case .spaces:
        combinedItems.filter { item in
          if case .space = item { return true }
          return false
        }
      case .chats:
        combinedItems.filter { item in
          if case .chat = item { return true }
          return false
        }
    }
  }
}

enum CombinedItem2: Identifiable {
  case space(SpaceItem)
  case chat(HomeChatItem)

  var id: Int64 {
    switch self {
      case let .space(space): space.id
      case let .chat(chat): chat.user.id
    }
  }

  var date: Date {
    switch self {
      case let .space(space): space.space.date
      case let .chat(chat): chat.message?.date ?? chat.chat?.date ?? Date()
    }
  }
}

private struct TabButton: View {
  let title: String
  let type: TabType
  @Binding var selectedTab: TabType

  var body: some View {
    Button {
      let impact = UIImpactFeedbackGenerator(style: .light)
      impact.impactOccurred()

      withAnimation(.easeOut(duration: 0.1)) {
        selectedTab = type
      }
    } label: {
      Text(title)
        .foregroundColor(selectedTab == type ? Color(ColorManager.shared.swiftUIColor) : .secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
          Group {
            if selectedTab == type {
              Color(ColorManager.shared.swiftUIColor).opacity(0.2).clipShape(Capsule())
            } else {
              Color.clear
            }
          }
        )
    }
  }
}
