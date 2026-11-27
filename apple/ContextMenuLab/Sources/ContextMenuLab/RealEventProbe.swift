import AppKit
import ApplicationServices
import InlineContextMenu

/// Drives the lab with real CGEvents posted to this process (the cursor is not moved), reads the native
/// menu through the accessibility API, and captures screenshots. Steps run on a background thread so
/// the main thread can sit inside the native menu's tracking loop.
final class RealEventProbe: @unchecked Sendable {
  let controller: LabWindowController
  let scenario: String
  let out: String?
  let pid = getpid()
  let source = CGEventSource(stateID: .privateState)
  let shotDir: String
  var results: [[String: String]] = []

  @MainActor
  init(controller: LabWindowController, scenario: String, out: String?) {
    self.controller = controller
    self.scenario = scenario
    self.out = out
    let base = out.map { ($0 as NSString).deletingLastPathComponent } ?? NSTemporaryDirectory()
    shotDir = (base as NSString).appendingPathComponent("shots")
    try? FileManager.default.createDirectory(atPath: shotDir, withIntermediateDirectories: true)
  }

  nonisolated(unsafe) var seen: [UInt: Int] = [:]

  @MainActor
  func start() {
    _ = NSEvent.addLocalMonitorForEvents(matching: .any) { [self] event in
      seen[event.type.rawValue, default: 0] += 1
      if event.type == .rightMouseDown {
        controller.lab.log("probe saw rightMouseDown window=\(event.windowNumber) lab=\(controller.window.windowNumber) loc=\(event.locationInWindow) hit=\(String(describing: controller.window.contentView?.hitTest(event.locationInWindow).map { type(of: $0) }))")
      }
      return event
    }
    Thread.detachNewThread { [self] in
      switch scenario {
      case "events":
        let point = bubblePoint(0)
        mouse(.mouseMoved, point); wait(0.2)
        rightClick(point); wait(0.5)
        key(53); wait(0.3)
        let hid = CGEventSource(stateID: .hidSystemState)
        let e = CGEvent(mouseEventSource: hid, mouseType: .mouseMoved, mouseCursorPosition: cg(point), mouseButton: .left)!
        e.postToPid(pid); wait(0.3)
        record("events", ["seen": onMain { seen.map { "\($0.key):\($0.value)" }.sorted().joined(separator: ",") }, "frontmost": onMain { "\(NSApp.isActive) key=\(controller.window.isKeyWindow)" }, "log": onMain { controller.lab.logLines.suffix(5).joined(separator: " / ") }])
      case "native": nativeSteps()
      case "custom": customSteps()
      case "both":
        nativeSteps()
        customSteps()
      default:
        nativeSteps()
        customSteps()
      }
      finish()
    }
  }

