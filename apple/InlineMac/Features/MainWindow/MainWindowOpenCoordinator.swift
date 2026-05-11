import AppKit
import InlineKit

enum MainWindowDestination: Hashable, Codable {
  case chat(peer: Peer)

  var route: Nav3Route {
    switch self {
    case let .chat(peer):
      .chat(peer: peer)
    }
  }
}

@MainActor
final class MainWindowOpenCoordinator {
  static let shared = MainWindowOpenCoordinator()

  private struct WindowEntry {
    weak var window: NSWindow?
    weak var toastPresenter: (any ToastPresenting)?
    let route: @MainActor (MainWindowDestination) -> Void
    let openCommandBar: @MainActor () -> Void
    let toggleSidebar: @MainActor () -> Void
    var navigateChat: (@MainActor (_ offset: Int) -> Void)?
    var renameThread: (@MainActor () -> Bool)?
  }

  private var pendingDestination: MainWindowDestination?
  private var openMainWindow: (() -> Void)?
  private var openOnboardingWindow: (() -> Void)?
  private var windows: [UUID: WindowEntry] = [:]
  private var sidebarNavigation: [UUID: @MainActor (_ offset: Int) -> Void] = [:]
  private var threadRenaming: [UUID: @MainActor () -> Bool] = [:]

  func register(
    openMainWindow: @escaping () -> Void,
    openOnboardingWindow: (() -> Void)? = nil
  ) {
    self.openMainWindow = openMainWindow
    self.openOnboardingWindow = openOnboardingWindow
  }

  func registerWindow(
    id: UUID,
    window: NSWindow?,
    toastPresenter: (any ToastPresenting)?,
    route: @escaping @MainActor (MainWindowDestination) -> Void,
    openCommandBar: @escaping @MainActor () -> Void,
    toggleSidebar: @escaping @MainActor () -> Void
  ) {
    guard let window else {
      unregisterWindow(id: id)
      return
    }

    windows[id] = WindowEntry(
      window: window,
      toastPresenter: toastPresenter,
      route: route,
      openCommandBar: openCommandBar,
      toggleSidebar: toggleSidebar,
      navigateChat: sidebarNavigation[id],
      renameThread: threadRenaming[id]
    )
  }

  func unregisterWindow(id: UUID) {
    windows.removeValue(forKey: id)
    sidebarNavigation.removeValue(forKey: id)
    threadRenaming.removeValue(forKey: id)
  }

  func registerSidebarNavigation(
    id: UUID,
    navigate: @escaping @MainActor (_ offset: Int) -> Void
  ) {
    sidebarNavigation[id] = navigate
    guard var entry = windows[id] else { return }
    entry.navigateChat = navigate
    windows[id] = entry
  }

  func unregisterSidebarNavigation(id: UUID) {
    sidebarNavigation.removeValue(forKey: id)
    guard var entry = windows[id] else { return }
    entry.navigateChat = nil
    windows[id] = entry
  }

  func registerRenameThread(
    id: UUID,
    rename: @escaping @MainActor () -> Bool
  ) {
    threadRenaming[id] = rename
    guard var entry = windows[id] else { return }
    entry.renameThread = rename
    windows[id] = entry
  }

  func unregisterRenameThread(id: UUID) {
    threadRenaming.removeValue(forKey: id)
    guard var entry = windows[id] else { return }
    entry.renameThread = nil
    windows[id] = entry
  }

  func resetWindows() {
    pendingDestination = nil
    windows.removeAll()
    sidebarNavigation.removeAll()
    threadRenaming.removeAll()
  }

  func openWindow(_ destination: MainWindowDestination) {
    if routeExistingWindow(to: destination) {
      return
    }

    openNewWindow(destination)
  }

  func openNewWindow(_ destination: MainWindowDestination) {
    pendingDestination = destination
    openMainWindow?()
  }

