import Auth
import GRDB
import InlineKit
import InlineUI
import Logger
import SwiftUI
import UIKit

private enum Tabs {
  case chats
  case archived

  var title: String {
    switch self {
      case .chats: "Chats"
      case .archived: "Archived"
    }
  }

  var icon: String {
    switch self {
      case .chats: "bubble.left.and.bubble.right.fill"
      case .archived: "archivebox.fill"
    }
  }
}

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
  @State private var selectedTab: Tabs = .chats

  var chatItems: [HomeChatItem] {
    home.chats.filter {
      selectedTab == .chats ?
        ($0.dialog.archived == nil || $0.dialog.archived == false) :
        $0.dialog.archived == true
    }.sorted { (item1: HomeChatItem, item2: HomeChatItem) in
      let pinned1 = item1.dialog.pinned ?? false
      let pinned2 = item2.dialog.pinned ?? false
      if pinned1 != pinned2 { return pinned1 }
      return item1.message?.date ?? item1.chat?.date ?? Date.now > item2.message?.date ?? item2.chat?.date ?? Date.now
    }
  }

  private func playTabHaptic() {
    let generator = UIImpactFeedbackGenerator(style: .soft)
    generator.impactOccurred(intensity: 0.5)
  }

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        Group {
          if !searchResults.isEmpty {
            searchResultsView
          } else if selectedTab == .archived {
            ArchivedChatsView(type: .home)
          } else {
            List {
              if selectedTab == .chats, !home.spaces.isEmpty {
                ScrollView(.horizontal) {
                  LazyHStack {
                    ForEach(home.spaces.sorted(by: { s1, s2 in
                      s1.space.date > s2.space.date
                    }), id: \.id) { spaceItem in
                      RectangleSpaceItem(spaceItem: spaceItem)
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
                      nav.push(.chat(peer: .user(id: item.user?.user.id ?? 0)))
                    } label: {
                      Label("Open Chat", systemImage: "bubble.left")
                    }
                  } preview: {
                    ChatView(peer: .user(id: item.user?.user.id ?? 0), preview: true)
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
      }
      .id(selectedTab)
    }
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden()
    .toolbar {
      HomeToolbarContent()
      ToolbarItem(placement: .bottomBar) {
        BottomTabBar(
          tabs: [Tabs.archived, .chats],
          selected: selectedTab,
          onSelect: { tab in
            playTabHaptic()

            withAnimation(.snappy(duration: 0.1)) {
              selectedTab = tab
            }
          }
        )
      }
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
      initalFetch()
    }
    .onAppear {
      initalFetch()
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

  @ViewBuilder
  func chatView(for item: HomeChatItem) -> some View {
    if let user = item.user {
      Button {
        nav.push(.chat(peer: .user(id: user.user.id)))
      } label: {
        DirectChatItem(props: Props(
          dialog: item.dialog,
          user: user,
          chat: item.chat,
          message: item.message,
          from: item.from?.user
        ))
      }
      .swipeActions(edge: .trailing, allowsFullSwipe: true) {
        Button(role: .destructive) {
          Task {
            try await dataManager.updateDialog(
              peerId: .user(id: user.user.id),
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
              peerId: .user(id: user.user.id),
              pinned: !(item.dialog.pinned ?? false)
            )
          }
        } label: {
          Image(systemName: item.dialog.pinned ?? false ? "pin.slash.fill" : "pin.fill")
        }
        .tint(.indigo)
      }
      .swipeActions(edge: .leading) {
        Button {
          Task {
            UnreadManager.shared.readAll(item.dialog.peerId, chatId: item.chat?.id ?? 0)
          }
        } label: {
          Image(systemName: "checkmark.message.fill")
        }
        .tint(.blue)
      }
    } else if let chat = item.chat {
      Button {
        nav.push(.chat(peer: .thread(id: chat.id)))
      } label: {
        ChatItemView(props: ChatItemProps(
          dialog: item.dialog,
          user: item.user,
          chat: chat,
          message: item.message,
          from: item.from,
          space: item.space
        ))
      }
      .swipeActions(edge: .trailing, allowsFullSwipe: true) {
        Button(role: .destructive) {
          Task {
            try await dataManager.updateDialog(
              peerId: .thread(id: chat.id),
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
              peerId: .thread(id: chat.id),
              pinned: !(item.dialog.pinned ?? false)
            )
          }
        } label: {
          Image(systemName: item.dialog.pinned ?? false ? "pin.slash.fill" : "pin.fill")
        }
        .tint(.indigo)
      }
      .swipeActions(edge: .leading) {
        Button {
          Task {
            UnreadManager.shared.readAll(item.dialog.peerId, chatId: chat.id)
          }
        } label: {
          Image(systemName: "checkmark.message.fill")
        }
        .tint(.blue)
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

private struct BottomTabBar: View {
  let tabs: [Tabs]
  let selected: Tabs
  let onSelect: (Tabs) -> Void
  var body: some View {
    HStack(spacing: 0) {
      ForEach(tabs, id: \.self) { tab in
        VStack {
          Image(systemName: tab == .chats ? "bubble.left.and.bubble.right.fill" : "archivebox.fill")
            .font(.system(size: 20, weight: .semibold))
            .foregroundColor(selected == tab ? Color(ThemeManager.shared.selected.accent) : Color(.systemGray4))
            .frame(width: 100, height: 36)
            .animation(.bouncy(duration: 0.08), value: selected == tab)
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity)
        .onTapGesture {
          onSelect(tab)
        }
      }
    }
    .frame(maxWidth: .infinity)
  }
}
