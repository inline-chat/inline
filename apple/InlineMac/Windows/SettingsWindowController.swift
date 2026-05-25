import AppKit
import Logger
import SwiftUI

@MainActor
class SettingsWindowController: NSWindowController, NSWindowDelegate {
  private let log = Log.scoped("SettingsWindowController")
  private let dependencies: AppDependencies
  private let appBridge: AppBridge
  private static var shared: SettingsWindowController?

  static func show(using dependencies: AppDependencies, sender: Any? = nil) {
    if shared == nil {
      shared = SettingsWindowController(dependencies: dependencies)
    }
    shared?.showWindow(sender)
  }

  init(dependencies: AppDependencies) {
    let windowID = UUID()
    let appBridge = dependencies.appBridge.bound(to: windowID)
    self.appBridge = appBridge
    self.dependencies = dependencies.with(appBridge: appBridge)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: CGSize(width: 800, height: 600)),
      styleMask: [
        .titled,
        .closable,
        .resizable,
        .miniaturizable,
        .fullSizeContentView,
      ],
      backing: .buffered,
      defer: false
    )

    super.init(window: window)
    appBridge.registerWindow(window)
    configureWindow()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func configureWindow() {
    guard let window else { return }

    window.title = "Settings"
    window.titleVisibility = .visible
    window.titlebarAppearsTransparent = false
    window.toolbarStyle = .automatic
    window.setFrameAutosaveName("SettingsWindow")
    window.minSize = NSSize(width: 600, height: 400)
    window.center()
    window.delegate = self

    // Set up SwiftUI content with dependencies
    let contentView = SettingsRootView()
      .environment(dependencies: dependencies)
    let hostingController = NSHostingController(rootView: contentView)
    window.contentViewController = hostingController

    log.debug("Settings window configured")
  }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    window?.makeKeyAndOrderFront(nil)
    appBridge.activate(ignoringOtherApps: true)
  }

  func windowWillClose(_ notification: Notification) {
    appBridge.unregisterWindow()
    Self.shared = nil
  }
}