  func openTab(_ destination: MainWindowDestination) {
    pendingDestination = destination
    openTab()
  }

  func openTab() {
    guard let currentWindow = NSApp.keyWindow,
          entry(for: currentWindow) != nil,
          let windowController = currentWindow.windowController
    else {
      openMainWindow?()
      return
    }

    windowController.newWindowForTab(nil)
  }

  @discardableResult
  func selectTab(at position: Int) -> Bool {
    guard position > 0, let tabGroup = tabGroupForSelection() else { return false }

    let index = position - 1
    let windows = tabGroup.windows
    guard windows.indices.contains(index) else { return false }

    let window = windows[index]
    guard tabGroup.selectedWindow !== window else { return true }

    tabGroup.selectedWindow = window
    window.makeKeyAndOrderFront(nil)
    return true
  }

  func openDefaultWindow() {
    openMainWindow?()
  }

  @discardableResult
  func openCommandBar() -> Bool {
    guard let entry = activeEntry() else {
      openMainWindow?()
      return false
    }

    entry.openCommandBar()
    focus(entry)
    return true
  }

  @discardableResult
  func toggleSidebar() -> Bool {
    guard let entry = activeEntry() else { return false }
    entry.toggleSidebar()
    return true
  }

  @discardableResult
  func navigateChat(offset: Int) -> Bool {
    guard let entry = activeEntry(),
          let navigateChat = entry.navigateChat
    else { return false }

    navigateChat(offset)
    return true
  }

  @discardableResult
  func renameThread() -> Bool {
    guard let entry = activeEntry(),
          let renameThread = entry.renameThread
    else { return false }

    focus(entry)
    return renameThread()
  }

  var activeToastPresenter: (any ToastPresenting)? {
    activeEntry()?.toastPresenter
  }

  var canNavigateChat: Bool {
    activeEntry()?.navigateChat != nil
  }

  func openLaunchWindow(topLevelRoute: TopLevelRoute) {
    switch topLevelRoute {
    case .main:
      openDefaultWindow()
    case .loading, .onboarding:
      openOnboarding()
    }
  }

  func openOnboarding() {
    if let openOnboardingWindow {
      openOnboardingWindow()
    } else {
      openMainWindow?()
    }
  }

  func consumePendingDestination() -> MainWindowDestination? {
    defer { pendingDestination = nil }
    return pendingDestination
  }

  private func routeExistingWindow(to destination: MainWindowDestination) -> Bool {
    removeClosedWindows()

    if let entry = entry(for: NSApp.keyWindow) {
      route(destination, using: entry)
      return true
    }

    if let entry = windows.values.first(where: { $0.window?.isVisible == true }) {
      route(destination, using: entry)
      return true
    }

    return false
  }

  private func activeEntry() -> WindowEntry? {
    removeClosedWindows()

    if let entry = entry(for: NSApp.keyWindow) {
      return entry
    }

    return windows.values.first { $0.window?.isVisible == true }
  }

  private func entry(for window: NSWindow?) -> WindowEntry? {
    guard let window else { return nil }
    return windows.values.first { $0.window === window }
  }

  private func tabGroupForSelection() -> NSWindowTabGroup? {
    if let window = NSApp.keyWindow, entry(for: window) != nil {
      return window.tabGroup
    }

    removeClosedWindows()
    return windows.values.first { $0.window?.isVisible == true }?.window?.tabGroup
  }

  private func route(_ destination: MainWindowDestination, using entry: WindowEntry) {
    entry.route(destination)
    focus(entry)
  }

  private func focus(_ entry: WindowEntry) {
    entry.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func removeClosedWindows() {
    windows = windows.filter { _, entry in
      entry.window?.isVisible == true || entry.window != nil
    }
    sidebarNavigation = sidebarNavigation.filter { id, _ in
      windows[id] != nil
    }
    threadRenaming = threadRenaming.filter { id, _ in
      windows[id] != nil
    }
  }
}