  private func finish() {
    let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
    if let out, let data { try? data.write(to: URL(fileURLWithPath: out)) }
    for result in results {
      print("PROBE " + result.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " | "))
    }
    DispatchQueue.main.async { NSApp.terminate(nil) }
  }

  private func record(_ step: String, _ values: [String: String]) {
    var entry = values
    entry["step"] = step
    results.append(entry)
    FileHandle.standardError.write("STEP \(step) \(values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " | "))\n".data(using: .utf8)!)
  }

  // MARK: Posting

  private func onMain<T>(_ body: @MainActor () -> T) -> T {
    DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
  }

  private var screenHeight: CGFloat { onMain { NSScreen.screens[0].frame.maxY } }

  private func cg(_ point: NSPoint) -> CGPoint {
    CGPoint(x: point.x, y: screenHeight - point.y)
  }

  private func mouse(_ type: CGEventType, _ point: NSPoint, button: CGMouseButton = .left, flags: CGEventFlags = []) {
    // Posted into the app's event queue with the window under the point, so the event goes through
    // nextEvent (native menu tracking reads it there), local monitors and window routing like a real one.
    let nsType: NSEvent.EventType = switch type {
    case .leftMouseDown: .leftMouseDown
    case .leftMouseUp: .leftMouseUp
    case .rightMouseDown: .rightMouseDown
    case .rightMouseUp: .rightMouseUp
    case .rightMouseDragged: .rightMouseDragged
    case .leftMouseDragged: .leftMouseDragged
    default: .mouseMoved
    }
    var modifiers: NSEvent.ModifierFlags = []
    if flags.contains(.maskControl) { modifiers.insert(.control) }
    let (number, location) = onMain { () -> (Int, NSPoint) in
      // Our windows only: another app's window may sit over the lab on a busy desktop.
      let candidates = NSApp.windows.filter { $0.isVisible && $0.frame.contains(point) }
        .sorted { $0.level.rawValue != $1.level.rawValue ? $0.level.rawValue > $1.level.rawValue : $0.orderedIndex < $1.orderedIndex }
      if let window = candidates.first {
        return (window.windowNumber, window.convertPoint(fromScreen: point))
      }
      return (0, point)
    }
    let event = NSEvent.mouseEvent(
      with: nsType, location: location, modifierFlags: modifiers,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number,
      context: nil, eventNumber: 0, clickCount: 1, pressure: nsType == .mouseMoved ? 0 : 1
    )!
    NSApp.postEvent(event, atStart: false)
  }

  private func rightClick(_ point: NSPoint) {
    mouse(.rightMouseDown, point, button: .right)
    usleep(40_000)
    mouse(.rightMouseUp, point, button: .right)
  }

  private func click(_ point: NSPoint) {
    mouse(.leftMouseDown, point)
    usleep(40_000)
    mouse(.leftMouseUp, point)
  }

  private func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
    for down in [true, false] {
      let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
      event.flags = flags
      event.postToPid(pid)
      usleep(25_000)
    }
  }

  private func wait(_ seconds: Double) { usleep(useconds_t(seconds * 1_000_000)) }

  // MARK: Reading state

  private func bubblePoint(_ index: Int) -> NSPoint {
    onMain {
      let view = controller.bubbles[index]
      return controller.window.convertPoint(toScreen: view.convert(NSPoint(x: min(40, view.bounds.midX), y: view.bounds.midY), to: nil))
    }
  }

  /// On-screen windows of this process above normal level (menus, our panels).
  private func overlayWindows() -> [CGRect] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
    return list.compactMap { info in
      guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
            let layer = info[kCGWindowLayer as String] as? Int, layer > 0,
            let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
      else { return nil }
      return CGRect(x: bounds["X"]!, y: bounds["Y"]!, width: bounds["Width"]!, height: bounds["Height"]!)
    }
  }

  /// Menu items as the accessibility API sees them: title and frame in top-left screen coordinates.
  private func axMenuItems() -> [(String, CGRect, Bool)] {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1.5)
    var found: [(String, CGRect, Bool)] = []
    func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
      var value: AnyObject?
      return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    func visit(_ element: AXUIElement, depth: Int) {
      guard depth < 12 else { return }
      let role = attribute(element, kAXRoleAttribute) as? String
      if role == (kAXMenuItemRole as String) {
        let title = attribute(element, kAXTitleAttribute) as? String ?? ""
        var point = CGPoint.zero
        var size = CGSize.zero
        if let value = attribute(element, kAXPositionAttribute) { AXValueGetValue(value as! AXValue, .cgPoint, &point) }
        if let value = attribute(element, kAXSizeAttribute) { AXValueGetValue(value as! AXValue, .cgSize, &size) }
        let enabled = (attribute(element, kAXEnabledAttribute) as? Bool) ?? true
        found.append((title, CGRect(origin: point, size: size), enabled))
      }
      // The menu bar's own menus are not what we want.
      if role == (kAXMenuBarRole as String) { return }
      for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
        visit(child, depth: depth + 1)
      }
    }
    visit(app, depth: 0)
    return found
  }

  private func appKitPoint(fromAX rect: CGRect) -> NSPoint {
    NSPoint(x: rect.midX, y: screenHeight - rect.midY)
  }

  private func screenshot(_ name: String, around rects: [CGRect]) -> String {
    guard var union = rects.first else { return "-" }
    for rect in rects.dropFirst() { union = union.union(rect) }
    union = union.insetBy(dx: -60, dy: -40)
    let path = (shotDir as NSString).appendingPathComponent(name + ".png")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-R\(Int(union.minX)),\(Int(union.minY)),\(Int(union.width)),\(Int(union.height))", path]
    try? process.run()
    process.waitUntilExit()
    return FileManager.default.fileExists(atPath: path) ? path : "failed(\(process.terminationStatus))"
  }

  private func describe(_ rect: CGRect) -> String {
    String(format: "%.0f,%.0f %.0fx%.0f", rect.minX, rect.minY, rect.width, rect.height)
  }

  // MARK: Native

  private func nativeSteps() {
    onMain { controller.setMode(.native) }
    let point = bubblePoint(0)

    // Open with a quick right click: does it stay open, where is it, what are the row metrics?
    onMain { controller.lab.highlightTrail = [] }
    rightClick(point)
    wait(0.6)
    let windows = overlayWindows()
    let items = axMenuItems()
    let rowHeights = items.map { Int($0.1.height) }
    var values: [String: String] = [
      "openAfterQuickClick": "\(!windows.isEmpty)",
      "menuWindows": windows.map(describe).joined(separator: "; "),
      "clickPoint(top-left)": String(format: "%.0f,%.0f", cg(point).x, cg(point).y),
      "axItems": items.map { "\($0.0)[\(Int($0.1.minY))+\(Int($0.1.height)) w\(Int($0.1.width))\($0.2 ? "" : " disabled")]" }.joined(separator: ", "),
      "rowHeights": Set(rowHeights).sorted().map(String.init).joined(separator: ","),
    ]
    values["screenshot"] = screenshot("native-menu", around: windows)
    record("native.open", values)

    // Keyboard: down x3, right into Forward, left, down x2 (Edit is disabled for incoming).
    key(125); key(125); key(125)
    let afterDown = onMain { controller.lab.highlightTrail }
    key(124)
    wait(0.3)
    let submenuWindows = overlayWindows().count
    let afterRight = onMain { controller.lab.highlightTrail }
    key(123)
    wait(0.2)
    let afterLeftWindows = overlayWindows().count
    key(125); key(125)
    let afterSkip = onMain { controller.lab.highlightTrail }
    record("native.keyboard", [
      "downTrail": afterDown.joined(separator: ">"),
      "rightOpensSubmenu": "\(submenuWindows > windows.count)",
      "afterRightTrail": afterRight.suffix(2).joined(separator: ">"),
      "leftClosesSubmenu": "\(afterLeftWindows == windows.count)",
      "skipDisabledTrail": afterSkip.suffix(2).joined(separator: ">"),
    ])

    // Wrap-around and type select.
    for _ in 0 ..< 14 { key(126) }
    let afterUps = onMain { controller.lab.highlightTrail }
    key(2); key(14) // d e
    wait(0.1)
    let afterType = onMain { controller.lab.highlightTrail }
    record("native.navigation", [
      "upPastTopTrail": afterUps.suffix(5).joined(separator: ">"),
      "typeSelectDE": afterType.last ?? "-",
    ])

    // Escape inside a submenu: does it close the submenu or the whole menu?
    for _ in 0 ..< 14 { key(126) }
    key(125); key(125); key(125); key(124)
    wait(0.3)
    let before = overlayWindows().count
    key(53)
    wait(0.3)
    let afterEsc = overlayWindows().count
    key(53)
    wait(0.4)
    record("native.escape", ["windowsInSubmenu": "\(before)", "afterOneEscape": "\(afterEsc)", "afterTwoEscapes": "\(overlayWindows().count)"])

    // Space: activates?
    rightClick(point)
    wait(0.5)
    let actionsBefore = onMain { controller.lab.actions.count }
    let logBefore = onMain { controller.lab.logLines.count }
    key(125); key(49)
    wait(0.4)
    let actionsAfter = onMain { controller.lab.actions }
    let tail = onMain { Array(controller.lab.logLines.dropFirst(logBefore)) }
    let closeIndex = tail.firstIndex { $0.contains("menuDidClose root") }
    let actionIndex = tail.firstIndex { $0.contains("ACTION") }
    record("native.space", [
      "spaceActivates": "\(actionsAfter.count > actionsBefore)", "last": actionsAfter.last ?? "-",
      "openAfter": "\(!overlayWindows().isEmpty)",
      "order": closeIndex == nil || actionIndex == nil ? "unknown" : (closeIndex! < actionIndex! ? "didClose then action" : "action then didClose"),
      "viewDidCloseIndex": "\(tail.firstIndex { $0.contains("view didCloseMenu") } ?? -1) action=\(actionIndex ?? -1) delegateClose=\(closeIndex ?? -1)",
    ])
    if !overlayWindows().isEmpty { key(53); wait(0.3) }

    // Press-drag-release onto Pin, and the order of didClose vs action.
    mouse(.rightMouseDown, point, button: .right)
    wait(0.5)
    let pin = axMenuItems().first { $0.0 == "Pin" }
    var pressValues: [String: String] = ["pinFound": "\(pin != nil)"]
    if let pin {
      let target = appKitPoint(fromAX: pin.1)
      mouse(.rightMouseDragged, NSPoint(x: point.x + 20, y: point.y - 20), button: .right)
      wait(0.05)
      mouse(.rightMouseDragged, target, button: .right)
      wait(0.15)
      mouse(.rightMouseUp, target, button: .right)
      wait(0.4)
      let log = onMain { controller.lab.logLines.suffix(12) }
      pressValues["last"] = onMain { controller.lab.actions.last ?? "-" }
      let closeIndex = log.lastIndex { $0.contains("menuDidClose root") }
      let actionIndex = log.lastIndex { $0.contains("ACTION Pin") }
      pressValues["didCloseBeforeAction"] = "\(closeIndex != nil && actionIndex != nil && closeIndex! < actionIndex!)"
    } else {
      mouse(.rightMouseUp, point, button: .right)
    }
    if !overlayWindows().isEmpty { key(53); wait(0.3) }
    record("native.pressDragRelease", pressValues)

    // Right-click elsewhere while open: dismiss only, or reopen there?
    rightClick(point)
    wait(0.5)
    let second = bubblePoint(2)
    let logMark = onMain { controller.lab.logLines.count }
    rightClick(second)
    wait(0.6)
    let reopened = onMain { controller.lab.logLines.dropFirst(logMark).contains { $0.contains("menu(for:)") } }
    record("native.rightClickOutside", ["reopensAtNewSpot": "\(reopened)", "openAfter": "\(!overlayWindows().isEmpty)"])
    if !overlayWindows().isEmpty { key(53); wait(0.3) }

    // Left click outside: is the click delivered to what is under it?
    rightClick(point)
    wait(0.5)
    let textBubble = onMain { controller.bubbles.last as! TextBubbleView }
    let textPoint = bubblePoint(onMain { controller.bubbles.count } - 1)
    onMain { controller.window.makeFirstResponder(nil) }
    click(textPoint)
    wait(0.4)
    let textBecameFirst = onMain { controller.window.firstResponder === textBubble.textView }
    record("native.leftClickOutside", ["clickReachedView": "\(textBecameFirst)", "openAfter": "\(!overlayWindows().isEmpty)"])
    if !overlayWindows().isEmpty { key(53); wait(0.3) }

    // Native menu + floating panel: can the panel be used while the menu tracks?
    onMain { controller.setMode(.nativePanel) }
    var monitorEvents: [String] = []
    let monitor = onMain {
      NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseUp]) { event in
        monitorEvents.append("\(event.type.rawValue)")
        return event
      }
    }
    rightClick(point)
    wait(0.6)
    let panelWindows = overlayWindows()
    let panelFrame = panelWindows.min { $0.minY < $1.minY } // topmost on screen = the panel above the cursor
    var panelValues: [String: String] = ["windows": panelWindows.map(describe).joined(separator: "; ")]
    panelValues["screenshot"] = screenshot("native-plus-panel", around: panelWindows)
    if let panelFrame {
      let heart = NSPoint(x: panelFrame.minX + 5 + 36 + 18, y: screenHeight - panelFrame.midY)
      onMain { controller.lab.panelEvents = [] }
      mouse(.mouseMoved, heart)
      wait(0.1)
      click(heart)
      wait(0.5)
      panelValues["panelEvents"] = onMain { controller.lab.panelEvents.joined(separator: ",") }
      panelValues["reacted"] = onMain { "\(controller.lab.actions.last?.hasPrefix("react") ?? false)" }
      panelValues["menuOpenAfterClick"] = "\(overlayWindows().count >= 2)"
      panelValues["localMonitorDuringTracking"] = monitorEvents.joined(separator: ",")
    }
    onMain { if let monitor { NSEvent.removeMonitor(monitor) } }
    if overlayWindows().count >= 2 { key(53); wait(0.3) }
    onMain { NSApp.windows.filter { $0 is NSPanel && $0.isVisible }.forEach { $0.orderOut(nil) } }
    record("nativePanel", panelValues)

    // View row and palette inside the native menu: screenshot and click the heart.
    for mode in [LabMode.viewRow, .palette] {
      onMain { controller.setMode(mode) }
      rightClick(point)
      wait(0.6)
      let windows = overlayWindows()
      var values: [String: String] = ["screenshot": screenshot("native-\(mode.rawValue)", around: windows)]
      let items = axMenuItems()
      values["axItems"] = items.prefix(4).map { "\($0.0)[\(describe($0.1))]" }.joined(separator: ", ")
      if mode == .palette, let heart = items.first(where: { $0.0 == "❤️" }) {
        let target = appKitPoint(fromAX: heart.1)
        mouse(.mouseMoved, target)
        wait(0.1)
        click(target)
      } else if mode == .viewRow, let row = items.first {
        // The bar is the first row: inset 10 + one 30pt cell + half a cell.
        let target = NSPoint(x: row.1.minX + 10 + 30 + 15, y: screenHeight - row.1.midY)
        mouse(.mouseMoved, target)
        wait(0.1)
        click(target)
      }
      wait(0.5)
      values["reacted"] = onMain { controller.lab.actions.last ?? "-" }
      values["openAfter"] = "\(!overlayWindows().isEmpty)"
      if !overlayWindows().isEmpty { key(53); wait(0.3) }
      record("native.\(mode.rawValue)", values)
    }
  }

  // MARK: Custom

  private func customSteps() {
    onMain {
      controller.setMode(.custom)
      controller.lab.animation = .pop
    }
    let point = bubblePoint(0)

    rightClick(point)
    wait(0.5)
    let windows = overlayWindows()
    var values: [String: String] = onMain {
      let session = ContextMenuSession.current
      return [
        "opened": "\(session?.isOpen == true)",
        "eventToVisibleMs": session?.eventToVisible.map { String(format: "%.1f", $0 * 1000) } ?? "-",
        "buildMs": session.map { String(format: "%.2f", $0.openDuration * 1000) } ?? "-",
        "menuFrame": session?.menuScreenFrames.first.map { String(format: "%.0f,%.0f %.0fx%.0f", $0.minX, $0.minY, $0.width, $0.height) } ?? "-",
        "accessoryFrame": session?.accessoryScreenFrame.map { String(format: "%.0f,%.0f %.0fx%.0f", $0.minX, $0.minY, $0.width, $0.height) } ?? "-",
        "windowStayedKey": "\(controller.window.isKeyWindow)",
      ]
    }
    values["screenshot"] = screenshot("custom-menu", around: windows)
    record("custom.open", values)

    // Hover and click a row with real events.
    let items = axMenuItems()
    record("custom.ax", ["axItems": items.prefix(6).map { "\($0.0)[\(describe($0.1))]" }.joined(separator: ", ")])
    if let replyInThread = items.first(where: { $0.0 == "Reply in Thread" }) {
      let target = appKitPoint(fromAX: replyInThread.1)
      mouse(.mouseMoved, target)
      wait(0.15)
      let highlighted = onMain { ContextMenuSession.current?.highlightedItem?.title ?? "-" }
      _ = screenshot("custom-hover", around: overlayWindows())
      click(target)
      wait(0.4)
      record("custom.mouse", ["hoverHighlight": highlighted, "last": onMain { controller.lab.actions.last ?? "-" }, "closed": "\(onMain { ContextMenuSession.current == nil })"])
    }

    // Click an emoji in the accessory.
    rightClick(point)
    wait(0.5)
    if let bar = onMain({ ContextMenuSession.current?.accessoryScreenFrame }) {
      let heart = NSPoint(x: bar.minX + 5 + 36 + 18, y: bar.midY)
      mouse(.mouseMoved, heart)
      wait(0.1)
      click(heart)
      wait(0.4)
      record("custom.accessoryClick", ["last": onMain { controller.lab.actions.last ?? "-" }, "closed": "\(onMain { ContextMenuSession.current == nil })"])
    }

    // Press-drag-release onto a row and onto an emoji.
    mouse(.rightMouseDown, point, button: .right)
    wait(0.4)
    if let pin = axMenuItems().first(where: { $0.0 == "Pin" }) {
      let target = appKitPoint(fromAX: pin.1)
      mouse(.rightMouseDragged, NSPoint(x: point.x + 20, y: point.y - 20), button: .right)
      wait(0.05)
      mouse(.rightMouseDragged, target, button: .right)
      wait(0.1)
      mouse(.rightMouseUp, target, button: .right)
      wait(0.4)
      record("custom.pressDragRelease", ["last": onMain { controller.lab.actions.last ?? "-" }])
    } else {
      mouse(.rightMouseUp, point, button: .right)
    }
    mouse(.rightMouseDown, point, button: .right)
    wait(0.4)
    if let bar = onMain({ ContextMenuSession.current?.accessoryScreenFrame }) {
      let fire = NSPoint(x: bar.minX + 5 + 3 * 36 + 18, y: bar.midY)
      mouse(.rightMouseDragged, NSPoint(x: point.x + 5, y: point.y + 10), button: .right)
      wait(0.05)
      mouse(.rightMouseDragged, fire, button: .right)
      wait(0.1)
      mouse(.rightMouseUp, fire, button: .right)
      wait(0.4)
      record("custom.pressDragReleaseEmoji", ["last": onMain { controller.lab.actions.last ?? "-" }])
    }

    // Keyboard with real key events.
    rightClick(point)
    wait(0.4)
    key(125); key(125); key(36)
    wait(0.4)
    record("custom.keyboard", ["last": onMain { controller.lab.actions.last ?? "-" }])

    // Control-click opens it too.
    mouse(.leftMouseDown, point, flags: .maskControl)
    wait(0.04)
    mouse(.leftMouseUp, point, flags: .maskControl)
    wait(0.4)
    let ctrlOpen = onMain { ContextMenuSession.current?.isOpen == true }
    record("custom.controlClick", ["opened": "\(ctrlOpen)"])
    key(53)
    wait(0.3)

    // Right click elsewhere while open reopens there.
    rightClick(point)
    wait(0.4)
    let first = onMain { ContextMenuSession.current.map(ObjectIdentifier.init) }
    // The outgoing bubble on the right, clear of the open menu.
    let rightEnd = onMain { () -> NSPoint in
      let view = controller.bubbles[1]
      return controller.window.convertPoint(toScreen: view.convert(NSPoint(x: view.bounds.maxX - 12, y: view.bounds.midY), to: nil))
    }
    let menuFrame = onMain { ContextMenuSession.current?.menuScreenFrames.first ?? .zero }
    rightClick(rightEnd)
    wait(0.4)
    let reopened = onMain { () -> Bool in
      guard let second = ContextMenuSession.current else { return false }
      return ObjectIdentifier(second) != first && second.isOpen
    }
    record("custom.rightClickOutside", ["reopened": "\(reopened)", "clickOutsideMenu": "\(!menuFrame.contains(rightEnd))"])
    key(53)
    wait(0.3)

    // Light and dark side by side for review.
    for appearance in [NSAppearance.Name.darkAqua, .aqua] {
      onMain { NSApp.appearance = NSAppearance(named: appearance) }
      wait(0.2)
      rightClick(point)
      wait(0.5)
      _ = screenshot("custom-\(appearance == .darkAqua ? "dark" : "light")", around: overlayWindows())
      key(53)
      wait(0.3)
      onMain { controller.setMode(.native) }
      rightClick(point)
      wait(0.5)
      _ = screenshot("native-\(appearance == .darkAqua ? "dark" : "light")", around: overlayWindows())
      key(53)
      wait(0.3)
      onMain { controller.setMode(.custom) }
    }
    onMain { NSApp.appearance = nil }
  }
}

extension LabWindowController {
  var bubblesCount: Int { bubbles.count }
}
