#if SPARKLE
import AppKit
import SwiftUI

@MainActor
protocol UpdatePresenting: AnyObject {
  func show(activate: Bool)
  func closeIfNeeded()
}

@MainActor
final class UpdateWindowController: NSWindowController, UpdatePresenting {
  private let viewModel: UpdateViewModel

  init(viewModel: UpdateViewModel) {
    self.viewModel = viewModel
    let window = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.isFloatingPanel = true
    window.level = .floating
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    super.init(window: window)
    window.contentViewController = NSHostingController(
      rootView: UpdateWindowView(viewModel: viewModel)
    )
    window.center()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func show(activate: Bool) {
    guard let window else { return }
    if activate {
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
      return
    }
    if NSApp.isActive {
      window.makeKeyAndOrderFront(nil)
    }
  }

  func closeIfNeeded() {
    window?.orderOut(nil)
  }
}
#endif
