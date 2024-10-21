import Sentry
import SwiftUI

@main
struct InlineApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject var viewModel = MainWindowViewModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindow()
                .environmentObject(viewModel)
        }
        .defaultSize(width: 900, height: 600)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands { MainWindowCommands() }

        Settings {
            SettingsView()
                .environmentObject(viewModel)
        }
    }
}
