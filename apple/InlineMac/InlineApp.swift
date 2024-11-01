import Sentry
import SwiftUI
import InlineKit

@main
struct InlineApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject var viewModel = MainWindowViewModel()
    @StateObject var ws = WebSocketManager()

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindow()
                .environmentObject(ws)
                .environmentObject(viewModel)
                .appDatabase(.shared)
        }
        .defaultSize(width: 900, height: 600)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands { MainWindowCommands() }

        Settings {
            SettingsView()
                .environmentObject(ws)
                .environmentObject(viewModel)
                .appDatabase(.shared)
        }
    }
}


// MARK: - Database
extension EnvironmentValues {
    @Entry var appDatabase = AppDatabase.empty()
}

extension View {
    func appDatabase(_ appDatabase: AppDatabase) -> some View {
        self.environment(\.appDatabase, appDatabase)
    }
}