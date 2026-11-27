#if DEBUG
import AppKit
import InlineKit
import SwiftUI

/// Debug builds only: `--window-sizing-probe` drives the main window through resize and sidebar
/// toggles and writes what holds its width after every step: window frame and min size, the root
/// hosting view, the split view, each split item (minimum thickness, holding priority, collapse)
/// and the constraints that set each column's width. Run with `--perf-harness` for a signed-in
/// window on fixture chats. Output: `<container tmp>/window-sizing-probe/<label>.log`.
@MainActor
enum WindowSizingProbe {
  static var isRequested: Bool { CommandLine.arguments.contains("--window-sizing-probe") }

  private static var logURL: URL?

  /// `--window-sizing-options none|min|intrinsic|standard` overrides the root hosting controller's
  /// sizing options, to compare how each lets the window follow SwiftUI's sizes.
  static func start(openChat: @escaping (Peer) -> Void) {
    Task { @MainActor in await run(openChat: openChat) }
  }

  private static func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
  }

  private static func run(openChat: (Peer) -> Void) async {
    let label = argument("--window-sizing-probe-label") ?? "probe"
    let outDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("window-sizing-probe", isDirectory: true)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    logURL = outDir.appendingPathComponent("\(label).log")
    try? Data().write(to: logURL!)

    var window: NSWindow?
    for _ in 0 ..< 400 {
      window = NSApp.windows.first { $0.isVisible && $0.windowController is MainWindowController }
      if window != nil { break }
      await sleep(ms: 50)
    }
    guard let window else {
      note("no main window")
      done(outDir: outDir, label: label)
      return
    }
    await sleep(ms: 3000)

    // Steps: "w<width>" resizes (top-left fixed), "t" toggles the sidebar, "c" opens a chat,
    // "e" opens the empty route, "d" just dumps.
    let script = argument("--window-sizing-probe-steps")
      ?? "c,d,w700,w1460,t,w1000,t,w1000,w700"
    for step in script.split(separator: ",").map(String.init) {
      switch step.first {
        case "w":
          let width = CGFloat(Double(step.dropFirst()) ?? 900)
          var frame = window.frame
          frame.origin.y += frame.height - 640
          frame.size = NSSize(width: width, height: 640)
          window.setFrame(frame, display: true)
        case "t":
          _ = MainWindowOpenCoordinator.shared.toggleSidebar()
        case "c":
          openChat(.user(id: 2))
        case "u":
          openChat(.user(id: Int64(step.dropFirst()) ?? 3))
        case "s":
          // The shell captures the window while the probe waits (see the `snap` line).
          note("snap \(step) \(window.windowNumber)")
          await sleep(ms: 2500)
        case "r":
          await liveResize(window, to: CGFloat(Double(step.dropFirst()) ?? 900))
        case "b":
          if let split = firstSplitView(in: window.contentView) {
            split.setPosition(CGFloat(Double(step.dropFirst()) ?? 246), ofDividerAt: 0)
          }
        case "i":
          // What a constraint change inside the split does: SwiftUI re-reads the host's layout traits.
          if let split = firstSplitView(in: window.contentView) {
            var node: NSView? = split
            while let view = node {
              view.invalidateIntrinsicContentSize()
              view.needsUpdateConstraints = true
              node = view.superview
            }
          }
        case "k":
          // A required minimum on the split, to see whether SwiftUI sizes its host from AppKit.
          if let split = firstSplitView(in: window.contentView) {
            let constraint = split.widthAnchor.constraint(greaterThanOrEqualToConstant: CGFloat(Double(step.dropFirst()) ?? 1100))
            constraint.identifier = "probe.min"
            constraint.isActive = true
          }
        case "x":
          NSApp.deactivate()
        case "f":
          // Every constraint in the window with a width-sized constant, to find the latched one.
          var found: [String] = []
          func scan(_ view: NSView, depth: Int) {
            for constraint in view.constraints where abs(constraint.constant) >= 300 {
              found.append("  [\(depth)] owner=\(type(of: view))@\(Int(view.frame.width)) \(describe(constraint)) active=\(constraint.isActive)")
            }
            for subview in view.subviews { scan(subview, depth: depth + 1) }
          }
          if let root = window.contentView?.superview { scan(root, depth: 0) }
          note("constraints >= 300:\n" + found.joined(separator: "\n"))
        case "h":
          // Detail item holding priority (its remembered width competes at this priority).
          if let split = firstSplitView(in: window.contentView),
             let controller = split.delegate as? NSSplitViewController,
             controller.splitViewItems.count > 1 {
            controller.splitViewItems[1].holdingPriority = NSLayoutConstraint.Priority(Float(Double(step.dropFirst()) ?? 250))
          }
        case "g":
          // A real mouse drag on the sidebar divider, by dx points.
          if let split = firstSplitView(in: window.contentView),
             let controller = split.delegate as? NSSplitViewController,
             let sidebar = controller.splitViewItems.first?.viewController.view {
            let dividerX = sidebar.convert(NSPoint(x: sidebar.bounds.maxX + 1, y: 0), to: nil).x
            let y = window.frame.height / 2
            let dx = CGFloat(Double(step.dropFirst()) ?? 6)
            post(.leftMouseDown, at: NSPoint(x: dividerX, y: y), in: window)
            await sleep(ms: 50)
            for index in 1 ... 10 {
              post(.leftMouseDragged, at: NSPoint(x: dividerX + dx * CGFloat(index) / 10, y: y), in: window)
              await sleep(ms: 16)
            }
            post(.leftMouseUp, at: NSPoint(x: dividerX + dx, y: y), in: window)
            await sleep(ms: 200)
            note("divider drag from \(Int(dividerX)) by \(Int(dx)) -> sidebar \(Int(sidebar.frame.width))")
          }
        case "m":
          window.minSize = NSSize(width: 500, height: 300)
          note("set minSize -> \(fmt(window.minSize))")
        case "e":
          MainWindowController.all.first?.resetNavigation()
        default:
          break
      }
      await sleep(ms: 1200)
      dump(window, step: step)
    }
    done(outDir: outDir, label: label)
    if CommandLine.arguments.contains("--window-sizing-probe-quit") {
      // A normal quit, so AppKit saves window and split view state for the next launch.
      NSApp.terminate(nil)
    }
  }

  /// Drags the bottom-right corner through the window's own live-resize loop, like a person.
  private static func liveResize(_ window: NSWindow, to width: CGFloat) async {
    let start = window.frame.width
    let corner = NSPoint(x: start - 3, y: 3)
    post(.leftMouseDown, at: corner, in: window)
    await sleep(ms: 50)
    let distance = width - start
    let steps = max(1, Int(abs(distance) / 6))
    for index in 1 ... steps {
      let dx = distance * CGFloat(index) / CGFloat(steps)
      post(.leftMouseDragged, at: NSPoint(x: corner.x + dx, y: corner.y), in: window)
      await sleep(ms: 8.33)
    }
    post(.leftMouseUp, at: NSPoint(x: corner.x + distance, y: corner.y), in: window)
    await sleep(ms: 300)
    note("live resize \(Int(start)) -> \(Int(width)) ended at \(Int(window.frame.width))")
  }

  private static var eventNumber = 0

  private static func post(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) {
    eventNumber += 1
    guard let event = NSEvent.mouseEvent(
      with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: 1,
      pressure: type == .leftMouseUp ? 0 : 1
    ) else { return }
    NSApp.postEvent(event, atStart: false)
  }

  private static func done(outDir: URL, label: String) {
    try? Data().write(to: outDir.appendingPathComponent("\(label)-done"))
  }

  private static func dump(_ window: NSWindow, step: String) {
    var lines: [String] = ["== step \(step)"]
    lines.append("window frame=\(fmt(window.frame.size)) minSize=\(fmt(window.minSize)) "
      + "contentMinSize=\(fmt(window.contentMinSize)) layoutRect=\(fmt(window.contentLayoutRect.size))")
    if let content = window.contentView {
      lines.append("root frame=\(fmt(content.frame)) fitting=\(fmt(content.fittingSize))")
    }
    guard let split = firstSplitView(in: window.contentView) else {
      lines.append("no split view")
      note(lines.joined(separator: "\n"))
      return
    }
    lines.append("split frame=\(fmt(split.frame)) inWindow=\(fmt(split.convert(split.bounds, to: nil))) "
      + "fitting=\(fmt(split.fittingSize)) hostedBy=\(chain(split))")
    if let controller = split.delegate as? NSSplitViewController {
      for (index, item) in controller.splitViewItems.enumerated() {
        let view = item.viewController.view
        lines.append("item[\(index)] \(type(of: item.viewController)) behavior=\(item.behavior.rawValue) "
          + "collapsed=\(item.isCollapsed) min=\(item.minimumThickness) max=\(item.maximumThickness) "
          + "holding=\(item.holdingPriority.rawValue) frame=\(fmt(view.frame)) fitting=\(fmt(view.fittingSize)) "
          + "intrinsic=\(fmt(view.intrinsicContentSize))")
        if verbose {
          for constraint in view.constraintsAffectingLayout(for: .horizontal) {
            lines.append("    h: \(describe(constraint))")
          }
        }
      }
    }
    for constraint in verbose ? split.constraintsAffectingLayout(for: .horizontal) : [] {
      lines.append("  split h: \(describe(constraint))")
    }
    note(lines.joined(separator: "\n"))
  }

  private static var verbose: Bool { CommandLine.arguments.contains("--window-sizing-probe-verbose") }

  private static func firstSplitView(in view: NSView?) -> NSSplitView? {
    guard let view else { return nil }
    if let split = view as? NSSplitView { return split }
    for subview in view.subviews {
      if let found = firstSplitView(in: subview) { return found }
    }
    return nil
  }

  private static func chain(_ view: NSView) -> String {
    var names: [String] = []
    var current = view.superview
    while let node = current, names.count < 6 {
      names.append("\(type(of: node))\(fmt(node.frame.size))")
      current = node.superview
    }
    return names.joined(separator: " < ")
  }

  private static func describe(_ constraint: NSLayoutConstraint) -> String {
    func name(_ item: AnyObject?) -> String {
      guard let item else { return "nil" }
      if let view = item as? NSView { return "\(type(of: view))@\(Int(view.frame.width))" }
      return "\(type(of: item))"
    }
    return "\(name(constraint.firstItem)).\(constraint.firstAttribute.rawValue) "
      + "\(constraint.relation.rawValue) \(name(constraint.secondItem)).\(constraint.secondAttribute.rawValue)"
      + " *\(constraint.multiplier) +\(constraint.constant) p\(constraint.priority.rawValue)"
      + " id=\(constraint.identifier ?? "-")"
  }

  private static func fmt(_ size: NSSize) -> String { "\(Int(size.width))x\(Int(size.height))" }
  private static func fmt(_ rect: NSRect) -> String {
    "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)))"
  }

  private static func note(_ text: String) {
    guard let logURL, let handle = try? FileHandle(forWritingTo: logURL) else { return }
    handle.seekToEndOfFile()
    handle.write(Data((text + "\n").utf8))
    try? handle.close()
  }

  private static func sleep(ms: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(ms * 1_000_000))
  }
}
#endif
