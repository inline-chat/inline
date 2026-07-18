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
  private let controller: UpdateController

  init(controller: UpdateController) {
    self.controller = controller

    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: UpdateWindowView.contentSize),
      styleMask: [.titled],
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

    if let sheetParent = window.sheetParent {
      sheetParent.makeKeyAndOrderFront(nil)
      return
    }

    if let parent = presentingWindow(excluding: window), parent.attachedSheet == nil {
      parent.beginSheet(window)
      parent.makeKeyAndOrderFront(nil)
      return
    }

    window.center()
    window.makeKeyAndOrderFront(nil)
  }

  func closeIfNeeded() {
    guard let window else { return }

    if let sheetParent = window.sheetParent {
      sheetParent.endSheet(window)
    } else {
      window.orderOut(nil)
    }
  }

  private func configure(_ window: NSWindow) {
    let contentSize = UpdateWindowView.contentSize
    window.title = "Software Update"
    window.level = .normal
    window.animationBehavior = .documentWindow
    window.collectionBehavior = [.moveToActiveSpace]
    window.isReleasedWhenClosed = false

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

  private func presentingWindow(excluding updateWindow: NSWindow) -> NSWindow? {
    let candidates = [NSApp.keyWindow, NSApp.mainWindow] + NSApp.orderedWindows.map(Optional.some)
    return candidates
      .compactMap { $0 }
      .first { window in
        window !== updateWindow
          && window.isVisible
          && window.canBecomeKey
          && !(window is NSPanel)
      }
  }
}
#endif
