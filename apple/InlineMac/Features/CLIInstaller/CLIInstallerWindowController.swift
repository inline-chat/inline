import AppKit
import InlineCLIInstaller
import SwiftUI

@MainActor
final class CLIInstallerWindowController: NSWindowController {
  private static var shared: CLIInstallerWindowController?

  private let model: CLIInstallerModel

  static func show(using dependencies: AppDependencies, sender: Any? = nil) {
    if shared == nil {
      shared = CLIInstallerWindowController(dependencies: dependencies)
    }
    shared?.present(sender: sender)
  }

  static func prepareForApplicationTermination() {
    shared?.model.cancelForApplicationTermination()
  }

  init(dependencies: AppDependencies) {
    model = CLIInstallerModel(dependencies: dependencies)

    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: CLIInstallerView.contentSize),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    super.init(window: window)
    configure(window, installer: dependencies.cliInstaller)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func present(sender: Any?) {
    guard let window else { return }
    model.start()
    NSApp.activate(ignoringOtherApps: true)

    if let sheetParent = window.sheetParent {
      sheetParent.makeKeyAndOrderFront(sender)
      return
    }

    if let parent = presentingWindow(excluding: window), parent.attachedSheet == nil {
      parent.beginSheet(window)
      parent.makeKeyAndOrderFront(sender)
      return
    }

    window.center()
    window.makeKeyAndOrderFront(sender)
  }

  private func configure(_ window: NSWindow, installer: CLIInstallerController) {
    let contentSize = CLIInstallerView.contentSize
    window.title = "Install Inline CLI"
    window.level = .normal
    window.animationBehavior = .documentWindow
    window.collectionBehavior = [.moveToActiveSpace]
    window.isReleasedWhenClosed = false

    let hostingController = NSHostingController(
      rootView: CLIInstallerView(
        model: model,
        installer: installer,
        dismiss: { [weak self] in self?.dismiss() }
      )
    )
    hostingController.sizingOptions = [.preferredContentSize]
    hostingController.preferredContentSize = contentSize
    window.contentViewController = hostingController

    window.setContentSize(contentSize)
    window.contentMinSize = contentSize
    window.contentMaxSize = contentSize
    window.center()
  }

  private func dismiss() {
    guard !model.isBusy, let window else { return }

    if let sheetParent = window.sheetParent {
      sheetParent.endSheet(window)
    } else {
      window.orderOut(nil)
    }
    Self.shared = nil
  }

  private func presentingWindow(excluding installerWindow: NSWindow) -> NSWindow? {
    let candidates = [NSApp.keyWindow, NSApp.mainWindow] + NSApp.orderedWindows.map(Optional.some)
    return candidates
      .compactMap { $0 }
      .first { window in
        window !== installerWindow
          && window.isVisible
          && window.canBecomeKey
          && !(window is NSPanel)
      }
  }
}
