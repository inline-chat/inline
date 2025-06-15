import InlineKit
import InlineUI
import Logger
import SwiftUI

struct HomeSidebar: View {
  // MARK: - State

  @Environment(\.appDatabase) var db
  @Environment(\.keyMonitor) var keyMonitor
  @Environment(\.dependencies) var dependencies
  @EnvironmentObject var nav: Nav
  @EnvironmentObject var data: DataManager
  @EnvironmentObject var overlay: OverlayManager
  @EnvironmentStateObject var home: HomeViewModel
  @EnvironmentStateObject var localSearch: HomeSearchViewModel
  @StateObject var search = GlobalSearch()
  @FocusState private var isSearching: Bool
  @State private var selectedResultIndex: Int = 0
  @State private var searchQuery = ""
  @State private var keyMonitorSearchUnsubscriber: (() -> Void)?

  // MARK: - Initializer

  init() {
    _home = EnvironmentStateObject { env in
      HomeViewModel(db: env.appDatabase)
    }
    _localSearch = EnvironmentStateObject { env in
      HomeSearchViewModel(db: env.appDatabase)
    }
  }

  // MARK: - Computed

  private var showSearchBar: Bool {
    // search.hasResults || (isSearching && search.canSearch)
    search.hasResults || isSearching
  }

  private var tab: Tab {
    nav.selectedTab
  }

  // MARK: - Types

  enum Tab: String, Hashable {
    case inbox
    case archive
    case spaces
  }

  // MARK: - Views

