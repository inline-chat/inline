import InlineKit
import InlineSearch
import InlineUI
import Logger
import SwiftUI
import UIKit

struct HomeView: View {
  // MARK: - Environment

  @EnvironmentObject private var dataManager: DataManager
  @EnvironmentObject private var notificationHandler: NotificationHandler
  @EnvironmentObject private var home: HomeViewModel

  @Environment(\.realtimeV2) private var realtimeV2
  @Environment(\.appDatabase) private var database
  @Environment(Router.self) private var router

  // MARK: - State

  @State private var text = ""
  @State private var searchModel: InlineSearchViewModel?

  private var chatItems: [HomeChatItem] {
    let visibleChats = home.chats.filter { $0.dialog.archived != true }
    return HomeViewModel.sortChats(visibleChats)
  }

  var body: some View {
    homeContent
      .background(Color(.systemBackground))
      .searchable(text: $text, prompt: "Find")
      .onChange(of: text) { _, newValue in
        searchHome(query: newValue)
      }
      .toolbar {
        HomeToolbarContent()
      }
      .navigationBarTitleDisplayMode(.inline)
      .navigationBarBackButtonHidden()
      .onAppear {
        ensureSearchModel()
        searchHome(query: text)
        initialFetch()
      }
      .navigationTitle("Chats")
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
                router.push(.chat(peer: item.peerId))
              },
              onArchive: { item in
                Task {
                  try await dataManager.updateDialog(
                    peerId: item.peerId,
                    archived: true
                  )
                }
              },
              onPin: { item in
                Task {
                  try await dataManager.updateDialog(
                    peerId: item.peerId,
                    pinned: !(item.dialog.pinned ?? false)
                  )
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
                    try await realtimeV2.send(.markAsUnread(peerId: item.dialog.peerId))
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
            isSearchResultsEmpty: (searchModel?.hasResults ?? false) == false
          )
        }
      }
    }
  }

  @discardableResult
  private func ensureSearchModel() -> InlineSearchViewModel {
    if let searchModel {
      return searchModel
    }

    let model = InlineSearchViewModel(
      db: database,
      scope: homeSearchScope,
      limits: InlineSearchLimits(
        chatLimit: 24,
        messageBatchSize: 20,
        globalUserLimit: 20,
        globalDebounceNanoseconds: 220_000_000
      )
    )
    searchModel = model
    return model
  }

  private func searchHome(query: String) {
    let model = ensureSearchModel()
    guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
      model.clear()
      return
    }

    model.search(query, scope: homeSearchScope)
  }

  private var homeSearchScope: InlineSearchScope {
    InlineSearchScope(
      includeArchived: false,
      includeSpaceChatsInHome: true,
      includeGlobalUsers: true,
      messageSort: .relevance
    )
  }

  private func initialFetch() {
    notificationHandler.setAuthenticated(value: true)

    Task {
      do {
        try await realtimeV2.send(.getMe())
      } catch {
        Log.shared.error("Error fetching getMe info", error: error)
      }

      do {
        try await realtimeV2.send(.getChats())
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
    Group {
      if let searchModel {
        InlineSearchResultsList(
          model: searchModel,
          openChat: openSearchChat,
          openMessage: openSearchMessage,
          openGlobalUser: openSearchGlobalUser
        )
      } else {
        ProgressView()
      }
    }
  }

  private func openSearchChat(_ result: InlineSearchChatResult) {
    router.push(.chat(peer: result.peer))
  }

  private func openSearchMessage(_ result: LocalMessageSearchResult) {
    router.push(.chat(peer: result.peer))
  }

  private func openSearchGlobalUser(_ result: InlineSearchGlobalUserResult) {
    let apiUser = result.user
    Task {
      do {
        try await dataManager.createPrivateChatWithOptimistic(user: apiUser)
        router.push(.chat(peer: .user(id: apiUser.id)))
      } catch {
        Log.shared.error("Failed to open a private chat with \(apiUser.anyName)", error: error)
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
            .padding(.bottom, 14)
          Text("Search for chats and people")
            .font(.headline)

          Text("Type to find existing chats or search for people to start new conversations")
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
