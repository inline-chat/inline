#if SPARKLE
import AppKit
import SwiftUI

@MainActor
protocol UpdatePresenting: AnyObject {
  func show(activate: Bool)
  func closeIfNeeded()
}

@MainActor
final class UpdateWindowController: NSWindowController, NSWindowDelegate, UpdatePresenting {
  private let controller: UpdateController

  init(controller: UpdateController) {
    self.controller = controller

    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: UpdateWindowView.contentSize),
      styleMask: [.titled, .closable],
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

  func show(activate: Bool) {
    guard let window else { return }
    guard activate || NSApp.isActive else { return }

    if activate {
      NSApp.activate(ignoringOtherApps: true)
    }

    window.makeKeyAndOrderFront(nil)
  }

  func closeIfNeeded() {
    window?.orderOut(nil)
  }

  func windowShouldClose(_: NSWindow) -> Bool {
    switch controller.phase {
    case .idle, .upToDate, .failed:
      controller.dismissStatus()
    case .checking, .downloading:
      controller.cancel()
    case .updateAvailable, .readyToInstall:
      controller.remindLater()
    case .extracting, .installing:
      closeIfNeeded()
    }
    return false
  }

  private func configure(_ window: NSWindow) {
    let contentSize = UpdateWindowView.contentSize
    window.title = "Software Update"
    window.level = .normal
    window.animationBehavior = .documentWindow
    window.collectionBehavior = [.moveToActiveSpace]
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.delegate = self

    let hostingController = NSHostingController(
      rootView: UpdateWindowView(controller: controller)
    )
    hostingController.sizingOptions = [.preferredContentSize]
    hostingController.preferredContentSize = contentSize
    window.contentViewController = hostingController

    window.setContentSize(contentSize)
    window.contentMinSize = contentSize
    window.contentMaxSize = contentSize
    window.center()
  }
}
#endif
