import InlineKit
import InlineSearch
import InlineUI
import Logger
import RealtimeV2
import SwiftUI

struct ExperimentalSearchView: View {
  @Binding private var query: String
  let activeSpaceId: Int64?

  @Environment(Router.self) private var router
  @Environment(\.appDatabase) private var database
  @Environment(\.realtimeV2) private var realtimeV2
  @EnvironmentObject private var dataManager: DataManager

  @State private var searchModel: InlineSearchViewModel?
  @FocusState private var isSearchFocused: Bool

  init(query: Binding<String>, activeSpaceId: Int64?) {
    _query = query
    self.activeSpaceId = activeSpaceId
  }

  var body: some View {
    VStack(spacing: 0) {
      ExperimentalSearchInput(text: $query, isFocused: $isSearchFocused)

      ZStack {
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

        overlayContent
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(.rect)
      .simultaneousGesture(TapGesture().onEnded {
        isSearchFocused = false
      })
      .scrollDismissesKeyboard(.interactively)
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
      isSearchFocused = false
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
    isSearchFocused = false
    openInInbox(result.peer)
  }

  private func openSearchMessage(_ result: LocalMessageSearchResult) {
    isSearchFocused = false
    openInInbox(result.peer)
  }

  private func openSearchGlobalUser(_ result: InlineSearchGlobalUserResult) {
    isSearchFocused = false
    let user = result.user
    Task {
      do {
        try await dataManager.createPrivateChatWithOptimistic(user: user)
        openInInbox(.user(id: user.id))
      } catch {
        Log.shared.error("Failed to open private chat from experimental search", error: error)
      }
    }
  }

  private func openInInbox(_ peer: Peer) {
    Task {
      await realtimeV2.sendQueued(.updateDialogOpen(peerId: peer, open: true))
      router.selectedTab = .chats
      router.popToRoot(for: .chats)
      router.push(.chat(peer: peer), for: .chats)
    }
  }
}

private struct ExperimentalSearchInput: View {
  @Binding var text: String
  @FocusState.Binding var isFocused: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)

      TextField("Search chats, messages, and people", text: $text)
        .focused($isFocused)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.search)

      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear Search")
      }
    }
    .padding(.horizontal, 12)
    .frame(minHeight: 44)
    .background(
      Color(.secondarySystemBackground),
      in: Capsule()
    )
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }
}
