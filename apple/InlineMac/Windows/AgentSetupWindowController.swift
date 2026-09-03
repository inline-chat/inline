import AppKit
import SwiftUI

@MainActor
final class AgentSetupWindowController: NSWindowController, NSWindowDelegate {
  private static var shared: AgentSetupWindowController?
  private static let contentSize = NSSize(width: 560, height: 460)
  private static let minimumContentSize = NSSize(width: 540, height: 420)

  private let model: AgentSetupWizardModel
  private let appBridge: AppBridge
  private var isPresentingCancellationAlert = false
  private var closesAfterCancellation = false

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
      contentRect: NSRect(origin: .zero, size: Self.contentSize),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    super.init(window: window)
    appBridge.registerWindow(window)

    window.title = "Agent Setup"
    window.toolbarStyle = .unified
    window.tabbingMode = .disallowed
    window.contentMinSize = Self.minimumContentSize
    window.delegate = self
    let hostingController = NSHostingController(
      rootView: AgentSetupWizardView(model: model)
        .environment(dependencies: dependencies.with(appBridge: appBridge))
    )
    hostingController.sizingOptions = []
    window.contentViewController = hostingController
    window.setContentSize(Self.contentSize)
    window.center()
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
    if closesAfterCancellation {
      return true
    }
    if model.isBusy {
      presentCancellationAlert(for: sender)
      return false
    }
    return true
  }

  func windowWillClose(_ notification: Notification) {
    model.cancel()
    appBridge.unregisterWindow()
    Self.shared = nil
  }

  private func presentCancellationAlert(for window: NSWindow) {
    guard !isPresentingCancellationAlert else { return }
    isPresentingCancellationAlert = true
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Cancel Agent Setup?"
    alert.informativeText = "Inline will stop the current setup command. Work that already completed may remain configured."
    alert.addButton(withTitle: "Keep Setting Up")
    let cancelButton = alert.addButton(withTitle: "Cancel Setup")
    cancelButton.hasDestructiveAction = true
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }
      isPresentingCancellationAlert = false
      if response == .alertSecondButtonReturn {
        closesAfterCancellation = true
        model.cancelOperation()
        window.performClose(nil)
      }
    }
  }
}
