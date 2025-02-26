import InlineKit
import InlineUI
import SwiftUI

struct SpaceSidebar: View {
  @EnvironmentObject var nav: Nav
  @EnvironmentObject var data: DataManager

  @EnvironmentStateObject var fullSpace: FullSpaceViewModel
  @Environment(\.openWindow) var openWindow

  var spaceId: Int64

  init(spaceId: Int64) {
    self.spaceId = spaceId
    _fullSpace = EnvironmentStateObject { env in
      FullSpaceViewModel(db: env.appDatabase, spaceId: spaceId)
    }
  }

  var items: [SpaceChatItem] {
    (fullSpace.chats + fullSpace.memberChats).sorted(
      by: {
        ($0.message?.date ?? $0.chat?.date ?? Date()) > ($1.message?.date ?? $1.chat?.date ?? Date())
      }
    )
  }

  @ViewBuilder
  func threadItem(_ chat: Chat, _ item: SpaceChatItem) -> some View {
    let peerId: Peer = .thread(id: chat.id)

    ThreadItem(
      thread: chat,
      action: {
        nav.open(.chat(peer: peerId))
      },
      commandPress: {
        openWindow(value: peerId)
      },
      selected: nav.currentRoute == .chat(peer: peerId)
    )
    .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
  }

  @ViewBuilder
  func userItem(_ user: User, _ item: SpaceChatItem) -> some View {
    let peerId: Peer = .user(id: user.id)
    let dialog = item.dialog
    let chat = item.chat

    UserItem(
      userInfo: item.userInfo ?? .init(user: user),
      dialog: dialog,
      chat: chat,
      action: {
        nav.open(.chat(peer: peerId))
      },
      commandPress: {
        openWindow(value: peerId)
      },
      selected: nav.currentRoute == .chat(peer: peerId)
    )
    .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
  }

  var body: some View {
    List {
      ForEach(items, id: \.peerId) { item in
        if let user = item.user {
          userItem(user, item)
        } else if let chat = item.chat {
          threadItem(chat, item)
        } else {
          EmptyView()
        }
      }
    }
    .listRowInsets(EdgeInsets())
    .listRowBackground(Color.clear)
    .listStyle(.sidebar)
//    .toolbar {
//      ToolbarItemGroup(placement: .automatic) {
//        Button("Back to Home", systemImage: "house") {
//          nav.openHome()
//        }
//      }
//    }
    .safeAreaInset(
      edge: .top,
      content: {
        VStack(alignment: .leading, spacing: 0) {
          HStack(spacing: 0) {
            if let space = fullSpace.space {
              SpaceAvatar(space: space, size: Theme.sidebarIconSize)
                .padding(.trailing, Theme.sidebarIconSpacing)
            }

            Text(fullSpace.space?.name ?? "Loading...")
              .font(Theme.sidebarTopItemFont)

            Spacer()
          }
          .frame(height: Theme.sidebarTopItemHeight)
          .padding(.top, 0)
          // .frame(maxWidth: .infinity, alignment: .leading)
          // .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.leading, Theme.sidebarItemLeadingGutter)
      }
    )
    .task {
      do {
        try await data.getDialogs(spaceId: spaceId)
      } catch {}
    }
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
