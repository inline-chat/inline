import AppKit
import SwiftUI

@main
@MainActor
struct InlineDevCompanionApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var inventory = InventoryStore()

  var body: some Scene {
    MenuBarExtra("Inline Dev Companion", systemImage: "wrench.and.screwdriver") {
      CompanionMenuView(inventory: inventory)
    }
    .menuBarExtraStyle(.window)
  }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    LaunchAtLoginController.enable()
  }
}
