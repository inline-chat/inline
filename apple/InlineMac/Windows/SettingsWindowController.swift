import AppKit
import SwiftUI
import Logger

class SettingsWindowController: NSWindowController {
  private let log = Log.scoped("SettingsWindowController")
  
  init() {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: CGSize(width: 800, height: 600)),
      styleMask: [
        .titled,
        .closable,
        .resizable,
        .fullSizeContentView
      ],
      backing: .buffered,
      defer: false
    )
    
    super.init(window: window)
    configureWindow()
  }
  
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  private func configureWindow() {
    guard let window = window else { return }
    
    window.title = "Settings"
    window.titleVisibility = .visible
    window.titlebarAppearsTransparent = false
    window.toolbarStyle = .automatic
    window.setFrameAutosaveName("SettingsWindow")
    window.minSize = NSSize(width: 600, height: 400)
    window.center()
    
    // Set up SwiftUI content
    let contentView = SettingsRootView()
    let hostingController = NSHostingController(rootView: contentView)
    window.contentViewController = hostingController
    
    log.debug("Settings window configured")
  }
  
  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}