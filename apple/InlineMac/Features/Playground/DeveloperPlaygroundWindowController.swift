#if DEBUG || DEBUG_BUILD
import AppKit
import SwiftUI

@MainActor
final class DeveloperPlaygroundWindowController: NSWindowController, NSWindowDelegate {
  private static var shared: DeveloperPlaygroundWindowController?

  static func show(sender: Any? = nil) {
    if shared == nil {
      shared = DeveloperPlaygroundWindowController()
    }
    shared?.showWindow(sender)
  }

  private init() {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: NSSize(width: 1080, height: 680)),
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
    configure(window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    window?.makeKeyAndOrderFront(sender)
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowWillClose(_ notification: Notification) {
    Self.shared = nil
  }

  private func configure(_ window: NSWindow) {
    window.title = "Playground"
    window.titleVisibility = .visible
    window.toolbarStyle = .automatic
    window.minSize = NSSize(width: 900, height: 520)
    window.setFrameAutosaveName("DeveloperPlaygroundWindow")
    window.contentViewController = NSHostingController(rootView: DeveloperPlaygroundView())
    window.delegate = self
    window.center()
  }
}
#endif
