import InlineKit
import InlineUI
import SwiftUI

struct SpaceSidebar: View {
  @EnvironmentObject var ws: WebSocketManager
  @EnvironmentObject var navigation: NavigationModel
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

  var body: some View {
    List {
      Section {
        ForEach(fullSpace.chats, id: \.peerId) { item in
          ChatSideItem(
            selectedRoute: navigation.spaceSelection,
            item: item
          )
        }
      }

      Section {
        ForEach(fullSpace.memberChats, id: \.peerId) { item in
          if let user = item.user {
            UserItem(
              user: user,
              action: {
                navigation.select(.chat(peer: .user(id: user.id)))
              },
              commandPress: {
                openWindow(value: Peer.user(id: user.id))
              },
              selected: navigation.spaceSelection.wrappedValue == .chat(
                peer: .user(id: user.id)
              )
            )
            .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
          } else {
            EmptyView()
          }
        }
      }
    }
    .listRowInsets(EdgeInsets())
    .listRowBackground(Color.clear)
    .listStyle(.sidebar)
    .safeAreaInset(
      edge: .top,
      content: {
        VStack(alignment: .leading, spacing: 0) {
          HStack(spacing: 0) {
            // Back
            Button {
              navigation.goHome()
            } label: {
              Image(systemName: "chevron.left")
                .font(.caption)
                .frame(height: Theme.sidebarIconSize)
                .padding(.trailing, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let space = fullSpace.space {
              SpaceAvatar(space: space, size: Theme.sidebarIconSize)
                .padding(.trailing, Theme.sidebarIconSpacing)
            }

            Text(fullSpace.space?.name ?? "Loading...")
              .font(Theme.sidebarTopItemFont)

            Spacer()
          }
          .frame(height: Theme.sidebarTopItemHeight)
          .padding(.top, -6)
          // .frame(maxWidth: .infinity, alignment: .leading)
          // .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
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
      .previewsEnvironment(.populated)
      .environmentObject(NavigationModel())
  } detail: {
    Text("Welcome.")
  }
}
