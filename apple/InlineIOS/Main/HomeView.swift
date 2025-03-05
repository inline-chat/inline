import Auth
import GRDB
import InlineKit
import InlineUI
import Logger
import SwiftUI

struct HomeView: View {
  // MARK: - Environment

  @EnvironmentObject private var nav: Navigation
  @EnvironmentObject private var onboardingNav: OnboardingNavigation
  @EnvironmentObject private var api: ApiClient
  @EnvironmentObject private var dataManager: DataManager
  @EnvironmentObject private var notificationHandler: NotificationHandler
  @EnvironmentObject private var mainViewRouter: MainViewRouter
  @EnvironmentObject private var home: HomeViewModel
  @EnvironmentObject var data: DataManager

  @Environment(\.realtime) var realtime
  @Environment(\.appDatabase) private var database
  @Environment(\.auth) private var auth
  @Environment(\.scenePhase) var scenePhase

  // MARK: - State

  @State private var text = ""
  @State private var searchResults: [UserInfo] = []
  @State private var isSearchingState = false
  @StateObject private var searchDebouncer = Debouncer(delay: 0.3)

  var chatItems: [HomeChatItem] {
    home.chats.filter {
      $0.dialog.archived == nil || $0.dialog.archived == false
    }.sorted { (item1: HomeChatItem, item2: HomeChatItem) in
      let pinned1 = item1.dialog.pinned ?? false
      let pinned2 = item2.dialog.pinned ?? false
      if pinned1 != pinned2 { return pinned1 }
      return item1.message?.date ?? item1.chat?.date ?? Date.now > item2.message?.date ?? item2.chat?.date ?? Date.now
    }
  }

