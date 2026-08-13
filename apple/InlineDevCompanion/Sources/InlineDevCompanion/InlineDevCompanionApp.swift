import AppKit
import SwiftUI

@main
@MainActor
struct InlineDevCompanionApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var inventory = InventoryStore.shared

  var body: some Scene {
    MenuBarExtra("Inline Dev Companion", systemImage: "wrench.and.screwdriver") {
      CompanionDashboardView(inventory: inventory, presentation: .menuBar)
    }
    .menuBarExtraStyle(.window)

    Window("Inline Dev Companion", id: "control-panel") {
      CompanionDashboardView(inventory: inventory, presentation: .window)
        .frame(minWidth: 440, minHeight: 320)
    }
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)
    .defaultSize(width: 540, height: 620)
    .windowResizability(.contentMinSize)
    .windowToolbarStyle(.unifiedCompact)

    WindowGroup("Build Log", for: String.self) { $logPath in
      if let logPath {
        BuildLogView(logURL: URL(fileURLWithPath: logPath, isDirectory: false))
          .frame(minWidth: 520, minHeight: 280)
      } else {
        ContentUnavailableView("No Build Log", systemImage: "doc.text.magnifyingglass")
      }
    }
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)
    .defaultSize(width: 820, height: 520)
    .windowResizability(.contentMinSize)
    .windowToolbarStyle(.unifiedCompact)
  }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    LaunchAtLoginController.enable()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    InventoryStore.shared.canTerminateApplication() ? .terminateNow : .terminateCancel
  }
}
