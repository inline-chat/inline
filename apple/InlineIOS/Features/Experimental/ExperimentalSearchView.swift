import GRDB
import InlineKit
import InlineUI
import Logger
import SwiftUI

private struct IdentifiedLocalSearchResult: Identifiable {
  let id: String
  let item: HomeSearchResultItem
}

struct ExperimentalSearchView: View {
  let query: String
  let activeSpaceId: Int64?

  @Environment(Router.self) private var router
  @Environment(\.appDatabase) private var database
  @EnvironmentObject private var api: ApiClient
  @EnvironmentObject private var dataManager: DataManager
  @EnvironmentStateObject private var localSearch: HomeSearchViewModel

  @State private var globalSearchResults: [ApiUser] = []
  @State private var isSearchingRemotely = false
  @State private var remoteSearchTask: Task<Void, Never>?
  @State private var remoteSearchToken = UUID()

  init(query: String, activeSpaceId: Int64?) {
    self.query = query
    self.activeSpaceId = activeSpaceId
    _localSearch = EnvironmentStateObject { env in
      HomeSearchViewModel(db: env.appDatabase)
    }
  }

  var body: some View {
    List {
      if !identifiedLocalResults.isEmpty {
        Section {
          ForEach(identifiedLocalResults) { result in
            localSearchResultRow(for: result.item)
          }
        }
      }

      if !globalSearchResults.isEmpty {
        Section("Global Search") {
          ForEach(globalSearchResults, id: \.id) { user in
            remoteSearchResultRow(for: user)
          }
        }
      }
    }
    .listStyle(.plain)
    .overlay {
      overlayContent
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground))
    .navigationBarTitleDisplayMode(.inline)
    .navigationTitle("")
    .onAppear {
      updateSearch(for: query)
    }
    .onChange(of: query) { _, newValue in
      updateSearch(for: newValue)
    }
    .onDisappear {
      remoteSearchTask?.cancel()
    }
  }

  private var filteredLocalResults: [HomeSearchResultItem] {
    localSearch.results.filter { result in
      switch result {
        case let .thread(threadInfo):
          guard let activeSpaceId else { return true }
          return threadInfo.space?.id == activeSpaceId
        case .user:
          return true
      }
    }
  }

  private var hasResults: Bool {
    !filteredLocalResults.isEmpty || !globalSearchResults.isEmpty
  }

  private var identifiedLocalResults: [IdentifiedLocalSearchResult] {
    filteredLocalResults.map { result in
      switch result {
        case let .thread(threadInfo):
          IdentifiedLocalSearchResult(id: "thread_\(threadInfo.id)", item: result)
        case let .user(user):
          IdentifiedLocalSearchResult(id: "user_\(user.id)", item: result)
      }
    }
  }

  private var isSearching: Bool {
    localSearch.isSearching || isSearchingRemotely
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

  @ViewBuilder
  private func localSearchResultRow(for result: HomeSearchResultItem) -> some View {
    Button {
      openLocalSearchResult(result)
    } label: {
      HStack(alignment: .center, spacing: 9) {
        switch result {
          case let .thread(threadInfo):
            InitialsCircle(
              name: threadInfo.chat.humanReadableTitle ?? "Group Chat",
              size: 34,
              symbol: "number",
              symbolWeight: .medium,
              emoji: threadInfo.chat.emoji
            )

            VStack(alignment: .leading, spacing: 0) {
              Text(threadInfo.chat.humanReadableTitle ?? "Group Chat")
                .font(.body)
                .lineLimit(1)

              if let spaceName = threadInfo.space?.name {
                Text(spaceName)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
            }

          case let .user(user):
            UserAvatar(user: user, size: 34)

            VStack(alignment: .leading, spacing: 0) {
              Text(user.displayName)
                .font(.body)
                .lineLimit(1)

              if let username = user.username {
                Text("@\(username)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
            }
        }

        Spacer()
      }
    }
    .buttonStyle(.plain)
    .listRowInsets(.init(top: 4, leading: 12, bottom: 4, trailing: 12))
  }

  @ViewBuilder
  private func remoteSearchResultRow(for user: ApiUser) -> some View {
    Button {
      openRemoteSearchResult(user)
    } label: {
      HStack(alignment: .center, spacing: 9) {
        UserAvatar(apiUser: user, size: 34)

        VStack(alignment: .leading, spacing: 0) {
          Text(user.anyName)
            .font(.body)
            .lineLimit(1)

          if let username = user.username {
            Text("@\(username)")
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }

        Spacer()
      }
    }
    .buttonStyle(.plain)
    .listRowInsets(.init(top: 4, leading: 12, bottom: 4, trailing: 12))
  }

  private func updateSearch(for query: String) {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

    localSearch.search(query: trimmedQuery)
    remoteSearchTask?.cancel()

    let token = UUID()
    remoteSearchToken = token

    guard !trimmedQuery.isEmpty else {
      globalSearchResults = []
      isSearchingRemotely = false
      return
    }

    guard trimmedQuery.count >= 2 else {
      globalSearchResults = []
      isSearchingRemotely = false
      return
    }

    isSearchingRemotely = true

    remoteSearchTask = Task {
      do {
        let result = try await api.searchContacts(query: trimmedQuery)

        try await database.dbWriter.write { db in
          for apiUser in result.users {
            try apiUser.saveFull(db)
          }
        }

        guard !Task.isCancelled else { return }

        await MainActor.run {
          guard remoteSearchToken == token else { return }
          globalSearchResults = result.users
          isSearchingRemotely = false
        }
      } catch {
        guard !Task.isCancelled else { return }

        Log.shared.error("Failed experimental search", error: error)

        await MainActor.run {
          guard remoteSearchToken == token else { return }
          globalSearchResults = []
          isSearchingRemotely = false
        }
      }
    }
  }

  private func openLocalSearchResult(_ result: HomeSearchResultItem) {
    switch result {
      case let .thread(threadInfo):
        router.push(.chat(peer: .thread(id: threadInfo.chat.id)))
      case let .user(user):
        router.push(.chat(peer: .user(id: user.id)))
    }
  }

  private func openRemoteSearchResult(_ user: ApiUser) {
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
