import InlineKit
import InlineUI
import SwiftUI
import Logger

struct SpaceSidebar: View {
  @EnvironmentObject var nav: Nav
  @EnvironmentObject var data: DataManager
  @EnvironmentStateObject var fullSpace: FullSpaceViewModel
  @Environment(\.keyMonitor) var keyMonitor
  @Environment(\.openWindow) var openWindow
  @Environment(\.realtime) var realtime

  @State var searchQuery: String = ""

  var spaceId: Int64

  enum Tab: String, Hashable {
    case archive
    case chats
    case members
  }

  @State private var tab: Tab = .chats

  init(spaceId: Int64) {
    self.spaceId = spaceId
    _fullSpace = EnvironmentStateObject { env in
      FullSpaceViewModel(db: env.appDatabase, spaceId: spaceId)
    }
  }

  var items: [SpaceChatItem] {
    let items = (fullSpace.chats + fullSpace.memberChats).sorted(
      by: {
        ($0.message?.date ?? $0.chat?.date ?? Date()) > ($1.message?.date ?? $1.chat?.date ?? Date())
      }
    )

    if tab == .archive {
      return items.filter { $0.dialog.archived == true }
    } else {
      return items.filter { $0.dialog.archived != true }
    }
  }

  @ViewBuilder
  func threadItem(_ chat: Chat, _ item: SpaceChatItem) -> some View {
    let peerId: Peer = .thread(id: chat.id)

    SidebarThreadItem(
      chat: chat,
      dialog: item.dialog,
      lastMessage: item.message,
    )
    .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
  }

  @ViewBuilder
  func userItem(_ user: User, _ item: SpaceChatItem) -> some View {
    let peerId: Peer = .user(id: user.id)
    let dialog = item.dialog
    let chat = item.chat
    let userInfo = item.userInfo ?? .init(user: user)

    SidebarItem(
      type: .user(userInfo, chat: chat),
      dialog: dialog,
      lastMessage: item.message,
      selected: nav.currentRoute == .chat(peer: peerId),
      onPress: {
        nav.open(.chat(peer: peerId))
      },
    )
    .listRowInsets(.init(
      top: 0,
      leading: 0,
      bottom: 0,
      trailing: 0
    ))
  }

  var body: some View {
    List {
      if tab == .archive || tab == .chats {
        ForEach(items, id: \ .peerId) { item in
          if let user = item.user {
            userItem(user, item)
          } else if let chat = item.chat {
            threadItem(chat, item)
          } else {
            EmptyView()
          }
        }
      } else if tab == .members {
        ForEach(fullSpace.memberChats) { item in
          if let user = item.user {
            userItem(user, item)
          } else {
            EmptyView()
          }
        }
      }
    }
    .animation(.smoothSnappy, value: items)
    .listRowBackground(Color.clear)
    .listStyle(.sidebar)
    .safeAreaInset(
      edge: .bottom,
      content: {
        tabs
          .padding(.top, -8)
      }
    )

    .safeAreaInset(
      edge: .top,
      content: {
        VStack(alignment: .leading, spacing: 0) {
          topArea
          SidebarSearchBar(text: $searchQuery)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(
          .horizontal,
          Theme.sidebarItemOuterSpacing
        )
        .padding(.bottom, 8)
        .edgesIgnoringSafeArea(.bottom)
      }
    )
    .task {
      Task.detached {
        do {
          // this one gets members
          try await data.getSpace(spaceId: spaceId)
        } catch {
          Log.shared.error("failed to get space", error: error)
        }
        
        Task.detached {
          try await realtime
            .invokeWithHandler(.getSpaceMembers, input: .getSpaceMembers(.with {
              $0.spaceID = spaceId
            }))
        }
        Task.detached {
          do {
            try await data.getDialogs(spaceId: spaceId)
          } catch {
            Log.shared.error("failed to get dialogs for space", error: error)
          }
        }
      }
    }
    .onAppear {
      DispatchQueue.main.async {
        subscribeKeyMonitor()
      }
    }
    .onDisappear {
      unsubscribeKeyMonitor()
    }
  }

  // MARK: - Views

  @ViewBuilder
  var tabs: some View {
    SidebarTabView<Tab>(
      tabs: [
        .init(value: .archive, systemImage: "archivebox.fill", accessibilityLabel: "Archive"),

        .init(
          value: .chats,
          systemImage: "bubble.left.and.bubble.right.fill",
          fontSize: 15,
          accessibilityLabel: "Chats"
        ),

        .init(value: .members, systemImage: "person.2.fill", accessibilityLabel: "Members"),
      ],
      selected: tab,
      showDivider: true,
      onSelect: { tab = $0 }
    )
  }

  @ViewBuilder
  var topArea: some View {
    HStack(spacing: 0) {
      BackToHomeButton()
        .padding(.leading, -4)
        .padding(.trailing, 4)

      if let space = fullSpace.space {
        SpaceAvatar(space: space, size: Theme.sidebarTitleIconSize)
          .padding(.trailing, Theme.sidebarIconSpacing)
      }

      Text(fullSpace.space?.name ?? "Loading...")
        .font(Theme.sidebarTopItemFont)

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
      // Button("New Chat") {
      Button("New Group Chat") {
        nav.open(.newChat)
      }

      Button("Invite to Space") {
        nav.open(.inviteToSpace)
      }
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.tertiary)
        .contentShape(.circle)
        .frame(width: 24, height: 24, alignment: .center)
//        .background(
//          Circle()
//            .foregroundStyle(.gray.opacity(0.1))
//        )
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
  }

  // MARK: - Private Methods

  private func subscribeKeyMonitor() {
    let _ = keyMonitor?.addHandler(for: .escape, key: "space_esc") { _ in
      if nav.currentRoute != .empty {
        nav.handleEsc()
      } else {
        nav.openHome(replace: true)
        unsubscribeKeyMonitor()
      }
    }
  }

  private func unsubscribeKeyMonitor() {
    keyMonitor?.removeHandler(for: .escape, key: "space_esc")
  }
}

@available(macOS 14, *)
#Preview {
  NavigationSplitView {
    SpaceSidebar(spaceId: 2)
      .previewsEnvironmentForMac(.populated)
  } detail: {
    Text("Welcome.")
  }
}
