#if DEBUG
import AppKit
import SwiftUI

@MainActor
final class RichMessageTestBookWindowController: NSWindowController, NSWindowDelegate {
  private static var shared: RichMessageTestBookWindowController?

  static func show(sender: Any? = nil) {
    if shared == nil {
      shared = RichMessageTestBookWindowController()
    }
    shared?.showWindow(sender)
  }

  init() {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: CGSize(width: 820, height: 720)),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
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
    guard let window else { return }

    window.title = "Rich Text Testbook"
    window.minSize = NSSize(width: 700, height: 520)
    window.isRestorable = false
    window.setFrameAutosaveName("RichMessageTestBookWindow")
    window.center()
    window.delegate = self
    window.contentViewController = NSHostingController(rootView: RichMessageBlockTestBookView())
  }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    window?.makeKeyAndOrderFront(sender)
    window?.orderFrontRegardless()
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowWillClose(_ notification: Notification) {
    Self.shared = nil
  }
}
#endif
