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

  @State private var text = ""
  @State private var searchResults: [User] = []
  @State private var isSearching = false
  @StateObject private var searchDebouncer = Debouncer(delay: 0.3)

  var user: User? {
    root.currentUser
  }

  // MARK: - Computed Properties

  private var hasContent: Bool { !spaceList.spaceItems.isEmpty || !home.chats.isEmpty }

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
      if hasContent {
        content
      } else {}
    }
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
      ToolbarItem(placement: .bottomBar) {
        ConnectionStateIndicator(state: ws.connectionState)
          .animation(.smoothSnappy, value: ws.connectionState)
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden()

    .task {
      await initalFetch()
    }
  }

  // MARK: - Content Views

  @ViewBuilder
  private var content: some View {
    List {
      if !text.isEmpty {
        searchSection
      } else {
        combinedSection
      }
    }
    .listStyle(.plain)
    .animation(.default, value: home.chats)
  }

  @ViewBuilder
  private var searchSection: some View {
    Section {
      if isSearching {
        searchLoadingView
      } else if searchResults.isEmpty {
        Text("No users found")
          .foregroundColor(.secondary)
      } else {
        searchResultsList
      }
    }
  }

  private var searchLoadingView: some View {
    HStack {
      ProgressView()
      Text("Searching...")
        .foregroundColor(.secondary)
    }
  }

  private var searchResultsList: some View {
    ForEach(searchResults) { user in
      searchResultRow(for: user)
    }
  }

  private func searchResultRow(for user: User) -> some View {
    Button {
      navigateToUser(user)
    } label: {
      HStack(alignment: .top) {
        UserAvatar(user: user, size: 36)
          .padding(.trailing, 6)
          .overlay(alignment: .bottomTrailing) {
            Circle()
              .fill(.green)
              .frame(width: 12, height: 12)
              .padding(.leading, -14)
          }

        VStack(alignment: .leading) {
          Text(user.firstName ?? "User")
            .fontWeight(.medium)
          if let username = user.username {
            Text("@\(username)")
              .font(.callout)
              .foregroundColor(.secondary)
          }
        }
        .padding(.top, -4)
      }
    }
  }

  private var combinedSection: some View {
    Section {
      ForEach(getCombinedItems(), id: \.id) { item in
        combinedItemRow(for: item)
      }
    }
  }

  private func combinedItemRow(for item: CombinedItem) -> some View {
    switch item {
    case .space(let space):
      return spaceRow(for: space)
    case .chat(let chat):
      return chatRow(for: chat)
    }
  }

  // MARK: - Helper Methods

  private func getCombinedItems() -> [CombinedItem] {
    let sortedChats = home.chats.sorted { chat1, chat2 in
      let pinned1 = chat1.dialog.pinned ?? false
      let pinned2 = chat2.dialog.pinned ?? false
      if pinned1 != pinned2 { return pinned1 }
      return chat1.message?.date ?? chat1.chat?.date ?? Date() > chat2.message?.date ?? chat2.chat?.date ?? Date()
    }.map { CombinedItem.chat($0) }

    let spaceItems = spaceList.spaceItems.map { CombinedItem.space($0) }

    return sortedChats + spaceItems
  }

  private func spaceRow(for space: SpaceItem) -> some View {
    Button(role: .destructive) {
      nav.push(.space(id: space.space.id))
    } label: {
      SpaceRowView(spaceItem: space)
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      if let creator = space.space.creator, creator == true {
        Button(role: .destructive) {
          Task { try await dataManager.deleteSpace(spaceId: space.space.id) }
        } label: {
          Image(systemName: "trash")
        }
      } else {
        Button(role: .destructive) {
          Task { try await dataManager.leaveSpace(spaceId: space.space.id) }
        } label: {
          Image(systemName: "exit")
        }
      }
    }
    .tint(.red)
  }

  private func chatRow(for chat: HomeChatItem) -> some View {
    Button(role: .destructive) {
      nav.push(.chat(peer: .user(id: chat.user.id)))
    } label: {
      ChatRowView(item: chat)
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
    .listRowBackground(chat.dialog.pinned ?? false ? Color(.systemGray6).opacity(0.5) : .clear)
  }

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
          if let user = user {
            UserAvatar(user: user, size: 26)
              .padding(.trailing, 4)
          }
          VStack(alignment: .leading) {
            Text(user?.firstName ?? user?.lastName ?? user?.email ?? "User")
              .font(.title3)
              .fontWeight(.semibold)
          }
          .animation(.smoothSnappy, value: ws.connectionState)
        }
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
