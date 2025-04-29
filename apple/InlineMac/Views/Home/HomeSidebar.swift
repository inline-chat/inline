import InlineKit
import Logger
import SwiftUI

struct HomeSidebar: View {
  // MARK: - Types

  enum SideItem: Identifiable, Equatable {
    case space(InlineKit.Space)
    case user(InlineKit.HomeChatItem)
    case thread(InlineKit.SpaceChatItem)

    var id: Int64 {
      switch self {
        case let .space(space):
          space.id
        case let .user(chat):
          chat.user.id
        case let .thread(chat):
          chat.chat?.id ?? 0
      }
    }
  }

  enum Tab: String {
    case inbox
    case archive
    case search
  }

  // MARK: - State

  @Environment(\.appDatabase) var db
  @Environment(\.keyMonitor) var keyMonitor
  @EnvironmentObject var nav: Nav
  @EnvironmentObject var data: DataManager
  @EnvironmentObject var overlay: OverlayManager
  @EnvironmentStateObject var model: SpaceListViewModel
  @EnvironmentStateObject var home: HomeViewModel
  @StateObject var search = GlobalSearch()
  @FocusState private var isSearching: Bool

  @State private var tab: Tab = .inbox
  @State private var isScrolledToBottom = false

  // MARK: - Initializer

  init() {
    _model = EnvironmentStateObject { env in
      SpaceListViewModel(db: env.appDatabase)
    }
    _home = EnvironmentStateObject { env in
      HomeViewModel(db: env.appDatabase)
    }
  }

  // MARK: - Computed

  var items: [SideItem] {
    let spaces = home.spaces.map { SideItem.space($0.space) }
    let users = home.chats.sorted(
      by: {
        ($0.message?.date.timeIntervalSince1970 ?? $0.chat?.date.timeIntervalSince1970 ?? 0) > (
          $1.message?.date.timeIntervalSince1970 ?? $1.chat?.date.timeIntervalSince1970 ?? 0
        )
      }
    )
    .map { SideItem.user($0) }

    return users + spaces
  }

  // MARK: - Views

  var body: some View {
    List {
      if search.hasResults || (isSearching && search.canSearch) {
        searchView
      } else {
        spacesAndUsersView
      }

      // Add this invisible marker at the end of your list
      Color.clear
        .frame(height: 1)
        .id("bottom")
        .onAppear {
          isScrolledToBottom = true
        }
        .onDisappear {
          isScrolledToBottom = false
        }
    }
    .listStyle(.sidebar)
    .animation(.smoothSnappy, value: items)
    .safeAreaInset(
      edge: .bottom,
      content: {
        tabs
          .padding(.top, -8)
      }
    )

//    .safeAreaInset(
//      edge: .top,
//      content: {
//        Color.clear
//          .frame(height: 12)
//      }
//    )

//    .safeAreaInset(
//      edge: .top,
//      content: {
//        VStack(alignment: .leading, spacing: 0) {
//          HStack(alignment: .center, spacing: 0) {
//            SelfUser()
//              /// NOTE(@mo): this `scaleEffect` fixes an animation issue where the image would stay still while the
//              /// wrapper view was moving
//              .scaleEffect(1.0)
//
//            AlphaCapsule()
//          }
//          .padding(.top, 0)
//          .padding(.bottom, 8)
//
//          searchBar
//            .padding(.bottom, 2)
//        }
//        .frame(maxWidth: .infinity, alignment: .leading)
//        .padding(.horizontal) // default side padding
//        .padding(.leading, Theme.sidebarItemLeadingGutter) // gutter to sync with items
//      }
//    )

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
    HStack(spacing: 0) {
      Spacer()

      Button(action: {
        // Archive tab
      }) {
        let isActive = tab == .archive
        Image(systemName: "archivebox.fill")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(isActive ? .primary : .tertiary)
          .padding(.horizontal, 12)
          .padding(.vertical, 4)
      }
      .buttonStyle(.plain)

      Button(action: {
        // Inbox tab
      }) {
        let isActive = tab == .inbox
        Image(systemName: "tray.fill")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(isActive ? .primary : .tertiary)
          .padding(.horizontal, 12)
          .padding(.vertical, 4)
      }
      .buttonStyle(.plain)

      Button(action: {
        // Search tab
      }) {
        let isActive = tab == .search
        Image(systemName: "magnifyingglass")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(isActive ? .primary : .tertiary)
          .padding(.horizontal, 12)
          .padding(.vertical, 4)
      }
      .buttonStyle(.plain)

      Spacer()
    }
    .frame(height: 44)
    .overlay(alignment: .top) {
      if !isScrolledToBottom {
        Divider()
      }
    }
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
  var spacesAndUsersView: some View {
    ForEach(items, id: \.id) { item in
      renderItem(item)
    }
  }

  @ViewBuilder
  fileprivate func renderItem(_ item: SideItem) -> some View {
    switch item {
      case let .user(chat):
        userItem(chat: chat)

      case let .thread(chatItem):
        threadItem(chatItem: chatItem)

      case let .space(space):
        spaceItem(space: space)
    }
  }

  @ViewBuilder
  func spaceItem(space: InlineKit.Space) -> some View {
    SidebarSpaceItem(
      space: space
    )
    .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))

//    .swipeActions(edge: .leading, allowsFullSwipe: false) {
//      Button(action: {
//        nav.openSpace(space.id)
//      }) {
//        Image(systemName: "chevron.right")
//          .font(.system(size: 16, weight: .semibold))
//          .foregroundStyle(.primary)
//      }
//      .tint(.primary)
//    }
  }

  @ViewBuilder
  func userItem(chat: HomeChatItem) -> some View {
    let userInfo = chat.user
    let user = userInfo.user
    let dialog = chat.dialog
    let chatChat = chat.chat
    let peerId = Peer.user(id: user.id)

    SidebarItem(
      type: .user(userInfo, chat: chatChat),
      dialog: dialog,
      lastMessage: chat.message,
      selected: nav.currentRoute == .chat(peer: peerId),
      onPress: {
        nav.open(.chat(peer: peerId))
      },
    )
    .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
  }

  @ViewBuilder
  func threadItem(chatItem: SpaceChatItem) -> some View {
    if let chat = chatItem.chat {
      let peerId: Peer = .thread(id: chat.id)

      ThreadItem(
        thread: chat,
        action: {
          nav.open(.chat(peer: peerId))
        },
        commandPress: {
          openInWindow(peerId)
        },
        selected: nav.upcomingRoute == .chat(peer: peerId)
      )
      .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
    } else {}
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
