import AppKit
import Combine
import InlineKit
import InlineMacUI

@MainActor
final class FilesWindowController: NSWindowController, NSWindowDelegate {
  private static var current: FilesWindowController?
  private let browser: FileBrowserViewController
  private var accountObservation: AnyCancellable?

  static func show(dependencies: AppDependencies) {
    guard ExperimentalFeatureFlags.fileBrowserEnabled, dependencies.auth.getCurrentUserId() != nil else { return }
    if let current {
      current.showWindow(nil)
      current.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = FilesWindowController(dependencies: dependencies)
    current = controller
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  static func closeIfOpen() {
    current?.close()
  }

  private init(dependencies: AppDependencies) {
    browser = FileBrowserViewController(database: dependencies.database) { peer, messageID in
      let main = MainWindowController.showDefault(dependencies: dependencies)
      main.openChat(peer: peer, targetMessageId: messageID)
      main.window?.makeKeyAndOrderFront(nil)
    }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered, defer: false
    )
    super.init(window: window)
    window.title = "Files"
    window.minSize = NSSize(width: 600, height: 350)
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.contentViewController = browser
    window.delegate = self
    window.center()
    window.setFrameAutosaveName("InlineFilesWindow")
    let accountID = dependencies.auth.getCurrentUserId()
    accountObservation = dependencies.auth.$currentUserId.removeDuplicates().sink { [weak self] userID in
      if userID != accountID { self?.close() }
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError()
  }

  func windowWillClose(_ notification: Notification) {
    accountObservation?.cancel()
    browser.stop()
    Self.current = nil
  }
}
