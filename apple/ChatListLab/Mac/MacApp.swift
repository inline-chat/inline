import AppKit

@main
@MainActor
struct MacApp {
  static func main() {
    let application = NSApplication.shared
    let applicationDelegate = MacAppDelegate()
    application.delegate = applicationDelegate
    application.run()
    withExtendedLifetime(applicationDelegate) {}
  }
}

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
  private var window: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let window = NSWindow(
      contentRect: CGRect(x: 150, y: 100, width: 900, height: 720),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false
    )
    window.title = "ChatList Package Lab"
    window.contentViewController = MacLabController()
    window.makeKeyAndOrderFront(nil)
    self.window = window
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
