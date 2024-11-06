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
        List {
            Section("Threads") {
                NavigationLink(destination: Text("Hi")) {
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
                        .font(.title2)
                        .fontWeight(.bold)
                    Spacer()
                }

                SearchBar()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
        })
        // Extract ???
        .overlay(alignment: .bottom, content: {
            ConnectionStateOverlay()
        })
        .task {
            do {
                // Fetch full space
            } catch {
                // TODO: handle error? keep on loading? retry? (@mo)
            }
        }
    }
}

@available(macOS 14, *)
#Preview {
    @Previewable @Namespace var namespace

    NavigationSplitView {
        SpaceSidebar(spaceId: 2, namespace: namespace)
            .previewsEnvironment(.populated)
            .environmentObject(NavigationModel())
    } detail: {
        Text("Welcome.")
    }
}
