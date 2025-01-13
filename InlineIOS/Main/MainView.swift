import GRDB
import InlineKit
import InlineUI
import SwiftUI

/// The main view of the application showing spaces and direct messages

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

  @Environment(\.appDatabase) private var database
  @Environment(\.scenePhase) private var scene
  @Environment(\.auth) private var auth

  @EnvironmentStateObject var root: RootData
  @EnvironmentStateObject private var spaceList: SpaceListViewModel
  @EnvironmentStateObject private var home: HomeViewModel

  // MARK: - State

  enum Tab: Int {
    case chats
    case spaces
  }

  @AppStorage("mainViewSelectedTab") private var selectedTab = Tab.chats

  @State private var text = ""
  @State private var searchResults: [User] = []
  @State private var isSearching = false
  @StateObject private var searchDebouncer = Debouncer(delay: 0.3)

  var user: User? {
    root.currentUser
  }

  // MARK: - Initialization

  init() {
    _root = EnvironmentStateObject { env in
      RootData(db: env.appDatabase, auth: Auth.shared)
    }
    _spaceList = EnvironmentStateObject { env in
      SpaceListViewModel(db: env.appDatabase)
    }
    _home = EnvironmentStateObject { env in
      HomeViewModel(db: env.appDatabase)
    }
  }

  // MARK: - Body

  var body: some View {
    VStack {
      switch selectedTab {
      case .chats:
        chatsTab
      case .spaces:
        spacesTab
      }
    }
    .background(Color(.systemBackground))
    .searchable(text: $text, prompt: "Search in users and spaces")
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
  var spacesTab: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 26) {
        tabbar
        ForEach(spaceList.spaceItems) { space in
          Button {
            nav.push(.space(id: space.space.id))
          } label: {
            SpaceRowView(spaceItem: space)
          }
        }
      }
      .padding(.horizontal, 16)
    }
  }

  @ViewBuilder
  var chatsTab: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 26) {
        tabbar
        ForEach(
          home.chats.sorted { chat1, chat2 in
            let pinned1 = chat1.dialog.pinned ?? false
            let pinned2 = chat2.dialog.pinned ?? false
            if pinned1 != pinned2 { return pinned1 }
            return chat1.message?.date ?? chat1.chat?.date ?? Date() > chat2.message?.date ?? chat2
              .chat?.date ?? Date()
          }
        ) { chat in
          Button {
            nav.push(.chat(peer: .user(id: chat.user.id)))
          } label: {
            ChatRowView(item: .home(chat))
          }
          .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
              Task {
                try await dataManager.updateDialog(
                  peerId: .user(id: chat.user.id),
                  pinned: !(chat.dialog.pinned ?? false)
                )
              }
            } label: {
              Image(systemName: chat.dialog.pinned ?? false ? "pin.slash.fill" : "pin.fill")
            }
          }
          .tint(.indigo)
        }
      }
      .padding(.horizontal, 16)
    }
    .animation(.default, value: home.chats)
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
      Log.shared.error("Failed to getPrivateChats", error: error)
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

  @ViewBuilder
  var tabbar: some View {
    HStack {
      Button {
        withAnimation {
          selectedTab = .chats
        }
      } label: {
        ZStack {
          Capsule()
            .fill(selectedTab == .chats ? ColorManager.shared.swiftUIColor.opacity(0.1) : Color.gray.opacity(0.1))
            .frame(height: 36)
          Text("Chats")
            .font(.callout)
            .foregroundColor(selectedTab == .chats ? ColorManager.shared.swiftUIColor : .secondary)
            .padding(.horizontal, 12)
        }
      }

      Button {
        withAnimation {
          selectedTab = .spaces
        }
      } label: {
        ZStack {
          Capsule()
            .fill(selectedTab == .spaces ? ColorManager.shared.swiftUIColor.opacity(0.1) : Color.gray.opacity(0.1))
            .frame(height: 36)
          Text("Spaces")
            .font(.callout)
            .foregroundColor(selectedTab == .spaces ? ColorManager.shared.swiftUIColor : .secondary)
            .padding(.horizontal, 12)
        }
      }
    }
    .fixedSize()
  }

  var toolbarContent: some ToolbarContent {
    Group {
      ToolbarItem(id: "UserAvatar", placement: .topBarLeading) {
        HStack {
          if let user = user {
            UserAvatar(user: user, size: 26)
              .padding(.trailing, 4)
          }
          VStack(alignment: .leading) {
            Text(user?.firstName ?? user?.lastName ?? user?.email ?? "User")
              .font(.title3)
              .fontWeight(.semibold)
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
            let user = User(
              id: apiUser.id,
              email: apiUser.email,
              firstName: apiUser.firstName,
              lastName: apiUser.lastName,
              username: apiUser.username
            )
            try user.save(db)
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
}

private enum CombinedItem: Identifiable {
  case space(SpaceItem)
  case chat(HomeChatItem)

  var id: Int64 {
    switch self {
    case .space(let space): return space.id
    case .chat(let chat): return chat.user.id
    }
  }

  var date: Date {
    switch self {
    case .space(let space): return space.space.date
    case .chat(let chat): return chat.message?.date ?? chat.chat?.date ?? Date()
    }
  }
}
