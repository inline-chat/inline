import GRDB
import InlineKit
import InlineUI
import SwiftUI

struct HomeViw: View {
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

  var user: User? {
    root.currentUserInfo?.user
  }

  var combinedItems: [CombinedItem] {
    var items: [CombinedItem] = []

    // Add non-archived chats
    items.append(
      contentsOf: home.chats
        .filter { $0.dialog.archived == nil || $0.dialog.archived == false }
        .map { .chat($0) }
    )

    // Add spaces with their full data
    for space in spaceList.fullSpaces {
      let chats = spaceList.spaceChats[space.id] ?? []
      let spaceItem = SpaceItem(
        space: space,
        members: [],
        chats: chats
      )
      items.append(.space(spaceItem))
    }

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
          return !pinned1
        case let (.space(_), .chat(chat)):
          pinned2 = chat.dialog.pinned ?? false
          return !pinned2 // if chat is not pinned, space goes above
        case (.space, .space):
          return item1.date > item2.date
      }
    }
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

  var body: some View {
    Group {
      if !searchResults.isEmpty {
        searchResultsView
      } else {
        List {
          ForEach(combinedItems, id: \.id) { item in
            chatOrSpaceView(for: item)
              .listRowInsets(.init(
                top: 9,
                leading: 16,
                bottom: 2,
                trailing: 0
              ))
          }
        }
        .listStyle(.plain)
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $text, prompt: "Find")
    .onChange(of: text) { _, newValue in
      searchDebouncer.input = newValue
    }
    .onReceive(searchDebouncer.$debouncedInput) { debouncedValue in
      guard let value = debouncedValue else { return }
      searchUsers(query: value)
    }
    .toolbar {
      HomeToolbarContent(user: user)
    }
    .onAppear {
      Task {
        do {
          try await dataManager.getSpaces()
        } catch {
          Log.shared.error("Failed to getSpaces", error: error)
        }
      }
    }
    .task {
      await initalFetch()
    }
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

  private func initalFetch() async {
    notificationHandler.setAuthenticated(value: true)
    spaceList.start()
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
  var searchResultsView: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 12) {
        ForEach(searchResults) { user in

          HStack(spacing: 9) {
            UserAvatar(user: user, size: 38)

            VStack(alignment: .leading, spacing: 0) {
              Text((user.firstName ?? "") + " " + (user.lastName ?? ""))
                .fontWeight(.medium)
                .foregroundColor(.primary)

              Text(user.username ?? "")
                .foregroundColor(.secondary)
            }

            Spacer()
            Button {
              navigateToUser(user)
            } label: {
              Circle()
                .fill(Color(.systemGray5))
                .frame(width: 36, height: 36)
                .overlay {
                  Image(systemName: "message.fill")
                    .foregroundColor(ColorManager.shared.swiftUIColor)
                }
            }
          }
        }
      }
      .padding(.horizontal, 16)
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
  func chatOrSpaceView(for item: CombinedItem) -> some View {
    switch item {
      case let .chat(chatItem):
        if chatItem.chat?.peerUserId != nil {
          Button {
            nav.push(.chat(peer: .user(id: chatItem.user.id)))
          } label: {
            DirectChatItem(props: Props(
              dialog: chatItem.dialog,
              user: chatItem.user,
              chat: chatItem.chat,
              message: chatItem.message,
              from: chatItem.from
            ))
          }
        } else {
          EmptyView()
        }
      case let .space(spaceItem):
        Button {
          nav.push(.space(id: spaceItem.space.id))
        } label: {
          SpaceItemView(props: SpaceItemProps(
            space: spaceItem.space,
            members: spaceItem.members,
            chats: spaceItem.chats
          ))
        }
    }
  }
}
