import AppKit
import Logger
import SwiftUI

@MainActor
class SettingsWindowController: NSWindowController, NSWindowDelegate {
  private let log = Log.scoped("SettingsWindowController")
  private let dependencies: AppDependencies
  private let appBridge: AppBridge
  private let navigation: SettingsNavigationModel
  private static var shared: SettingsWindowController?

  static func show(
    using dependencies: AppDependencies,
    selectedCategory: SettingsCategory? = nil,
    sender: Any? = nil
  ) {
    if shared == nil {
      shared = SettingsWindowController(
        dependencies: dependencies,
        selectedCategory: selectedCategory ?? .general
      )
    } else if let selectedCategory {
      shared?.navigation.selectedCategory = selectedCategory
    }
    shared?.showWindow(sender)
  }

  init(
    dependencies: AppDependencies,
    selectedCategory: SettingsCategory = .general
  ) {
    let windowID = UUID()
    let appBridge = dependencies.appBridge.bound(to: windowID)
    self.appBridge = appBridge
    self.dependencies = dependencies.with(appBridge: appBridge)
    navigation = SettingsNavigationModel(selectedCategory: selectedCategory)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: CGSize(width: 840, height: 640)),
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
    window.toolbarStyle = .unified
    window.backgroundColor = Theme.settingsWindowBackgroundColor
    window.minSize = NSSize(width: 780, height: 520)
    if !window.setFrameUsingName("SettingsWindow") {
      window.center()
    }
    window.setFrameAutosaveName("SettingsWindow")
    window.delegate = self

    // Set up SwiftUI content with dependencies
    let contentView = SettingsRootView(navigation: navigation)
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
