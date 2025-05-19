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
  var spaceId: Int64
  @Binding var selectedSpaceId: Int64?

  init(spaceId: Int64, selectedSpaceId: Binding<Int64?>) {
    self.spaceId = spaceId
    _selectedSpaceId = selectedSpaceId
    _fullSpace = EnvironmentStateObject { env in
      FullSpaceViewModel(db: env.appDatabase, spaceId: spaceId)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      topBar
      searchBar
      membersList
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
      BackToSpacesButton(selectedSpaceId: $selectedSpaceId)
        .padding(.leading, -4)
        .padding(.trailing, 4)

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

  private var membersList: some View {
    List {
      Section("Members") {
        ForEach(fullSpace.members) { item in
          memberItem(item)
        }
      }

      Section("Threads") {
        ForEach(fullSpace.chats) { item in
          if let chat = item.chat {
            SpaceSmallChatItem(
              chat: chat,
              selected: nav.currentRoute == .chat(peer: .thread(id: chat.id)),
              onPress: {
                nav.open(.chat(peer: .thread(id: chat.id)))
              }
            )
            .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
          }
        }
      }
    }
    .listStyle(.sidebar)
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
      Button("New Group Chat") {
        nav.open(.newChat(spaceId: spaceId))
      }

      Button("Invite to Space") {
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
  SpaceMembersView(spaceId: 1, selectedSpaceId: .constant(1))
    .previewsEnvironmentForMac(.populated)
}
