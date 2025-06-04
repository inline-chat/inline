import InlineKit
import InlineUI
import Logger
import SwiftUI

struct HomeSidebar: View {
  // MARK: - Types

  enum SideItem: Identifiable, Equatable {
    case space(InlineKit.Space)
    case chat(InlineKit.HomeChatItem)

    var id: String {
      switch self {
        case let .space(space):
          "\(space.id)\(space.name)"
        case let .chat(chat):
          "\(chat.dialog.id)dialog"
      }
    }
  }

  enum Tab: String, Hashable {
    case inbox
    case archive
    case spaces
  }

  // MARK: - State

  @Environment(\.appDatabase) var db
  @Environment(\.keyMonitor) var keyMonitor
  @Environment(\.dependencies) var dependencies
  @EnvironmentObject var nav: Nav
  @EnvironmentObject var data: DataManager
  @EnvironmentObject var overlay: OverlayManager
  @EnvironmentStateObject var home: HomeViewModel
  @StateObject var search = GlobalSearch()
  @FocusState private var isSearching: Bool

  private var showSearchBar: Bool {
    search.hasResults || (isSearching && search.canSearch)
  }

  private var tab: Tab {
    nav.selectedTab
  }

  // MARK: - Initializer

  init() {
    _home = EnvironmentStateObject { env in
      HomeViewModel(db: env.appDatabase)
    }
  }

  // MARK: - Computed

  private func filterArchived(_ chats: [HomeChatItem], archived: Bool) -> [HomeChatItem] {
    chats.filter { $0.dialog.archived == archived }
  }

  var items: [SideItem] {
    if tab == .archive {
      return home.archivedChats
        .map { SideItem.chat($0) }
    }

    return home.myChats
      .map { SideItem.chat($0) }
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
    SidebarSearchBar(text: $search.query)
      .focused($isSearching)
      .onChange(of: search.query) { _ in
        search.search()
      }
      .onChange(of: isSearching) { isSearching in
        if isSearching {
          keyMonitorUnsubscriber = keyMonitor?.addHandler(for: .escape, key: "home_search") { _ in
            search.clear()
            self.isSearching = false
            unsubcribeKeyMonitor()
          }
        } else {
          unsubcribeKeyMonitor()
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

  // The view when user focuses the search input shows up
  @ViewBuilder
  var searchView: some View {
    if search.hasResults {
      Section("Users") {
        ForEach(search.results, id: \.self) { result in
          switch result {
            case let .users(user):
              RemoteUserItem(user: user, action: {
                remoteUserPressed(user: user)
              })
              .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
          }
        }
      }
    } else {
      HStack {
        if search.isLoading {
          Text("Searching...")
        } else if let error = search.error {
          Text("Failed to load: \(error.localizedDescription)")
        } else if !search.query.isEmpty {
          // User searched, loading is done, but we didn't find a result
          Text("No user found.")
        } else {
          Text("Search by username to start a chat.")
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .lineLimit(2)
      .font(.body)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .padding()
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
