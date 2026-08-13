import AppKit
import SwiftUI

@MainActor
final class AgentSetupWindowController: NSWindowController, NSWindowDelegate {
  private static var shared: AgentSetupWindowController?

  private let model: AgentSetupWizardModel
  private let appBridge: AppBridge

  static func show(using dependencies: AppDependencies, sender: Any? = nil) {
    if shared == nil {
      shared = AgentSetupWindowController(dependencies: dependencies)
    }
    shared?.showWindow(sender)
  }

  static func prepareForApplicationTermination() {
    shared?.model.cancelForApplicationTermination()
  }

  init(dependencies: AppDependencies) {
    let windowID = UUID()
    let appBridge = dependencies.appBridge.bound(to: windowID)
    self.appBridge = appBridge
    model = AgentSetupWizardModel(dependencies: dependencies)

    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: CGSize(width: 620, height: 520)),
      styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    super.init(window: window)
    appBridge.registerWindow(window)

    window.title = "Set Up an Inline Agent"
    window.toolbarStyle = .unified
    window.minSize = NSSize(width: 560, height: 460)
    window.center()
    window.delegate = self
    window.contentViewController = NSHostingController(
      rootView: AgentSetupWizardView(model: model)
        .environment(dependencies: dependencies.with(appBridge: appBridge))
    )
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    window?.makeKeyAndOrderFront(nil)
    appBridge.activate(ignoringOtherApps: true)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if model.isBusy {
      NSSound.beep()
      return false
    }
    return true
  }

  func windowWillClose(_ notification: Notification) {
    model.cancel()
    appBridge.unregisterWindow()
    Self.shared = nil
  }
}
