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

  @State private var connection: String = ""
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
      if spaceList.spaces.isEmpty && home.chats.isEmpty {
        // TODO: Add empty state view
      } else {
        content
      }
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
}

private extension MainView {
  func initalFetch() async {
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

  @ViewBuilder
  var content: some View {
    let noUsersFound = searchResults.isEmpty
    let promptIsEmpty = text.isEmpty
    List {
      if !promptIsEmpty {
        Section {
          if isSearching {
            HStack {
              ProgressView()
              Text("Searching...")
                .foregroundColor(.secondary)
            }
          } else if noUsersFound {
            Text("No users found")
              .foregroundColor(.secondary)
          } else {
            ForEach(searchResults) { user in
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
          }
        }
      } else if !home.chats.isEmpty {
        chatsSection
      }
    }
    .listStyle(.plain)
  }

  func navigateToUser(_ user: User) {
    Task {
      do {
        let peer = try await dataManager.createPrivateChat(userId: user.id)
        nav.push(.chat(peer: peer))
      } catch {
        Log.shared.error("Failed to create chat", error: error)
      }
    }
  }

  var spacesSection: some View {
    Section(header: Text("Spaces")) {
      ForEach(spaceList.spaces.sorted(by: { $0.date > $1.date })) { space in
        SpaceRowView(space: space)
          .onTapGesture {
            nav.push(.space(id: space.id))
          }
      }
    }
  }

  var chatsSection: some View {
    Section {
      ForEach(
        home.chats.sorted(by: {
          let pinned0 = $0.dialog.pinned ?? false
          let pinned1 = $1.dialog.pinned ?? false
          if pinned0 != pinned1 {
            return pinned0
          }

          // Only sort by date if both are unpinned
          if !pinned0, !pinned1 {
            return $0.message?.date ?? $0.chat?.date ?? Date() > $1.message?.date ?? $1.chat?.date
              ?? Date()
          }
          // Keep original order for pinned items
          return false
        }),
        id: \.user.id
      ) { chat in
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
}

// MARK: - Helper Methods

extension MainView {
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
