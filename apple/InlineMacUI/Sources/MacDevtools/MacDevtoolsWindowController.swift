import AppKit
import SwiftUI

@MainActor
public final class MacDevtoolsWindowController: NSWindowController, NSWindowDelegate {
  private static var shared: MacDevtoolsWindowController?

  public static func show(sender: Any? = nil) {
    if shared == nil {
      shared = MacDevtoolsWindowController()
    }
    shared?.showWindow(sender)
  }

  private init() {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: NSSize(width: 980, height: 620)),
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

  override public func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    window?.makeKeyAndOrderFront(sender)
    NSApp.activate(ignoringOtherApps: true)
  }

  public func windowWillClose(_ notification: Notification) {
    Self.shared = nil
  }

  private func configure(_ window: NSWindow) {
    window.title = "MacDevtools"
    window.titleVisibility = .visible
    window.toolbarStyle = .automatic
    window.minSize = NSSize(width: 540, height: 360)
    window.setFrameAutosaveName("MacDevtoolsWindow")
    window.contentViewController = NSHostingController(rootView: MacDevtoolsView())
    window.delegate = self
    window.center()
  }
}
