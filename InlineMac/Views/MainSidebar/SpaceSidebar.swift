import InlineKit
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
      Section("Threads") {
        ChatSideItem(
          selectedRoute: navigation.spaceSelection,
          item:
          SpaceSidebarItem(peerId: Peer(threadId: 1), title: "Main")
        )
      }
    }
    .listRowInsets(EdgeInsets())
    .listRowBackground(Color.clear)
    .listStyle(.sidebar)
    .safeAreaInset(
      edge: .top,
      content: {
        VStack(alignment: .leading) {
          HStack(spacing: 0) {
            // Back
            Button {
              self.navigation.goHome()
            } label: {
              Image(systemName: "chevron.left")
                .font(.title3)
                .padding(.trailing, 8)
            }
            .buttonStyle(.plain)

            Text(fullSpace.space?.name ?? "")
              .font(Theme.sidebarTopItemFont)
            Spacer()
          }.frame(height: Theme.sidebarTopItemHeight)

          SidebarSearchBar()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
      }
    )
    // Extract ???
    .overlay(
      alignment: .bottom,
      content: {
        ConnectionStateOverlay()
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