  var body: some View {
    Group {
      if !searchResults.isEmpty {
        searchResultsView
      } else {
        List {
          if !home.spaces.isEmpty {
            ScrollView(.horizontal) {
              LazyHStack {
                ForEach(home.spaces.sorted(by: { s1, s2 in
                  s1.space.date > s2.space.date
                }), id: \.id) { space in
                  RectangleSpaceItem(spaceItem: space)
                }
              }
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .listRowInsets(.init(
              top: 0,
              leading: 0,
              bottom: 16,
              trailing: 0
            ))
            .listRowSeparator(.hidden)
          }
          if !home.chats.filter({ $0.dialog.archived == true }).isEmpty {
            Button {
              nav.push(.archivedChats)
            } label: {
              HStack(alignment: .top, spacing: 14) {
                Circle()
                  .fill(
                    LinearGradient(
                      colors: [
                        Color(.systemGray3).adjustLuminosity(by: 0.2),
                        Color(.systemGray5).adjustLuminosity(by: 0),
                      ],
                      startPoint: .top,
                      endPoint: .bottom
                    )
                  )
                  .frame(width: 58, height: 58)
                  .overlay {
                    Image(systemName: "tray.full.fill")
                      .font(.title)
                      .foregroundColor(.secondary)
                  }

                VStack(alignment: .leading, spacing: 1) {
                  Text("Archived Chats")
                    .font(.customTitle())
                    .foregroundColor(.primary)
                  Text("\(home.chats.filter { $0.dialog.archived == true }.count) chats")
                    .font(.customCaption())
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .contentTransition(.numericText())
                }
                .animation(.default, value: home.chats.filter { $0.dialog.archived == true }.count)
                Spacer()
              }
              .frame(height: 70)
              .frame(maxWidth: .infinity)
            }
            .listRowInsets(.init(
              top: 9,
              leading: 18,
              bottom: 2,
              trailing: 0
            ))
          }

          ForEach(chatItems, id: \.id) { item in
            chatView(for: item)

              .listRowInsets(.init(
                top: 9,
                leading: 16,
                bottom: 2,
                trailing: 0
              ))
              .contextMenu {
                Button {
                  nav.push(.chat(peer: .user(id: item.user.id)))
                } label: {
                  Label("Open Chat", systemImage: "bubble.left")
                }
              } preview: {
                ChatView(peer: .user(id: item.user.id), preview: true)
                  .frame(width: Theme.shared.chatPreviewSize.width, height: Theme.shared.chatPreviewSize.height)
                  .environmentObject(nav)
                  .environmentObject(data)
                  .environment(\.realtime, realtime)
                  .environment(\.appDatabase, database)
              }
          }
        }
        .listStyle(.plain)
        .animation(.default, value: home.chats)
        .animation(.default, value: home.spaces)
      }
    }
    .overlay {
      SearchedView(textIsEmpty: text.isEmpty, isSearchResultsEmpty: searchResults.isEmpty)
    }

    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden()
    .toolbar {
      HomeToolbarContent()
    }
    .searchable(text: $text, prompt: "Find")
    .onChange(of: text) { _, newValue in
      searchDebouncer.input = newValue
    }
    .onReceive(searchDebouncer.$debouncedInput) { debouncedValue in
      guard let value = debouncedValue else { return }
      searchUsers(query: value)
    }
    .task {
      await initalFetch()
    }
  }

  private func searchUsers(query: String) {
    guard !query.isEmpty else {
      searchResults = []
      isSearchingState = false
      return
    }

    isSearchingState = true
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
              .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
              .asRequest(of: UserInfo.self)
              .fetchAll(db)
        }

        await MainActor.run {
          isSearchingState = false
        }
      } catch {
        Log.shared.error("Error searching users", error: error)
        await MainActor.run {
          searchResults = []
          isSearchingState = false
        }
      }
    }
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

  private var searchResultsView: some View {
    List(searchResults) { userInfo in
      Button(action: {
        navigateToUser(userInfo.user)
      }) {
        HStack(spacing: 9) {
          UserAvatar(userInfo: userInfo, size: 28)
          Text((userInfo.user.firstName ?? "") + " " + (userInfo.user.lastName ?? ""))
            .fontWeight(.medium)
            .foregroundColor(.primary)
        }
      }
    }
    .listStyle(.plain)
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
  func chatView(for item: HomeChatItem) -> some View {
    if item.chat?.peerUserId != nil {
      Button {
        nav.push(.chat(peer: .user(id: item.user.id)))
      } label: {
        DirectChatItem(props: Props(
          dialog: item.dialog,
          user: item.user,
          chat: item.chat,
          message: item.message,
          from: item.from
        ))
      }
      .swipeActions(edge: .trailing, allowsFullSwipe: true) {
        Button(role: .destructive) {
          Task {
            try await dataManager.updateDialog(
              peerId: .user(id: item.user.id),
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
              peerId: .user(id: item.user.id),
              pinned: !(item.dialog.pinned ?? false)
            )
          }
        } label: {
          Image(systemName: item.dialog.pinned ?? false ? "pin.slash.fill" : "pin.fill")
        }
        .tint(.indigo)
      }
      .swipeActions(edge: .leading, allowsFullSwipe: true) {
        Button(role: .destructive) {
          Task {
            UnreadManager.shared.readAll(item.dialog.peerId, chatId: item.chat?.id ?? 0)
          }
        } label: {
          Image(systemName: "checkmark.message.fill")
        }
        .tint(.blue)
      }
    } else {
      EmptyView()
    }
  }
}

extension UIViewController {
  var topmostPresentedViewController: UIViewController {
    if let presented = presentedViewController {
      return presented.topmostPresentedViewController
    }
    return self
  }
}

struct SearchedView: View {
  @Environment(\.isSearching) private var isSearching
  var textIsEmpty: Bool
  var isSearchResultsEmpty: Bool

  var body: some View {
    if isSearching {
      if textIsEmpty || isSearchResultsEmpty {
        VStack(spacing: 4) {
          Text("🔍")
            .font(.largeTitle)
            .foregroundColor(.primary)
            .padding(.bottom, 14)
          Text("Search for people")
            .font(.headline)
            .foregroundColor(.primary)
          Text("Type a username to find someone to chat with. eg. dena, mo")
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 45)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .transition(.opacity)
      }
    }
  }
}
