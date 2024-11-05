import GRDB
import InlineKit
import InlineUI
import SwiftUI

struct MainView: View {
    @EnvironmentObject var windowViewModel: MainWindowViewModel
    @EnvironmentObject var ws: WebSocketManager
    @EnvironmentObject var navigation: NavigationModel

    // Fetch authenticated user data
    @EnvironmentStateObject var rootData: RootData
    @EnvironmentStateObject var dataManager: DataManager

    init() {
        _rootData = EnvironmentStateObject { env in
            RootData(db: env.appDatabase, auth: env.auth)
        }
        _dataManager = EnvironmentStateObject { env in
            DataManager(database: env.appDatabase)
        }
    }

    var body: some View {
        NavigationSplitView {
            // TODO: check active space / chat / etc??
            HomeSidebar()
                .navigationDestination(for: NavigationRoute.self) { route in
                    // WIP
                    switch route {
                    case .home:
                        Text("Home")
                    case .space(let id):
                        Text("Space \(id)")
                            .navigationTitle("Space")
                    case .chat(let peer):
                        Text("Chat \(peer)")
                            .navigationTitle("Chat")
                    }
                }
                // it must be below nav destination or it's not enforced
                .navigationSplitViewColumnWidth(min: Theme.minimumSidebarWidth, ideal: 240, max: 400)
        } detail: {
            NavigationStack(path: $navigation.path) {
                Text("Welcome to Inline")
                    .navigationTitle("Home")
            }
        }
        .navigationSplitViewStyle(.prominentDetail)
        .sheet(isPresented: $navigation.createSpaceSheetPresented) {
            CreateSpaceSheet()
        }
        .environmentObject(rootData)
        .environmentObject(dataManager)
        .task {
            rootData.fetch()
        }
    }
}

#Preview {
    MainView()
        .previewsEnvironment(.empty)
        .environmentObject(NavigationModel())
}
