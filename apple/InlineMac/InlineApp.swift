import GRDB
import GRDBQuery
import InlineKit
import Sentry
import SwiftUI

@main
struct InlineApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject var viewModel = MainWindowViewModel()
    @StateObject var ws = WebSocketManager()
    @StateObject var navigation = NavigationModel()
    @StateObject var auth = Auth.shared

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindow()
                .environmentObject(self.ws)
                .environmentObject(self.viewModel)
                .environmentObject(self.navigation)
                .environment(\.auth, auth)
                .appDatabase(AppDatabase.shared)
        }
        .defaultSize(width: 900, height: 600)
//        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            MainWindowCommands()

            // Create Space
            if auth.isLoggedIn {
                CommandGroup(after: .newItem) {
                    Button(action: createSpace) {
                        Text("Create Space")
                    }
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(self.ws)
                .environmentObject(self.viewModel)
                .environment(\.auth, Auth.shared)
                .appDatabase(AppDatabase.shared)
        }
    }
    
    private func createSpace() {
        navigation.createSpaceSheetPresented = true
    }
}
