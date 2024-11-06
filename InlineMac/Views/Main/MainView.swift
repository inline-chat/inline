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
            // ZStack needed for the transition to work
            self.sidebar
                .navigationSplitViewColumnWidth(min: Theme.minimumSidebarWidth, ideal: 240, max: 400)
        } detail: {
            NavigationStack(path: self.$navigation.path) {
                if let spaceId = navigation.activeSpaceId {
//                    SpaceView(spaceId: spaceId)
                    Text("Space View")
                } else {
                    Text("Welcome to Inline")
                }
            }
        }
        .sheet(isPresented: $navigation.createSpaceSheetPresented) {
            CreateSpaceSheet()
        }
        .environmentObject(rootData)
        .environmentObject(dataManager)
        .task {
            self.rootData.fetch()
        }
    }

    @Namespace private var sidebarNamespace

    @ViewBuilder
    var sidebar: some View {
        if let spaceId = navigation.activeSpaceId {
            SpaceSidebar(spaceId: spaceId, namespace: sidebarNamespace)
        } else {
            HomeSidebar(namespace: sidebarNamespace)
        }
    }
}

#Preview {
    MainView()
        .previewsEnvironment(.empty)
        .environmentObject(NavigationModel())
}
