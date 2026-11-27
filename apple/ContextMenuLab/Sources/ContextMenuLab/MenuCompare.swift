import AppKit
import InlineContextMenu

/// Native and custom menus for the same message, at the same point, over the same window, in light and
/// dark, idle and with a row highlighted from the keyboard. `--compare <dir>` writes PNG pairs.
@MainActor
enum MenuCompare {
  static func run(controller: LabWindowController, dir: String, bubbleIndex: Int) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let window = controller.window
    window.orderFrontRegardless()
    controller.lab.animation = .none

    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      window.appearance = NSAppearance(named: appearance)
      spin(0.4)
      for kind in ["native", "custom"] {
        controller.setMode(kind == "native" ? .native : .custom)
        guard let bubble = controller.bubbles[bubbleIndex] as? BubbleView else { return }
        let local = bubble.convert(NSPoint(x: 30, y: bubble.bounds.midY), to: nil)
        let anchor = window.convertPoint(toScreen: local)
        guard let event = NSEvent.mouseEvent(
          with: .rightMouseDown, location: local, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ) else { return }
        let screenHeight = NSScreen.screens.first?.frame.height ?? 1000
        let rect = CGRect(x: anchor.x - 30, y: screenHeight - (anchor.y + 70), width: 330, height: 470)
        let prefix = (dir as NSString).appendingPathComponent("\(kind)-\(name)")

        // Shots and keys from another thread: the native menu blocks the main thread while it tracks.
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
          Thread.sleep(forTimeInterval: 0.7)
          capture(rect, to: prefix + ".png")
          captureMenuWindows(prefix: prefix + "-window")
          postKey(125)
          Thread.sleep(forTimeInterval: 0.08)
          postKey(125)
          Thread.sleep(forTimeInterval: 0.9)
          capture(rect, to: prefix + "-hover.png")
          captureMenuWindows(prefix: prefix + "-hover-window")
          postKey(53)
          done.signal()
        }
        if kind == "native" {
          guard let menu = controller.lab.menu(for: bubble, event: event, nativeTextMenu: nil) else { return }
          let start = Date()
          NSMenu.popUpContextMenu(menu, with: event, for: bubble)
          print("native \(name) tracked \(String(format: "%.2f", Date().timeIntervalSince(start)))s active=\(NSApp.isActive)")
        } else {
          _ = controller.lab.menu(for: bubble, event: event, nativeTextMenu: nil)
          // Let the opening press end in place, as a quick right click does.
          if let up = NSEvent.mouseEvent(
            with: .rightMouseUp, location: local, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
          ) { _ = ContextMenuSession.current?.handle(up) }
        }
        let deadline = Date().addingTimeInterval(6)
        // Dispatch events, not only run-loop sources: the custom menu sees keys through the app's event flow.
        while done.wait(timeout: .now()) == .timedOut, Date() < deadline {
          if let next = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) {
            NSApp.sendEvent(next)
          }
        }
        ContextMenuSession.closeAll()
        spin(0.3)
      }
    }
    print(controller.lab.logLines.suffix(40).joined(separator: "\n"))
    print("compare shots in \(dir)")
    NSApp.terminate(nil)
  }

  /// A short screen recording of the custom menu: hover down the rows (icon effects), then the keyboard
  /// into the reactions bar. `--record <file.mov>`.
  static func record(controller: LabWindowController, path: String, bubbleIndex: Int, dark: Bool) {
    let window = controller.window
    window.orderFrontRegardless()
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    controller.setMode(.custom)
    controller.lab.animation = .pop
    spin(0.4)
    guard let bubble = controller.bubbles[bubbleIndex] as? BubbleView else { return }
    let local = bubble.convert(NSPoint(x: 30, y: bubble.bounds.midY), to: nil)
    let anchor = window.convertPoint(toScreen: local)
    let screenHeight = NSScreen.screens.first?.frame.height ?? 1000
    let rect = CGRect(x: anchor.x - 30, y: screenHeight - (anchor.y + 70), width: 330, height: 480)

    let recorder = Process()
    recorder.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    recorder.arguments = ["-x", "-v", "-V", "11", "-R\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", path]
    try? recorder.run()
    spin(1.2)

    guard let event = NSEvent.mouseEvent(
      with: .rightMouseDown, location: local, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
    ) else { return }
    _ = controller.lab.menu(for: bubble, event: event, nativeTextMenu: nil)
    if let up = NSEvent.mouseEvent(
      with: .rightMouseUp, location: local, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
    ) { _ = ContextMenuSession.current?.handle(up) }
    spin(0.6)

    let titles = ["Reply", "Reply in Thread", "Copy Text", "Copy Message Link", "Edit", "Pin", "Select", "Create Linear Issue", "Delete"]
    for title in titles {
      guard let session = ContextMenuSession.current, let frame = session.rootAccessibilityElement(title: title)?.accessibilityFrame() else { continue }
      let point = NSPoint(x: frame.midX - 40, y: frame.midY)
      if let move = NSEvent.mouseEvent(
        with: .mouseMoved, location: window.convertPoint(fromScreen: point), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
      ) { _ = session.handle(move) }
      spin(0.55)
    }
    // Keyboard: to the top, up into the bar, along it.
    let session = ContextMenuSession.current
    func key(_ code: UInt16) {
      if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) {
        _ = session?.handle(event)
      }
    }
    key(115) // Home
    spin(0.4)
    key(126)
    spin(0.5)
    for _ in 0 ..< 3 { key(124); spin(0.35) }
    spin(0.4)
    key(53)
    spin(0.8)
    recorder.waitUntilExit()
    print("recorded \(path)")
    NSApp.terminate(nil)
  }

  private static func spin(_ seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.main.run(mode: .default, before: end) }
  }

  nonisolated private static func capture(_ rect: CGRect, to path: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-R\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", path]
    try? process.run()
    process.waitUntilExit()
  }

  /// Window captures of our level-101 windows (menu glass and panels): a window capture of the native
  /// glass window includes what is composited behind it.
  nonisolated private static func captureMenuWindows(prefix: String) {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    var index = 0
    for info in list where (info[kCGWindowOwnerPID as String] as? Int32) == getpid() && (info[kCGWindowLayer as String] as? Int) == 101 {
      guard let id = info[kCGWindowNumber as String] as? Int else { continue }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      process.arguments = ["-x", "-o", "-l\(id)", "\(prefix)\(index).png"]
      try? process.run()
      process.waitUntilExit()
      index += 1
    }
  }

  nonisolated private static func postKey(_ code: CGKeyCode) {
    for down in [true, false] {
      CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.postToPid(getpid())
    }
  }
}
