import GRDB
import InlineKit
import InlineUI
import SwiftUI

struct MainView: View {
    @EnvironmentObject var windowViewModel: MainWindowViewModel
    @EnvironmentObject var ws: WebSocketManager

    // Fetch authenticated user data
    @EnvironmentStateObject var rootData: RootData

    init() {
        _rootData = EnvironmentStateObject { env in
            RootData(db: env.appDatabase, auth: env.auth)
        }
    }

    var body: some View {
        NavigationSplitView {
            // TODO: check active space / chat / etc??
            HomeSidebar()
                .navigationSplitViewColumnWidth(min: 160, ideal: 220, max: 380)
        } detail: {
            Text("You're logged in!")
        }
        .environmentObject(rootData)
        .task {
            rootData.fetch()
        }
    }
}

#Preview {
    MainView()
        .previewsEnvironment(.empty)
}
