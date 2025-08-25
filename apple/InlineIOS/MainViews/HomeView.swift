import Auth
import GRDB
import InlineKit
import InlineUI
import Logger
import SwiftUI
import UIKit

enum SearchResult: Identifiable, Hashable {
  case localUser(User)
  case localThread(ThreadInfo)
  case globalUser(ApiUser)

  var id: String {
    switch self {
      case let .localUser(user):
        "local_user_\(user.id)"
      case let .localThread(threadInfo):
        "local_thread_\(threadInfo.chat.id)"
      case let .globalUser(user):
        "global_user_\(user.id)"
    }
  }
}

struct HomeView: View {
  // MARK: - Environment

  @EnvironmentObject private var onboardingNav: OnboardingNavigation
  @EnvironmentObject private var api: ApiClient
  @EnvironmentObject private var dataManager: DataManager
  @EnvironmentObject private var notificationHandler: NotificationHandler
  @EnvironmentObject private var mainViewRouter: MainViewRouter
  @EnvironmentObject private var home: HomeViewModel
  @EnvironmentObject var data: DataManager
  @EnvironmentObject private var tabsManager: TabsManager

  @Environment(\.realtime) var realtime
  @Environment(\.realtimeV2) var realtimeV2
  @Environment(\.appDatabase) private var database
  @Environment(\.auth) private var auth
  @Environment(\.scenePhase) var scenePhase
  @Environment(Router.self) private var router

  // MARK: - State

  @State private var text = ""
  @State private var globalSearchResults: [ApiUser] = []
  @State private var isSearchingState = false

  // Initialize local search with database from environment
  @State private var localSearch: HomeSearchViewModel?

  @State private var spacesPath: [Navigation.Destination] = []

  var chatItems: [HomeChatItem] {
    home.chats.filter {
      $0.dialog.archived != true
    }.sorted { (item1: HomeChatItem, item2: HomeChatItem) in
      let pinned1 = item1.dialog.pinned ?? false
      let pinned2 = item2.dialog.pinned ?? false
      if pinned1 != pinned2 { return pinned1 }
      return item1.lastMessage?.message.date ?? item1.chat?.date ?? Date.now > item2.lastMessage?.message.date ?? item2
        .chat?.date ?? Date.now
    }
  }

  var localSearchResults: [SearchResult] {
    guard let localResults = localSearch?.results else { return [] }

    var results: [SearchResult] = []
    for result in localResults {
      switch result {
        case let .user(user):
          results.append(.localUser(user))
        case let .thread(threadInfo):
          results.append(.localThread(threadInfo))
      }
    }

    // Sort local results by relevance to query
    return results.sorted { result1, result2 in
      let score1 = calculateRelevanceScore(for: result1, query: text)
      let score2 = calculateRelevanceScore(for: result2, query: text)
      return score1 > score2
    }
  }

  var mixedAndSortedSearchResults: [SearchResult] {
    var results: [SearchResult] = []

    // Add local results, separating users and threads
    if let localResults = localSearch?.results {
      for result in localResults {
        switch result {
          case let .user(user):
            results.append(.localUser(user))
          case let .thread(threadInfo):
            results.append(.localThread(threadInfo))
        }
      }
    }

    // Add global results
    results.append(contentsOf: globalSearchResults.map { .globalUser($0) })

    // Sort by relevance to query
    return results.sorted { result1, result2 in
      let score1 = calculateRelevanceScore(for: result1, query: text)
      let score2 = calculateRelevanceScore(for: result2, query: text)
      return score1 > score2
    }
  }

  var body: some View {
    homeContent
      .background(ThemeManager.shared.backgroundColorSwiftUI)
      .searchable(text: $text, prompt: "Find")
      .onChange(of: text) { _, newValue in
        searchUsers(query: newValue)
      }
      .toolbar {
        HomeToolbarContent()
      }
      .navigationBarTitleDisplayMode(.inline)
      .navigationBarBackButtonHidden()
      .task {
        // initalFetch()
      }
      .onAppear {
        initalFetch()
      }
      .navigationTitle("")
  }

