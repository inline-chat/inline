import AppKit

final class AppBridge {
  private final class State {
    weak var app: NSApplication?
    var windows: [UUID: WeakWindow] = [:]

    init(app: NSApplication?) {
      self.app = app
    }
  }

  private let state: State
  private let windowID: UUID?

  init(app: NSApplication? = nil) {
    state = State(app: app)
    windowID = nil
  }

  private init(state: State, windowID: UUID?) {
    self.state = state
    self.windowID = windowID
  }

  func bound(to windowID: UUID) -> AppBridge {
    AppBridge(state: state, windowID: windowID)
  }

  @MainActor
  func registerWindow(_ window: NSWindow, id: UUID? = nil) {
    guard let id = id ?? windowID else { return }
    state.windows[id] = WeakWindow(window)
  }

  @MainActor
  func unregisterWindow(id: UUID? = nil) {
    guard let id = id ?? windowID else { return }
    state.windows[id] = nil
  }

  @MainActor
  func activate(ignoringOtherApps: Bool = true) {
    currentApp.activate(ignoringOtherApps: ignoringOtherApps)
  }

  @MainActor
  func hide() {
    currentApp.hide(nil)
  }

  @MainActor
  func openSettings(dependencies: AppDependencies, sender: Any? = nil) {
    SettingsWindowController.show(using: dependencies, sender: sender)
  }

  @MainActor
  func currentWindow() -> NSWindow? {
    window()
  }

  @MainActor
  func performWindowZoom() {
    window()?.performZoom(nil)
  }

  @MainActor
  func applyWindowBackground(_ appearance: AppWindowBackgroundAppearance) {
    guard let window = window() else { return }

    window.backgroundColor = appearance.background.nsColor
    window.isOpaque = appearance.isOpaque
  }

  @MainActor
  func setWindowTitlebarAppearsTransparent(_ appearsTransparent: Bool) {
    window()?.titlebarAppearsTransparent = appearsTransparent
  }

  @MainActor
  private func window() -> NSWindow? {
    guard let windowID else { return nil }

    pruneWindows()

    return state.windows[windowID]?.window
  }

  @MainActor
  private func pruneWindows() {
    state.windows = state.windows.filter { $0.value.window != nil }
  }

  @MainActor
  private var currentApp: NSApplication {
    state.app ?? NSApp
  }
}

struct AppWindowBackgroundAppearance {
  var background: AppWindowBackground
  var isOpaque: Bool

  static let standard = Self(
    background: .content,
    isOpaque: true
  )

  static let clear = Self(
    background: .clear,
    isOpaque: false
  )
}

enum AppWindowBackground: Equatable {
  case content
  case clear

  var nsColor: NSColor {
    switch self {
    case .content:
      Theme.windowContentBackgroundColor
    case .clear:
      .clear
    }
  }
}

private final class WeakWindow {
  weak var window: NSWindow?

  init(_ window: NSWindow) {
    self.window = window
  }
}
