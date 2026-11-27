#if DEBUG
import AppKit
import InlineKit
import InlineMacUI

/// Debug builds only. `--context-menu-demo [message index]` opens the message context menu in the real
/// app, unattended, so the menu can be checked and captured with the harness data (`--perf-harness`).
///
/// It goes through AppKit's own right-click path (a right-mouse-down sent to the window, so hit testing,
/// `menu(for:)` and the text view delegates run as for a real click), then walks a timeline the capture
/// script follows: light idle (2 s), light with a row highlighted (4 s), closed (6 s), dark idle (7 s),
/// dark highlighted (9 s), closed (11 s). Each step is logged to `tmp/context-menu-demo/steps.log` in the
/// app container with the menu and window frames.
@MainActor
enum ContextMenuDemo {
  private static var log: [String] = []
  private static let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("context-menu-demo")

  static func startIfRequested() {
    let arguments = CommandLine.arguments
    guard let flag = arguments.firstIndex(of: "--context-menu-demo") else { return }
    let index = arguments.indices.contains(flag + 1) ? Int(arguments[flag + 1]) ?? 0 : 0
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // The harness's long one-to-one chat (`PerfHarnessFixture`, peer user 2).
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(3))
      MainWindowController.all.first?.openChat(peer: .user(id: 2), targetMessageId: nil)
    }
    let start = Date()
    var opened = false
    var appearance: NSAppearance.Name = .aqua
    let timer = Timer(timeInterval: 0.25, repeats: true) { timer in
      MainActor.assumeIsolated {
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 6 else { return }
        let t = elapsed - 6
        switch t {
        case _ where !opened && t >= 2 && t < 6:
          opened = open(index: index, appearance: appearance)
        case _ where opened && t >= 4 && t < 6:
          highlight()
        case _ where opened && t >= 6 && appearance == .aqua:
          ContextMenu.current?.close(animated: false)
          opened = false
          appearance = .darkAqua
        case _ where !opened && t >= 7 && t < 11 && appearance == .darkAqua:
          opened = open(index: index, appearance: appearance)
        case _ where opened && t >= 9 && t < 11:
          highlight()
        case _ where t >= 11:
          ContextMenu.current?.close(animated: false)
          record("done")
          timer.invalidate()
        default:
          break
        }
      }
    }
    RunLoop.main.add(timer, forMode: .common)
  }

  private static var highlighted = false

  private static func open(index: Int, appearance: NSAppearance.Name) -> Bool {
    highlighted = false
    guard let window = NSApp.windows.first(where: { $0.isVisible && $0.isMainWindow || $0.isKeyWindow }) ?? NSApp.windows.first(where: \.isVisible),
          let content = window.contentView else { return false }
    window.appearance = NSAppearance(named: appearance)
    window.setFrame(NSRect(x: 229, y: -860, width: 1200, height: 800), display: true)
    window.layoutIfNeeded()
    let messages = messageViews(in: content).filter { view in
      let rect = view.convert(view.bounds, to: nil)
      return content.bounds.insetBy(dx: 0, dy: 120).contains(NSPoint(x: rect.midX, y: rect.midY))
    }
    guard !messages.isEmpty else {
      record("no visible message view yet")
      return false
    }
    let view = messages[min(index, messages.count - 1)]
    let point = view.convert(NSPoint(x: min(80, view.bounds.midX), y: view.bounds.midY), to: nil)
    guard let down = NSEvent.mouseEvent(
      with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
    ) else { return false }
    window.sendEvent(down)
    if let up = NSEvent.mouseEvent(
      with: .rightMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
    ) {
      _ = ContextMenu.current?.handle(up)
    }
    let session = ContextMenu.current
    record("open \(appearance.rawValue) view=\(type(of: view)) items=\(session?.menu.items.map(\.title).filter { !$0.isEmpty }.joined(separator: "|") ?? "nil") menu=\(session?.menuScreenFrames.first.map(describe) ?? "-") accessory=\(session?.accessoryScreenFrame.map(describe) ?? "-") window=\(describe(window.frame)) eventToVisibleMs=\(session?.eventToVisible.map { String(format: "%.1f", $0 * 1000) } ?? "-")")
    return session?.isOpen == true
  }

  private static func highlight() {
    guard !highlighted, let session = ContextMenu.current, let window = NSApp.mainWindow ?? NSApp.keyWindow else { return }
    highlighted = true
    for _ in 0 ..< 2 {
      if let key = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: 125
      ) {
        _ = session.handle(key)
      }
    }
    record("highlight \(session.highlightedItem?.title ?? "nil")")
  }

  private static func messageViews(in view: NSView) -> [NSView] {
    var found: [NSView] = []
    for sub in view.subviews where !sub.isHidden {
      if sub is MessageViewAppKit || sub is MinimalMessageViewAppKit {
        found.append(sub)
      } else {
        found += messageViews(in: sub)
      }
    }
    return found.sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
  }

  private static func describe(_ rect: NSRect) -> String {
    String(format: "%.0f,%.0f %.0fx%.0f", rect.minX, rect.minY, rect.width, rect.height)
  }

  private static func record(_ line: String) {
    log.append(String(format: "%.2f ", ProcessInfo.processInfo.systemUptime) + line)
    try? log.joined(separator: "\n").write(to: directory.appendingPathComponent("steps.log"), atomically: true, encoding: .utf8)
  }
}
#endif
