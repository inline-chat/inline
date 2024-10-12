import SwiftUI
import Sentry

@main
struct InlineApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindow()
        }
        .defaultSize(width: 900, height: 600)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands { MainWindowCommands() }
    }
}
