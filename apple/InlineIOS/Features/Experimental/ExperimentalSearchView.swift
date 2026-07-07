import InlineKit
import InlineSearch
import InlineUI
import Logger
import SwiftUI

struct ExperimentalSearchView: View {
  let query: String
  let activeSpaceId: Int64?

  @Environment(Router.self) private var router
  @Environment(\.appDatabase) private var database
  @EnvironmentObject private var dataManager: DataManager

  @State private var searchModel: InlineSearchViewModel?

  init(query: String, activeSpaceId: Int64?) {
    self.query = query
    self.activeSpaceId = activeSpaceId
  }

  var body: some View {
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
    .overlay {
      overlayContent
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground))
    .navigationBarTitleDisplayMode(.inline)
    .navigationTitle("")
    .onAppear {
      ensureSearchModel()
      updateSearch(for: query)
    }
    .onChange(of: query) { _, newValue in
      updateSearch(for: newValue)
    }
    .onChange(of: activeSpaceId) { _, _ in
      updateSearch(for: query)
    }
    .onDisappear {
      searchModel?.clear()
    }
  }

  private var hasResults: Bool {
    searchModel?.hasResults ?? false
  }

  private var isSearching: Bool {
    searchModel?.isSearching ?? false
  }

  @ViewBuilder
  private var overlayContent: some View {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

    if trimmedQuery.isEmpty {
      ContentUnavailableView(
        "Search for chats and people",
        systemImage: "magnifyingglass",
        description: Text("Type to find existing chats or search for people to start new conversations")
      )
    } else if isSearching && !hasResults {
      ProgressView()
        .controlSize(.large)
    } else if !hasResults {
      ContentUnavailableView.search(text: trimmedQuery)
    }
  }

  private func updateSearch(for query: String) {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmedQuery.isEmpty else {
      searchModel?.clear()
      return
    }

    ensureSearchModel().search(trimmedQuery, scope: searchScope)
  }

  @discardableResult
  private func ensureSearchModel() -> InlineSearchViewModel {
    if let searchModel {
      return searchModel
    }

    let model = InlineSearchViewModel(
      db: database,
      scope: searchScope,
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

  private var searchScope: InlineSearchScope {
    InlineSearchScope(
      spaceId: activeSpaceId,
      includeArchived: false,
      includeSpaceChatsInHome: true,
      includeGlobalUsers: true,
      messageSort: .relevance
    )
  }

  private func openSearchChat(_ result: InlineSearchChatResult) {
    router.push(.chat(peer: result.peer))
  }

  private func openSearchMessage(_ result: LocalMessageSearchResult) {
    router.push(.chat(peer: result.peer))
  }

  private func openSearchGlobalUser(_ result: InlineSearchGlobalUserResult) {
    let user = result.user
    Task {
      do {
        try await dataManager.createPrivateChatWithOptimistic(user: user)
        router.push(.chat(peer: .user(id: user.id)))
      } catch {
        Log.shared.error("Failed to open private chat from experimental search", error: error)
      }
    }
  }
}
