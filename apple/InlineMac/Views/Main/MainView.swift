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

    
    /// 190 is minimum that fits both sidebar collapse button and plus button
    private let MIN_SIDEBAR_WIDTH: CGFloat = 200

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
                .navigationSplitViewColumnWidth(min: MIN_SIDEBAR_WIDTH, ideal: 240, max: 400)
        } detail: {
            Text("Welcome to Inline")
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
