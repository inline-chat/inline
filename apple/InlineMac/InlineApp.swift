import GRDBQuery
import InlineKit
import Sentry
import SwiftUI
import GRDB

@main
struct InlineApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject var viewModel = MainWindowViewModel()
    @StateObject var ws = WebSocketManager()
    
    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindow()
                .environmentObject(self.ws)
                .environmentObject(self.viewModel)
                .environment(\.auth, Auth.shared)
                .appDatabase(AppDatabase.shared)
            
        }
        .defaultSize(width: 900, height: 600)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands { MainWindowCommands() }

        Settings {
            SettingsView()
                .environmentObject(self.ws)
                .environmentObject(self.viewModel)
                .environment(\.auth, Auth.shared)
                .appDatabase(AppDatabase.shared)
        }
    }
}

// MARK: - Database

extension EnvironmentValues {
    @Entry var appDatabase = AppDatabase.empty()
    @Entry var auth = Auth.shared
}

extension View {
    func appDatabase(_ appDatabase: AppDatabase) -> some View {
        self
            .environment(\.appDatabase, appDatabase)
            .databaseContext(.readWrite { appDatabase.dbWriter })
    }
}
