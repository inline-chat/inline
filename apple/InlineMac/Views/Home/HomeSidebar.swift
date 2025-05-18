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
  @EnvironmentObject var nav: Nav
  @EnvironmentObject var data: DataManager
  @EnvironmentObject var overlay: OverlayManager
  @EnvironmentStateObject var home: HomeViewModel
  @StateObject var search = GlobalSearch()
  @FocusState private var isSearching: Bool

  @State private var tab: Tab = .inbox
  @State private var isAtTop = false
  @State private var isAtBottom = false

  // MARK: - Initializer

  init() {
    _home = EnvironmentStateObject { env in
      HomeViewModel(db: env.appDatabase)
    }
  }

  // MARK: - Computed

  private func sortChats(_ chats: [HomeChatItem]) -> [HomeChatItem] {
    chats.sorted { item1, item2 in
      // First sort by pinned status
      let pinned1 = item1.dialog.pinned ?? false
      let pinned2 = item2.dialog.pinned ?? false
      if pinned1 != pinned2 { return pinned1 }

      // Then sort by date
      let date1 = item1.message?.date ?? item1.chat?.date ?? Date.distantPast
      let date2 = item2.message?.date ?? item2.chat?.date ?? Date.distantPast
      return date1 > date2
    }
  }

  private func filterArchived(_ chats: [HomeChatItem], archived: Bool) -> [HomeChatItem] {
    chats.filter { $0.dialog.archived == archived }
  }

  var items: [SideItem] {
    let sortedChats = sortChats(home.chats)

    if tab == .archive {
      return filterArchived(sortedChats, archived: true)
        .map { SideItem.chat($0) }
    }

    let users = filterArchived(sortedChats, archived: false)
      .map { SideItem.chat($0) }

    return users
  }

  // MARK: - Views

  var body: some View {
    list3
  }

  @ViewBuilder
  var list: some View {
    if tab == .spaces {
      SpacesTab()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(
          edge: .bottom,
          content: {
            tabs
              .padding(.top, -8)
          }
        )
    } else {
      List {
        if search.hasResults || (isSearching && search.canSearch) {
          searchView
        } else {
          spacesAndUsersView
        }
      }
      .padding(.bottom, 0)
      .listStyle(.sidebar)
      .animation(.smoothSnappy, value: items)
      .animation(.smoothSnappy, value: home.chats)
      .safeAreaInset(
        edge: .bottom,
        content: {
          tabs
            .padding(.top, -8)
        }
      )

      //    .overlay(alignment: .bottom) {
      //      tabs
      //    }

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
      //              /// NOTE(@mo): this `scaleEffect` fixes an animation issue where the image would stay still while
      //              /the
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

      .safeAreaInset(
        edge: .top,
        spacing: 0,
        content: {
          VStack(alignment: .leading, spacing: 0) {
            topArea
            searchBar
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(
            .horizontal,
            Theme.sidebarItemOuterSpacing
          )
          .padding(.bottom, 8)
          .edgesIgnoringSafeArea(.bottom)
          .background(alignment: .bottom) {
            if !isAtTop {
              Divider().opacity(0.4)
            }
          }
        }
      )

      .onChange(of: nav.currentRoute) { _ in
        DispatchQueue.main.async {
          subscribeNavKeyMonitor()
        }
      }
      .onAppear {
        subscribeNavKeyMonitor()
      }
    }
  }

  @ViewBuilder
  var list2: some View {
    if #available(macOS 15.0, *) {
      list
//        .overlay(alignment: .top) {
//          if !isAtTop {
//            Divider().opacity(0.4)
//          }
//        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
          geometry.contentOffset.y <= 0
        } action: { _, isBeyondZero in
          self.isAtTop = isBeyondZero
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
          geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height
        } action: { _, isBeyondBottom in
          self.isAtBottom = isBeyondBottom
        }
    } else {
      list
    }
  }

  @ViewBuilder
  var list3: some View {
    if #available(macOS 14.0, *) {
      list2

      // .contentMargins(.bottom, 44, for: .scrollIndicators)
      // .safeAreaPadding(.bottom, 40)
      // .contentMargins(.bottom, 44, for: .scrollContent)
      // .ignoresSafeArea(edges: .bottom)
    } else {
      list2
    }
  }

  @ViewBuilder
  var tabs: some View {
    SidebarTabView<Tab>(
      tabs: [
        .init(value: .archive, systemImage: "archivebox.fill"),
        .init(value: .inbox, systemImage: "bubble.left.and.bubble.right.fill", fontSize: 15),
        .init(value: .spaces, systemImage: "building.2.fill", fontSize: 15),
      ],
      selected: tab,
      showDivider: !isAtBottom,
      onSelect: { tab = $0 }
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
  var spacesAndUsersView: some View {
    ForEach(items, id: \.id) { item in
      renderItem(item)
    }
  }

  @ViewBuilder
  fileprivate func renderItem(_ item: SideItem) -> some View {
    switch item {
      case let .chat(chat):
        if let user = chat.user {
          userItem(user, item: chat)
        } else if let thread = chat.chat {
          threadItem(thread, item: chat)
        }

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
  func userItem(_ userInfo: UserInfo, item: HomeChatItem) -> some View {
    let user = userInfo.user
    let dialog = item.dialog
    let chatChat = item.chat
    let peerId = Peer.user(id: user.id)

    SidebarItem(
      type: .user(userInfo, chat: chatChat),
      dialog: dialog,
      lastMessage: item.message,
      selected: nav.currentRoute == .chat(peer: peerId),
      onPress: {
        nav.open(.chat(peer: peerId))
      },
    )
    .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
  }

  @ViewBuilder
  func threadItem(_ chat: Chat, item: HomeChatItem) -> some View {
    let peerId: Peer = .thread(id: chat.id)

    SidebarThreadItem(
      chat: chat,
      dialog: item.dialog,
      lastMessage: item.message,
      lastMessageSender: item.from,
      spaceName: item.space?.name
    )
    .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
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

      plusButton
    }
    .padding(.top, -6)
    .padding(.bottom, 8)
    .padding(
      .leading,
      Theme.sidebarItemInnerSpacing
    )
    .padding(
      .trailing,
      4
    )
  }

  @ViewBuilder
  var plusButton: some View {
    Menu {
      Button {
        nav.open(.createSpace)
      } label: {
        Label("New Supergroup (Team)", systemImage: "plus")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(Color.accent)
      }

      Menu {
        ForEach(home.spaces, id: \.space.id) { spaceItem in
          Button {
            nav.open(.newChat(spaceId: spaceItem.space.id))
          } label: {
            Label(spaceItem.space.name, systemImage: "bubble.left.and.bubble.right.fill")
              .font(.system(size: 14, weight: .medium))
              .foregroundStyle(Color.accent)
          }
        }
      } label: {
        Label("Create group chat", systemImage: "person.3.fill")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(Color.accent)
      }

    } label: {
      Image(systemName: "plus")
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.tertiary)
        .contentShape(.circle)
        .frame(width: Theme.sidebarTitleIconSize, height: Theme.sidebarTitleIconSize, alignment: .center)
//        .background(
//          Circle()
//            .foregroundStyle(.gray.opacity(0.1))
//        )
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
