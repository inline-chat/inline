import Auth
import GRDB
import InlineKit
import InlineUI
import Logger
import SwiftUI
import UIKit

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
  @EnvironmentObject private var tabsManager: TabsManager

  @Environment(\.realtime) var realtime
  @Environment(\.appDatabase) private var database
  @Environment(\.auth) private var auth
  @Environment(\.scenePhase) var scenePhase

  // MARK: - State

  @State private var text = ""
  @State private var searchResults: [UserInfo] = []
  @State private var isSearchingState = false
  @StateObject private var searchDebouncer = Debouncer(delay: 0.3)

  @State private var spacesPath: [Navigation.Destination] = []

  var chatItems: [HomeChatItem] {
    home.chats.filter {
      $0.dialog.archived != true
    }.sorted { (item1: HomeChatItem, item2: HomeChatItem) in
      let pinned1 = item1.dialog.pinned ?? false
      let pinned2 = item2.dialog.pinned ?? false
      if pinned1 != pinned2 { return pinned1 }
      return item1.message?.date ?? item1.chat?.date ?? Date.now > item2.message?.date ?? item2.chat?.date ?? Date.now
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      switch tabsManager.selectedTab {
        case .archived:
          ArchivedChatsView()
        case .chats:
          homeContent
            .searchable(text: $text, prompt: "Find")
            .onChange(of: text) { _, newValue in
              searchDebouncer.input = newValue
            }
            .onReceive(searchDebouncer.$debouncedInput) { debouncedValue in
              guard let value = debouncedValue else { return }
              searchUsers(query: value)
            }
            .toolbar {
              HomeToolbarContent()
            }
        case .spaces:
          SpacesView()
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden()
    .toolbar {
      ToolbarItemGroup(placement: .bottomBar) {
        Spacer()

        Button(action: { tabsManager.setSelectedTab(.archived) }) {
          Image(systemName: "archivebox.fill")
            .font(.body)
            .foregroundColor(tabsManager.selectedTab == .archived ? Color(ThemeManager.shared.selected.accent) : .gray)
        }

        Spacer()

        Button(action: { tabsManager.setSelectedTab(.chats) }) {
          Image(systemName: "bubble.left.and.bubble.right.fill")
            .font(.body)
            .foregroundColor(tabsManager.selectedTab == .chats ? Color(ThemeManager.shared.selected.accent) : .gray)
        }

        Spacer()

        Button(action: { tabsManager.setSelectedTab(.spaces) }) {
          Image(systemName: "building.2.fill")
            .font(.body)
            .foregroundColor(tabsManager.selectedTab == .spaces ? Color(ThemeManager.shared.selected.accent) : .gray)
        }

        Spacer()
      }
    }

    .task {
      initalFetch()
    }
    .onAppear {
      initalFetch()
    }
  }

  @ViewBuilder
  private var homeContent: some View {
    VStack(spacing: 0) {
      ZStack {
        Group {
          if !searchResults.isEmpty {
            searchResultsView
          } else {
            ChatListView(
              items: chatItems,
              isArchived: false,
              onItemTap: { item in
                if let user = item.user {
                  nav.push(.chat(peer: .user(id: user.user.id)))
                } else if let chat = item.chat {
                  nav.push(.chat(peer: .thread(id: chat.id)))
                }
              },
              onArchive: { item in
                Task {
                  if let user = item.user {
                    try await dataManager.updateDialog(
                      peerId: .user(id: user.user.id),
                      archived: true
                    )
                  } else if let chat = item.chat {
                    try await dataManager.updateDialog(
                      peerId: .thread(id: chat.id),
                      archived: true
                    )
                  }
                }
              },
              onPin: { item in
                Task {
                  if let user = item.user {
                    try await dataManager.updateDialog(
                      peerId: .user(id: user.user.id),
                      pinned: !(item.dialog.pinned ?? false)
                    )
                  } else if let chat = item.chat {
                    try await dataManager.updateDialog(
                      peerId: .thread(id: chat.id),
                      pinned: !(item.dialog.pinned ?? false)
                    )
                  }
                }
              },
              onRead: { item in
                Task {
                  UnreadManager.shared.readAll(item.dialog.peerId, chatId: item.chat?.id ?? 0)
                }
              }
            )
          }
        }
        .overlay {
          SearchedView(textIsEmpty: text.isEmpty, isSearchResultsEmpty: searchResults.isEmpty)
        }
      }
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

  private func initalFetch() {
    notificationHandler.setAuthenticated(value: true)

    Task.detached {
      do {
        try await Realtime.shared
          .invokeWithHandler(.getMe, input: .getMe(.init()))
      } catch {
        Log.shared.error("Error fetching getMe info", error: error)
      }

      do {
        try await Realtime.shared
          .invokeWithHandler(.getChats, input: .getChats(.init()))
      } catch {
        Log.shared.error("Error fetching getChats", error: error)
      }

      do {
        try await dataManager.getSpaces()
      } catch {
        Log.shared.error("Failed to getSpaces", error: error)
      }
    }
  }

  private var searchResultsView: some View {
    List(searchResults) { userInfo in
      Button(action: {
        navigateToUser(userInfo.user.id)
      }) {
        HStack(spacing: 9) {
          UserAvatar(userInfo: userInfo, size: 32)
          Text((userInfo.user.firstName ?? "") + " " + (userInfo.user.lastName ?? ""))
            .fontWeight(.medium)
            .foregroundColor(.primary)
        }
      }
    }
    .listStyle(.plain)
  }

  private func navigateToUser(_ userId: Int64) {
    Task {
      do {
        let peer = try await dataManager.createPrivateChat(userId: userId)
        nav.push(.chat(peer: peer))
      } catch {
        Log.shared.error("Failed to create chat", error: error)
      }
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
