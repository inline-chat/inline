import InlineKit
import SwiftUI

struct SpaceSidebar: View {
    @EnvironmentObject var ws: WebSocketManager
    @EnvironmentObject var navigation: NavigationModel
    @EnvironmentObject var data: DataManager

    @EnvironmentStateObject var fullSpace: FullSpaceViewModel

    var spaceId: Int64

    init(spaceId: Int64) {
        self.spaceId = spaceId
        _fullSpace = EnvironmentStateObject { env in
            FullSpaceViewModel(db: env.appDatabase, spaceId: spaceId)
        }
    }

    var body: some View {
        List(selection: navigation.spaceSelection) {
            Section("Threads") {
                NavigationLink(value: NavigationRoute.chat(peer: Peer(threadId: 1))) {
                    Text("Main")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, content: {
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
        })
        // Extract ???
        .overlay(alignment: .bottom, content: {
            ConnectionStateOverlay()
        })
        .task {
//            await data.getFullSpace(spaceId: spaceId)
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