  var body: some View {
    VStack(spacing: 0) {
      if nav.selectedTab == .spaces {
        SpacesTab()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        // Top area
        VStack(alignment: .leading, spacing: 0) {
          topArea
          searchBar
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.sidebarItemOuterSpacing)
        .padding(.bottom, 8)

        // Main content
        if showSearchBar {
          List {
            searchView
          }
          .listStyle(.sidebar)
          .listRowBackground(Color.clear)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          NewSidebarWrapper(dependencies: dependencies!, tab: tab)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .center) {
              if tab == .inbox, home.myChats
                .isEmpty, home.archivedChats.isEmpty
              {
                VStack(spacing: 10) {
                  Image(systemName: "bubble.and.pencil")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.accent)

                  Text("Search a username (eg. @mo) to start a chat or create a new space.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.sidebarItemOuterSpacing)
                }
                .padding(.horizontal, 18)
              }

              if tab == .archive, home.archivedChats.isEmpty {
                VStack(spacing: 10) {
                  Image(systemName: "archivebox")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.accent)

                  Text("Archive chats you don't need to see anymore by swiping left.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.sidebarItemOuterSpacing)
                }
                .padding(.horizontal, 18)
              }
            }
        }
      }

      // Bottom tabs
      tabs
    }
    .onChange(of: nav.currentRoute) { _ in
      DispatchQueue.main.async {
        subscribeNavKeyMonitor()
      }
    }
    .onAppear {
      subscribeNavKeyMonitor()
      // Add notification observer for focus search
      NotificationCenter.default.addObserver(
        forName: .focusSearch,
        object: nil,
        queue: .main
      ) { _ in
        isSearching = true
      }
    }
    .onDisappear {
      // Remove notification observer
      NotificationCenter.default.removeObserver(self, name: .focusSearch, object: nil)
    }
  }

  @ViewBuilder
  var tabs: some View {
    SidebarTabView<Tab>(
      tabs: [
        .init(value: .archive, label: "Archive", systemImage: "archivebox.fill"),
        .init(value: .inbox, label: "Your Chats", systemImage: "bubble.left.and.bubble.right.fill", fontSize: 16),
        .init(value: .spaces, label: "Space", systemImage: "building.2.fill", fontSize: 16),
        //  .init(value: .spaces, label: "Browse", systemImage: "list.bullet", fontSize: 18),
      ],
      selected: tab,
      showDivider: true,
      onSelect: { nav.selectedTab = $0 }
    )
  }

  @ViewBuilder
  var searchBar: some View {
    SidebarSearchBar(text: $searchQuery)
      .focused($isSearching)
      .overlay(alignment: .trailing) {
        if isSearching {
          Button {
            search.clear()
            searchQuery = ""
            isSearching = false
          } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: 13, weight: .medium))
          }
          .labelsHidden()
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .padding(.trailing, 8)
        }
      }
      .onSubmit {
        let totalResults = localSearch.results.count + search.results.count
        if totalResults > 0 {
          if selectedResultIndex < localSearch.results.count {
            // Local result
            let result = localSearch.results[selectedResultIndex]
            switch result {
              case let .thread(threadInfo):
                nav.open(.chat(peer: .thread(id: threadInfo.chat.id)))
              case let .user(user):
                userPressed(user: user)
            }
          } else {
            // Global result
            let globalIndex = selectedResultIndex - localSearch.results.count
            let result = search.results[globalIndex]
            switch result {
              case let .users(user):
                remoteUserPressed(user: user)
            }
          }
          search.clear()
          searchQuery = ""
          isSearching = false
        }
      }
      .onChange(of: searchQuery) { _ in
        search.updateQuery(searchQuery)
        Task { @MainActor in
          await localSearch.search(query: searchQuery)
          // Reset selection when search query changes
          selectedResultIndex = 0
        }
      }
      .onChange(of: isSearching) { isSearching in
        if isSearching {
          // Subscribe to escape key
          keyMonitorUnsubscriber = keyMonitor?.addHandler(for: .escape, key: "home_search") { _ in
            search.clear()
            searchQuery = ""
            self.isSearching = false
            unsubcribeKeyMonitor()
          }

          // Subscribe to arrow keys
          keyMonitorSearchUnsubscriber = keyMonitor?.addHandler(for: .arrowKeys, key: "home_search_arrows") { event in
            let totalResults = localSearch.results.count + search.results.count
            guard totalResults > 0 else { return }

            switch event.keyCode {
              case 126: // Up arrow
                if selectedResultIndex > 0 {
                  selectedResultIndex -= 1
                }
              case 125: // Down arrow
                if selectedResultIndex < totalResults - 1 {
                  selectedResultIndex += 1
                }
              default:
                break
            }
          }
        } else {
          unsubcribeKeyMonitor()
          unsubcribeSearchKeyMonitor()
        }
      }
  }

  @ViewBuilder
  var topArea: some View {
    HStack(spacing: 0) {
      // Home icon
      Circle()
        .fill(
          LinearGradient(
            colors: [
              .accent.adjustLuminosity(by: 0.05),
              .accent,
            ],
            startPoint: .top,
            endPoint: .bottom
          )
        )
        .overlay {
          // Image(systemName: "house.fill")
          if tab == .archive {
            Image(systemName: "archivebox.fill")
              .foregroundColor(.white)
              .font(.system(size: 11, weight: .regular))
          } else {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
              .foregroundColor(.white)
              .font(.system(size: 11, weight: .regular))
          }
        }
        .frame(width: Theme.sidebarTitleIconSize, height: Theme.sidebarTitleIconSize)
        .fixedSize()
        .padding(.trailing, Theme.sidebarIconSpacing)

      // Text("Home")
      if tab == .archive {
        Text("Archive")
      } else {
        Text("Your Chats")
      }

      Spacer()

      notificationsButton
      plusButton
    }
    .padding(.top, -6)
    .padding(.bottom, 8)
    .padding(
      .leading,
      Theme.sidebarItemInnerSpacing
    )
    .padding(.trailing, 4)
  }

  @ViewBuilder
  var notificationsButton: some View {
    NotificationSettingsButton()
  }

  @ViewBuilder
  var plusButton: some View {
    Menu {
      Button {
        nav.open(.createSpace)
      } label: {
        Label("New Space (Team)", systemImage: "plus")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(Color.accent)
      }

      Menu {
        if home.spaces.isEmpty {
          Button("Create a Space First") {}.disabled(true)
        } else {
          ForEach(home.spaces, id: \.space.id) { spaceItem in
            Button {
              nav.open(.newChat(spaceId: spaceItem.space.id))
            } label: {
              Label(spaceItem.space.name, systemImage: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.accent)
            }
          }
        }
      } label: {
        Label("New Chat", systemImage: "person.3.fill")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(Color.accent)
      }

    } label: {
      Image(systemName: "plus")
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.tertiary)
        .contentShape(.circle)
        .frame(width: Theme.sidebarTitleIconSize, height: Theme.sidebarTitleIconSize, alignment: .center)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
  }

  var hasAnyResults: Bool {
    search.hasResults || localSearch.results.count > 0
  }

  var searchLoadingResults: Bool {
    search.isLoading
  }

  // The view when user focuses the search input shows up
  @ViewBuilder
  var searchView: some View {
    if isSearching {
      if hasAnyResults {
        if localSearch.results.count > 0 {
          Section {
            ForEach(Array(localSearch.results.enumerated()), id: \.element.id) { index, result in
              LocalSearchItem(item: result, highlighted: selectedResultIndex == index) {
                handleLocalResult(result)
              }
              .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
          }
        }

        if search.hasResults {
          Section("Global Search") {
            ForEach(Array(search.results.enumerated()), id: \.element.id) { index, result in
              let globalIndex = index + localSearch.results.count
              switch result {
                case let .users(user):
                  RemoteUserItem(user: user, highlighted: selectedResultIndex == globalIndex, action: {
                    handleRemoteUser(user)
                  })
                  .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
              }
            }
          }
        }
      } else {
        HStack {
          if searchLoadingResults {
            ProgressView()
              .progressViewStyle(.circular)
              .tint(.secondary)
          } else if let error = search.error {
            Text("Failed to load: \(error.localizedDescription)")
              .font(.body)
              .foregroundStyle(.secondary)
          } else if !searchQuery.isEmpty, !hasAnyResults {
            // User searched, loading is done, but we didn't find a result
            Image(systemName: "x.circle")
              .font(.system(size: 32, weight: .medium))
              .foregroundStyle(.tertiary)
          } else {
            Image(systemName: "magnifyingglass")
              .font(.system(size: 32, weight: .medium))
              .foregroundStyle(.tertiary)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .lineLimit(2)
        .multilineTextAlignment(.center)
        .padding()
      }
    }
  }

  // MARK: - Key Monitor

  private func subscribeNavKeyMonitor() {
    if nav.currentRoute != .empty {
      if keyMonitorNavUnsubscriber == nil {
        keyMonitorNavUnsubscriber = keyMonitor?.addHandler(for: .escape, key: "nav_search") { _ in
          nav.handleEsc()
          unsubcribeNavKeyMonitor()
        }
      }
    } else {
      unsubcribeNavKeyMonitor()
    }
  }

  @State var keyMonitorNavUnsubscriber: (() -> Void)?
  private func unsubcribeNavKeyMonitor() {
    keyMonitorNavUnsubscriber?()
    keyMonitorNavUnsubscriber = nil
  }

  @State var keyMonitorUnsubscriber: (() -> Void)?
  private func unsubcribeKeyMonitor() {
    keyMonitorUnsubscriber?()
    keyMonitorUnsubscriber = nil
  }

  private func unsubcribeSearchKeyMonitor() {
    keyMonitorSearchUnsubscriber?()
    keyMonitorSearchUnsubscriber = nil
  }

  // MARK: - Actions

  private func remoteUserPressed(user: ApiUser) {
    // Save user

    Task { @MainActor in
      do {
        try await data.createPrivateChatWithOptimistic(user: user)

        // Clear search
        search.clear()
        isSearching = false

        nav.open(.chat(peer: .user(id: user.id)))
      } catch {
        Log.shared.error("Failed to open a private chat with \(user.anyName)", error: error)
        overlay.showError(message: "Failed to open a private chat with \(user.anyName)")
      }
    }
  }

  private func userPressed(user: User) {
    // Open chat in home
    nav.open(.chat(peer: .user(id: user.id)))
  }

  private func openInWindow(_ peer: Peer) {
    // TODO: implement when we support multiple windows
    nav.open(.chat(peer: peer))
  }

  private func handleLocalResult(_ result: HomeSearchResultItem) {
    switch result {
      case let .thread(threadInfo):
        nav.open(.chat(peer: .thread(id: threadInfo.chat.id)))
      case let .user(user):
        nav.open(.chat(peer: .user(id: user.id)))
    }
    search.clear()
    searchQuery = ""
    isSearching = false
  }

  private func handleRemoteUser(_ user: ApiUser) {
    Task { @MainActor in
      do {
        try await dependencies?.data.createPrivateChatWithOptimistic(user: user)
        nav.open(.chat(peer: .user(id: user.id)))
        search.clear()
        searchQuery = ""
        isSearching = false
      } catch {
        Log.shared.error("Failed to open a private chat with \(user.anyName)", error: error)
        overlay.showError(message: "Failed to open a private chat with \(user.anyName)")
      }
    }
  }
}

// MARK: - Preview

#Preview {
  NavigationSplitView {
    HomeSidebar()
      .previewsEnvironmentForMac(.populated)
  } detail: {
    Text("Welcome.")
  }
}

// MARK: - NewSidebar Wrapper

struct NewSidebarWrapper: NSViewControllerRepresentable {
  let dependencies: AppDependencies
  var tab: HomeSidebar.Tab

  func makeNSViewController(context: Context) -> NewSidebar {
    NewSidebar(dependencies: dependencies, tab: tab)
  }

  func updateNSViewController(_ nsView: NewSidebar, context: Context) {
    nsView.update(tab: tab)
  }
}