  @ViewBuilder
  private var homeContent: some View {
    VStack(spacing: 0) {
      ZStack {
        Group {
          if !text.isEmpty {
            searchResultsView
          } else {
            ChatListView(
              items: chatItems,
              isArchived: false,
              onItemTap: { item in
                if let user = item.user {
                  router.push(.chat(peer: .user(id: user.user.id)))
                } else if let chat = item.chat {
                  router.push(.chat(peer: .thread(id: chat.id)))
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
              },
              onUnread: { item in
                Task {
                  do {
                    try await realtime.invokeWithHandler(.markAsUnread, input: .markAsUnread(.with {
                      $0.peerID = item.dialog.peerId.toInputPeer()
                    }))
                  } catch {
                    Log.shared.error("Failed to mark as unread", error: error)
                  }
                }
              }
            )
          }
        }
        .overlay {
          SearchedView(
            textIsEmpty: text.isEmpty,
            isSearchResultsEmpty: globalSearchResults.isEmpty && (localSearch?.results.count ?? 0) == 0
          )
        }
      }
    }
  }

  private func searchUsers(query: String) {
    guard !query.isEmpty else {
      globalSearchResults = []
      isSearchingState = false
      // Clear local search results as well
      if localSearch == nil {
        localSearch = HomeSearchViewModel(db: database)
      }
      localSearch?.search(query: "")
      return
    }

    // Always perform local search immediately for any character (like macOS)
    if localSearch == nil {
      localSearch = HomeSearchViewModel(db: database)
    }
    localSearch?.search(query: query)

    // Only perform global search for queries with 2 or more characters (like macOS)
    guard query.count >= 2 else {
      globalSearchResults = []
      isSearchingState = false
      return
    }

    isSearchingState = true

    Task {
      do {
        let result = try await api.searchContacts(query: query)

        // Save users to database like macOS
        try await database.dbWriter.write { db in
          for apiUser in result.users {
            try apiUser.saveFull(db)
          }
        }

        // Store the API users directly for use in navigation
        await MainActor.run {
          globalSearchResults = result.users
        }

        await MainActor.run {
          isSearchingState = false
        }
      } catch {
        Log.shared.error("Error searching users", error: error)
        await MainActor.run {
          globalSearchResults = []
          isSearchingState = false
        }
      }
    }
  }

  private func initalFetch() {
    notificationHandler.setAuthenticated(value: true)

    Task.detached {
      do {
        try await realtimeV2.send(.getMe())
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
    List {
      if !localSearchResults.isEmpty {
        ForEach(localSearchResults) { (result: SearchResult) in
          searchResultRow(for: result)
        }
      }

      if !globalSearchResults.isEmpty {
        Section("Global Search") {
          ForEach(globalSearchResults.map { .globalUser($0) }) { (result: SearchResult) in
            searchResultRow(for: result)
          }
        }
      }
    }
    .listStyle(.plain)
  }

  private func searchResultRow(for result: SearchResult) -> some View {
    Button {
      handleSearchResult(result)
    } label: {
      HStack(alignment: .center, spacing: 9) {
        // Avatar
        switch result {
          case let .localUser(user):
            UserAvatar(user: user, size: 34)
          case let .localThread(threadInfo):
            InitialsCircle(
              name: threadInfo.chat.title ?? "Group Chat",
              size: 34,
              symbol: "bubble.fill",
              emoji: threadInfo.chat.emoji
            )
          case let .globalUser(apiUser):
            UserAvatar(apiUser: apiUser, size: 34)
        }

        // Content
        VStack(alignment: .leading, spacing: 0) {
          Text(getDisplayName(for: result))
            .font(.body)
            .themedPrimaryText()
            .lineLimit(1)

          if let subtitle = getSubtitle(for: result) {
            Text(subtitle)
              .font(.caption)
              .themedSecondaryText()
              .lineLimit(1)
          }
        }

        Spacer()
      }
    }
    .buttonStyle(.plain)
    .listRowInsets(.init(top: 4, leading: 12, bottom: 4, trailing: 0))
  }

  private func navigateToUser(_ userId: Int64) {
    Task {
      do {
        let peer = try await dataManager.createPrivateChat(userId: userId)
        router.push(.chat(peer: peer))
      } catch {
        Log.shared.error("Failed to create chat", error: error)
      }
    }
  }

  private func navigateToApiUser(_ apiUser: ApiUser) {
    Task {
      do {
        try await dataManager.createPrivateChatWithOptimistic(user: apiUser)
        router.push(.chat(peer: .user(id: apiUser.id)))
      } catch {
        Log.shared.error("Failed to open a private chat with \(apiUser.anyName)", error: error)
      }
    }
  }

  private func handleSearchResult(_ result: SearchResult) {
    switch result {
      case let .localUser(user):
        router.push(.chat(peer: .user(id: user.id)))
      case let .localThread(threadInfo):
        router.push(.chat(peer: .thread(id: threadInfo.chat.id)))
      case let .globalUser(apiUser):
        navigateToApiUser(apiUser)
    }
  }

  private func getDisplayName(for result: SearchResult) -> String {
    switch result {
      case let .localUser(user):
        "\(user.firstName ?? "") \(user.lastName ?? "")".trimmingCharacters(in: .whitespaces)
      case let .localThread(threadInfo):
        threadInfo.chat.title ?? "Group Chat"
      case let .globalUser(apiUser):
        "\(apiUser.firstName ?? "") \(apiUser.lastName ?? "")".trimmingCharacters(in: .whitespaces)
    }
  }

  private func getSubtitle(for result: SearchResult) -> String? {
    switch result {
      case let .localUser(user):
        user.username.map { "@\($0)" }
      case let .localThread(threadInfo):
        threadInfo.space?.name ?? "Group Chat"
      case let .globalUser(apiUser):
        apiUser.username.map { "@\($0)" }
    }
  }

  private func calculateRelevanceScore(for result: SearchResult, query: String) -> Int {
    let queryLower = query.lowercased()
    var score = 0

    switch result {
      case let .localUser(user):
        let fullName = "\(user.firstName ?? "") \(user.lastName ?? "")".lowercased()
        let username = user.username?.lowercased() ?? ""

        // Exact matches get highest score
        if fullName == queryLower || username == queryLower {
          score += 100
        }
        // Starts with query gets high score
        else if fullName.hasPrefix(queryLower) || username.hasPrefix(queryLower) {
          score += 50
        }
        // Contains query gets medium score
        else if fullName.contains(queryLower) || username.contains(queryLower) {
          score += 25
        }

        // Local results get a small boost for being cached
        score += 5

      case let .localThread(threadInfo):
        let title = threadInfo.chat.title?.lowercased() ?? ""

        if title == queryLower {
          score += 100
        } else if title.hasPrefix(queryLower) {
          score += 50
        } else if title.contains(queryLower) {
          score += 25
        }

        // Local results get a small boost
        score += 5

      case let .globalUser(apiUser):
        let fullName = "\(apiUser.firstName ?? "") \(apiUser.lastName ?? "")".lowercased()
        let username = apiUser.username?.lowercased() ?? ""

        // Exact matches get highest score
        if fullName == queryLower || username == queryLower {
          score += 100
        }
        // Starts with query gets high score
        else if fullName.hasPrefix(queryLower) || username.hasPrefix(queryLower) {
          score += 50
        }
        // Contains query gets medium score
        else if fullName.contains(queryLower) || username.contains(queryLower) {
          score += 25
        }
    }

    return score
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
            .themedPrimaryText()
            .padding(.bottom, 14)
          Text("Search for chats and people")
            .font(.headline)
            .themedPrimaryText()
          Text("Type to find existing chats or search for people to start new conversations")
            .themedSecondaryText()
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 45)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeManager.shared.backgroundColorSwiftUI)
        .transition(.opacity)
      }
    }
  }
}
