import InlineKit
import InlineUI
import Logger
import SwiftUI

struct SpaceMembersView: View {
  @EnvironmentObject var nav: Nav
  @EnvironmentObject var data: DataManager
  @EnvironmentStateObject var fullSpace: FullSpaceViewModel
  @Environment(\.keyMonitor) var keyMonitor
  @Environment(\.realtime) var realtime

  @State var searchQuery: String = ""
  @State private var selectedTab: Int = 0
  var spaceId: Int64

  init(spaceId: Int64) {
    self.spaceId = spaceId
    _fullSpace = EnvironmentStateObject { env in
      FullSpaceViewModel(db: env.appDatabase, spaceId: spaceId)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      topBar
      // searchBar

      Picker("", selection: $selectedTab) {
        Text("Chats").tag(0)
        Text("Members").tag(1)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal, Theme.sidebarItemOuterSpacing)
      .padding(.bottom, 8)
      .padding(.top, 4)

      if selectedTab == 0 {
        threadsList
      } else {
        membersList
      }
    }
    .task {
      do {
        try await data.getSpace(spaceId: spaceId)
        try await realtime
          .invokeWithHandler(.getSpaceMembers, input: .getSpaceMembers(.with {
            $0.spaceID = spaceId
          }))
      } catch {
        Log.shared.error("failed to get space data", error: error)
      }
    }
  }

  @ViewBuilder
  private var topBar: some View {
    HStack(spacing: 0) {
      BackToSpacesButton(selectedSpaceId: $nav.selectedSpaceId)
        .padding(.leading, -8)

      if let space = fullSpace.space {
        SpaceAvatar(space: space, size: Theme.sidebarTitleIconSize)
          .padding(.trailing, Theme.sidebarIconSpacing)
      }

      Text(fullSpace.space?.displayName ?? "Loading...")
        .font(Theme.sidebarTopItemFont)

      Spacer()

      plusButton
    }
    .padding(.top, -6)
    .padding(.bottom, 8)
    .padding(.horizontal, Theme.sidebarItemOuterSpacing)
    .padding(.leading, Theme.sidebarItemInnerSpacing)
    .padding(.trailing, 4)
  }

  private var searchBar: some View {
    SidebarSearchBar(text: $searchQuery)
      .padding(.horizontal, Theme.sidebarItemOuterSpacing)
      .padding(.bottom, 8)
  }

  @ViewBuilder
  private var membersList: some View {
    List {
      ForEach(fullSpace.members) { item in
        memberItem(item)
      }
    }
    .listStyle(.sidebar)
  }

  @ViewBuilder
  private var threadsList: some View {
    List {
      ForEach(fullSpace.chats) { item in
        if let chat = item.chat {
          SidebarThreadItem(
            chat: chat,
            dialog: item.dialog,
            lastMessage: item.message,
            lastMessageSender: item.from,
          )
          .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
        }
      }
    }
    .listStyle(.sidebar)
    .overlay(alignment: .center) {
      if fullSpace.chats.isEmpty || (fullSpace.chats.count == 1 && fullSpace.chats.first?.chat?.title == "Main") {
        VStack(spacing: 10) {
          Image(systemName: "ellipsis.bubble")
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(Color.accent)

          Text("You can create more chats for different topics.")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.sidebarItemOuterSpacing)

          Button("New Chat") {
            nav.open(.newChat(spaceId: spaceId))
          }
        }
      }
      // .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder
  func memberItem(_ item: FullMemberItem) -> some View {
    let peerId: Peer = .user(id: item.userInfo.user.id)

    MemberItem(
      member: item,
      selected: nav.currentRoute == .chat(peer: peerId),
      onPress: {
        nav.open(.chat(peer: peerId))
      }
    )
    .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
  }

  @ViewBuilder
  var plusButton: some View {
    Menu {
      Button("New Chat", systemImage: "bubble.left") {
        nav.open(.newChat(spaceId: spaceId))
      }

      Button("Invite to Space", systemImage: "person.badge.plus") {
        nav.open(.inviteToSpace(spaceId: spaceId))
      }
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.tertiary)
        .contentShape(.circle)
        .frame(width: 24, height: 24, alignment: .center)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
  }
}

#Preview {
  SpaceMembersView(spaceId: 1)
    .previewsEnvironmentForMac(.populated)
}
