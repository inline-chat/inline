import SwiftUI

@main
struct InlineApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindow()
        }
        .defaultSize(width: 840, height: 560)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands { MainWindowCommands() }
    }
}
