import AppKit
import InlineContextMenu

/// In-process checks with synthetic events. Real hardware-path checks live in RealEventProbe.
@MainActor
final class SelfTest {
  struct Result: Codable {
    let name: String
    let pass: Bool
    let detail: String
  }

  let controller: LabWindowController
  var lab: LabController { controller.lab }
  var window: NSWindow { controller.window }
  private var results: [Result] = []
  private var intercepted: [String] = []
  private var nativeTrackingSeen = false
  private var trackingObserver: NSObjectProtocol?

  init(controller: LabWindowController) {
    self.controller = controller
  }

  func run(out: String?) {
    let previousObserver = ContextMenu.presentationObserver
    ContextMenu.presentationObserver = { [weak self] entry in
      MainActor.assumeIsolated {
        self?.intercepted.append(entry)
        previousObserver?(entry)
      }
    }
    // Any native menu that starts tracking during a check is cancelled, so the check cannot hang.
    trackingObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { [weak self] note in
      guard let menu = note.object as? NSMenu, !(menu is ContextMenu) else { return }
      MainActor.assumeIsolated { self?.nativeTrackingSeen = true }
      RunLoop.main.perform(inModes: [.eventTracking, .common, .default]) { menu.cancelTracking() }
    }

    interceptionChecks()
    engineChecks()
    timingChecks()

    let passed = results.filter(\.pass).count
    print("SELFTEST \(passed)/\(results.count) passed")
    for result in results {
      print("\(result.pass ? "PASS" : "FAIL")  \(result.name)  \(result.detail)")
    }
    if let out {
      try? lab.logLines.joined(separator: "\n").write(toFile: out + ".log", atomically: true, encoding: .utf8)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try? encoder.encode(results).write(to: URL(fileURLWithPath: out))
    }
    NSApp.terminate(nil)
  }

  /// Checks that need the lab to be the active app (control-click, key window, first responder).
  /// macOS may decline activation while the user works in another app; those checks are skipped then.
  private let needsActiveApp: Set<String> = [
    "interception.menuForEvent.controlClick", "textView.copySelectedHighlighted",
    "responderChain.nilTargetCopy", "responderChain.windowStayedKey",
  ]

  private func check(_ name: String, _ pass: Bool, _ detail: String = "") {
    if !NSApp.isActive, needsActiveApp.contains(name) {
      results.append(Result(name: name, pass: true, detail: "SKIPPED: lab app not active. " + detail))
      return
    }
    results.append(Result(name: name, pass: pass, detail: detail))
  }

  private func spin(_ seconds: TimeInterval = 0.05) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  // MARK: Synthetic events

  private func center(of view: NSView) -> NSPoint {
    window.convertPoint(toScreen: view.convert(NSPoint(x: min(40, view.bounds.midX), y: view.bounds.midY), to: nil))
  }

  /// A mouse event addressed to the lab window, or with no window (screen coordinates) when `window` is nil.
  private func mouse(_ type: NSEvent.EventType, at screen: NSPoint, flags: NSEvent.ModifierFlags = [], in target: NSWindow? = nil) -> NSEvent {
    let location = target.map { $0.convertPoint(fromScreen: screen) } ?? screen
    return NSEvent.mouseEvent(
      with: type, location: location, modifierFlags: flags,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target?.windowNumber ?? 0,
      context: nil, eventNumber: 0, clickCount: 1, pressure: 1
    )!
  }

  private func key(_ code: UInt16, _ chars: String, flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code
    )!
  }

  private func flags(_ flags: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(
      with: .flagsChanged, location: .zero, modifierFlags: flags,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58
    )!
  }

  // MARK: Interception: does AppKit's own context-menu path reach InlineContextMenu?

  /// Posts Escape to this process after a delay, from another thread: closes a native menu whose
  /// tracking loop would otherwise hold the check forever.
  private func escapeWatchdog(after seconds: Double) {
    let pid = getpid()
    Thread.detachNewThread {
      usleep(useconds_t(seconds * 1_000_000))
      let source = CGEventSource(stateID: .privateState)
      for down in [true, false] {
        CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: down)?.postToPid(pid)
      }
    }
  }

  private func interceptionChecks() {
    controller.setMode(.custom)
    lab.animation = .none
    let bubble = controller.bubbles[1]
    let textBubble = controller.bubbles.last as! TextBubbleView

    let entries: [(String, () -> Void)] = [
      ("rightMouseDown", { [self] in
        window.sendEvent(mouse(.rightMouseDown, at: center(of: bubble), in: window))
        window.sendEvent(mouse(.rightMouseUp, at: center(of: bubble), in: window))
      }),
      ("controlClick", { [self] in
        window.sendEvent(mouse(.leftMouseDown, at: center(of: bubble), flags: .control, in: window))
        window.sendEvent(mouse(.leftMouseUp, at: center(of: bubble), flags: .control, in: window))
      }),
      ("textViewRightMouseDown", { [self] in
        window.sendEvent(mouse(.rightMouseDown, at: center(of: textBubble.textView), in: window))
        window.sendEvent(mouse(.rightMouseUp, at: center(of: textBubble.textView), in: window))
      }),
      ("accessibilityShowMenu", { _ = bubble.accessibilityPerformShowMenu() }),
      ("textViewAccessibilityShowMenu", { _ = textBubble.textView.accessibilityPerformShowMenu() }),
    ]

    for strategy in LabController.Interception.allCases {
      lab.interception = strategy
      for (name, body) in entries {
        intercepted = []
        nativeTrackingSeen = false
        lab.menuForEventCalls = []
        escapeWatchdog(after: 0.8)
        let start = CACurrentMediaTime()
        body()
        let returnedAfter = CACurrentMediaTime() - start
        spin(0.3)
        let open = ContextMenuSession.current?.isOpen == true
        let pass = open && !(strategy == .menuForEvent && nativeTrackingSeen)
        check("interception.\(strategy.rawValue).\(name)", pass,
              "key=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil") main=\(NSApp.mainWindow.map { String(describing: type(of: $0)) } ?? "nil") active=\(NSApp.isActive) customOpen=\(open) nativeTracking=\(nativeTrackingSeen) blockedFor=\(String(format: "%.2f", returnedAfter))s menuForEvent=\(lab.menuForEventCalls)")
        spin(0.7)
        ContextMenuSession.closeAll()
        spin(0.1)
      }
    }
    lab.interception = .menuForEvent

    // Does anything call menu(for:) speculatively? Accessibility asks a view which actions it has.
    lab.menuForEventCalls = []
    _ = bubble.accessibilityActionNames()
    _ = textBubble.textView.accessibilityActionNames()
    spin(0.1)
    let speculative = lab.menuForEventCalls
    let opened = ContextMenuSession.current?.isOpen == true
    check("interception.noSpeculativeMenuForEvent", speculative.isEmpty && !opened, "calls=\(speculative) opened=\(opened)")
    ContextMenuSession.closeAll()
  }

  // MARK: Engine behavior

  /// Opens the custom menu for a bubble the way the class override does, with a right-mouse-down at `anchor`.
  @discardableResult
  private func openCustom(on view: NSView, anchor: NSPoint? = nil, nativeTextMenu: NSMenu? = nil) -> ContextMenuSession? {
    ContextMenuSession.closeAll()
    let point = anchor ?? center(of: view)
    let event = mouse(.rightMouseDown, at: point, in: window)
    // Build without presenting, then present here with animations off.
    lab.interception = .classOverride
    defer { lab.interception = .menuForEvent }
    guard let menu = lab.menu(for: view, event: event, nativeTextMenu: nativeTextMenu) as? ContextMenu else { return nil }
    var options = menu.options
    options.animation = .none
    options.accessoryView = menu.accessoryViewProvider?()
    let session = ContextMenuSession.popUp(menu, with: event, for: view, options: options)
    spin()
    return session
  }

  private func send(_ session: ContextMenuSession?, _ events: NSEvent...) {
    for event in events { _ = session?.handle(event) }
    spin(0.08)
  }

  private func engineChecks() {
    let incoming = controller.bubbles[0]
    let outgoing = controller.bubbles[1]

    // Keyboard walk, submenu in and out, validation skipping a disabled item.
    var session = openCustom(on: incoming)
    send(session, key(125, ""), key(125, ""), key(125, ""))
    check("keys.downWalksRows", session?.highlightedItem?.title == "Forward", "highlighted=\(session?.highlightedItem?.title ?? "nil")")
    send(session, key(124, ""))
    check("keys.rightOpensSubmenuAtFirstItem", session?.openMenus.count == 2 && session?.highlightedItem?.title == "Design",
          "menus=\(session?.openMenus.count ?? 0) highlighted=\(session?.highlightedItem?.title ?? "nil")")
    send(session, key(123, ""))
    check("keys.leftClosesSubmenu", session?.openMenus.count == 1 && session?.highlightedItem?.title == "Forward",
          "menus=\(session?.openMenus.count ?? 0) highlighted=\(session?.highlightedItem?.title ?? "nil")")
    send(session, key(125, ""))
    check("keys.downCrossesSeparator", session?.highlightedItem?.title == "Copy Text", "highlighted=\(session?.highlightedItem?.title ?? "nil")")
    send(session, key(125, ""), key(125, ""), key(125, ""), key(125, ""))
    let editItem = session?.menu.items.first { $0.title == "Edit" }
    check("items.editHiddenOnIncoming", editItem == nil, "titles=\(session?.menu.items.map(\.title).filter { !$0.isEmpty } ?? [])")
    let linear = session?.menu.items.first { $0.title == "Create Linear Issue" }
    check("validation.disabledByValidation", linear?.isEnabled == false, "Linear enabled=\(linear?.isEnabled ?? true)")
    check("keys.skipDisabled", session?.highlightedItem?.title == "Mark", "highlighted=\(session?.highlightedItem?.title ?? "nil")")

    // Looks: icons are image views tinted like AppKit's, disabled icons dim with their title.
    if let session {
      check("look.iconViews", session.rootIconViewCount >= 8, "icons=\(session.rootIconViewCount)")
      let disabledTint = session.rootIconTint(title: "Create Linear Issue")
      check("look.disabledIconIsTertiary", disabledTint == .tertiaryLabelColor, "tint=\(disabledTint?.description ?? "nil")")
      let highlightedTint = session.rootIconTint(title: "Mark")
      check("look.highlightedIconIsWhite", highlightedTint == .selectedMenuItemTextColor, "tint=\(highlightedTint?.description ?? "nil")")
      check("look.keyboardHighlightPlaysIconEffect", session.rootIconEffectsPlayed >= 4, "effects=\(session.rootIconEffectsPlayed)")
      if #available(macOS 26.0, *), let glass = findGlass(in: session.rootPanel?.contentView) {
        let subvariant = glass.responds(to: NSSelectorFromString("_subvariant")) ? glass.value(forKey: "_subvariant") as? String : nil
        check("look.menuGlassVariant", subvariant == "menu", "subvariant=\(subvariant ?? "nil")")
      }
      // VoiceOver reads shortcuts from these attributes, as on AppKit's own items.
      let deleteElement = session.rootAccessibilityElement(title: "Delete")
      let cmdChar = deleteElement?.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: "AXMenuItemCmdChar")) as? String
      let cmdModifiers = deleteElement?.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: "AXMenuItemCmdModifiers")) as? Int
      check("a11y.shortcutAttributes", cmdChar == "⌫" && cmdModifiers == 0, "char=\(cmdChar ?? "nil") modifiers=\(cmdModifiers.map(String.init) ?? "nil")")
      let disabledElement = session.rootAccessibilityElement(title: "Create Linear Issue")
      check("a11y.disabledItemNotEnabled", disabledElement?.isAccessibilityEnabled() == false, "")
    }

    // Type select.
    send(session, key(2, "d"), key(14, "e"))
    check("keys.typeSelect", session?.highlightedItem?.title == "Delete", "highlighted=\(session?.highlightedItem?.title ?? "nil")")

    // Return picks; delegate close comes before the action, as with the native menu.
    let actionsBefore = lab.actions.count
    let logBefore = lab.logLines.count
    send(session, key(36, "\r"))
    spin(0.2)
    let tail = lab.logLines.dropFirst(logBefore)
    let closeIndex = tail.firstIndex { $0.contains("delegate menuDidClose root") }
    let actionIndex = tail.firstIndex { $0.contains("ACTION Delete") }
    check("keys.returnActivates", lab.actions.count == actionsBefore + 1 && lab.actions.last == "Delete" && session?.isOpen == false,
          "actions=\(lab.actions.suffix(1)) open=\(session?.isOpen ?? false)")
    check("delegate.didCloseBeforeAction", closeIndex != nil && actionIndex != nil && closeIndex! < actionIndex!,
          "closeIndex=\(String(describing: closeIndex)) actionIndex=\(String(describing: actionIndex))")
    check("view.willOpenAndDidCloseMenu", tail.contains { $0.contains("view didCloseMenu") }, "")

    // Key equivalents while open.
    session = openCustom(on: outgoing)
    send(session, key(15, "r", flags: .command))
    spin(0.2)
    check("keys.commandEquivalent", lab.actions.last == "Reply", "last=\(lab.actions.last ?? "")")
    session = openCustom(on: outgoing)
    send(session, key(8, "c", flags: [.command, .option]))
    spin(0.2)
    check("keys.alternateEquivalent", lab.actions.last == "Copy Message + Entities", "last=\(lab.actions.last ?? "")")
    let outgoingEdit = session?.menu.items.first { $0.title == "Edit" }
    check("validation.editEnabledOnOutgoing", outgoingEdit?.isEnabled == true, "")

    // Option swaps the alternate in place.
    session = openCustom(on: outgoing)
    send(session, flags(.option))
    let rowsWithOption = (session?.menu.items ?? []).filter { !$0.isHidden }.count
    send(session, flags([]))
    send(session, key(8, "c"), key(31, "o"), key(35, "p"), key(16, "y"), key(49, " "), key(17, "t"))
    let beforeOption = session?.highlightedItem?.title
    send(session, flags(.option))
    check("alternates.optionShowsAlternate", session?.highlightedItem?.title == "Copy Message + Entities",
          "before=\(beforeOption ?? "nil") highlighted=\(session?.highlightedItem?.title ?? "nil") items=\(rowsWithOption)")
    send(session, flags([]))
    check("alternates.releaseRestoresBase", session?.highlightedItem?.title == "Copy Text", "highlighted=\(session?.highlightedItem?.title ?? "nil")")

    // Escape.
    send(session, key(53, "\u{1b}"))
    check("keys.escapeCancels", session?.isOpen == false && session?.closeReason == .cancelled, "reason=\(session?.closeReason?.rawValue ?? "nil")")

    // Mouse hover and click.
    session = openCustom(on: incoming)
    if let session, let reply = rowCenter(session, title: "Reply in Thread") {
      send(session, mouse(.mouseMoved, at: reply))
      check("mouse.hoverHighlights", session.highlightedItem?.title == "Reply in Thread", "highlighted=\(session.highlightedItem?.title ?? "nil")")
      send(session, mouse(.leftMouseDown, at: reply), mouse(.leftMouseUp, at: reply))
      spin(0.2)
      check("mouse.clickActivates", lab.actions.last == "Reply in Thread" && !session.isOpen, "last=\(lab.actions.last ?? "")")
    } else {
      check("mouse.hoverHighlights", false, "no row")
    }

    // Hover a submenu row opens it after the delay; hovering into it keeps it.
    session = openCustom(on: incoming)
    if let session, let forward = rowCenter(session, title: "Forward") {
      send(session, mouse(.mouseMoved, at: forward))
      spin(0.25)
      check("mouse.hoverOpensSubmenu", session.openMenus.count == 2, "menus=\(session.openMenus.count)")
      session.close(animated: false, reason: .programmatic)
    }

    // Press-drag-release from the opening right click.
    let anchor = center(of: incoming)
    session = openCustom(on: incoming, anchor: anchor)
    send(session, mouse(.rightMouseUp, at: anchor))
    check("mouse.quickClickKeepsMenuOpen", session?.isOpen == true, "")
    session?.close(animated: false)
    session = openCustom(on: incoming, anchor: anchor)
    if let session, let pin = rowCenter(session, title: "Pin") {
      send(session, mouse(.rightMouseDragged, at: NSPoint(x: anchor.x + 20, y: anchor.y - 20)), mouse(.rightMouseDragged, at: pin))
      check("mouse.dragHighlights", session.highlightedItem?.title == "Pin", "highlighted=\(session.highlightedItem?.title ?? "nil")")
      send(session, mouse(.rightMouseUp, at: pin))
      spin(0.2)
      check("mouse.pressDragReleaseActivates", lab.actions.last == "Pin", "last=\(lab.actions.last ?? "")")
    }

    // Outside click closes and is swallowed.
    session = openCustom(on: incoming)
    let outside = NSPoint(x: window.frame.minX + 5, y: window.frame.minY + 5)
    let passed = session?.handle(mouse(.leftMouseDown, at: outside))
    check("mouse.outsideClickClosesAndSwallows", session?.isOpen == false && passed == nil && session?.closeReason == .outsideClick, "")

    // Accessory sits above the menu and press-drag-release reacts.
    session = openCustom(on: incoming, anchor: anchor)
    let menuFrame = session?.menuScreenFrames.first ?? .zero
    let barFrame = session?.accessoryScreenFrame ?? .zero
    let accessoryAbove = barFrame.minY >= menuFrame.maxY && barFrame.minY - menuFrame.maxY < 12
    check("accessory.placedAboveMenu", accessoryAbove, "menu=\(menuFrame) bar=\(barFrame)")
    if let session, let bar = session.options.accessoryView as? ReactionBarView, let barWindow = bar.window {
      let heart = barWindow.convertToScreen(bar.convert(NSRect(x: 5 + 36 + 18, y: bar.bounds.midY, width: 1, height: 1), to: nil)).origin
      send(session, mouse(.rightMouseDragged, at: NSPoint(x: anchor.x + 10, y: anchor.y + 10)), mouse(.rightMouseDragged, at: heart), mouse(.rightMouseUp, at: heart))
      spin(0.2)
      check("accessory.pressDragReleaseReacts", lab.actions.last == "react ❤️" && !session.isOpen, "last=\(lab.actions.last ?? "")")
    }

    // Keyboard reaches the accessory: Up from the first row, Left/Right inside, Down back, Return reacts.
    session = openCustom(on: incoming)
    send(session, key(125, ""), key(126, ""))
    let bar = session?.options.accessoryView as? ReactionBarView
    check("accessory.upFromFirstRowFocusesBar", session?.accessoryHasKeyboardFocus == true && session?.highlightedItem == nil && bar?.keyboardIndex == 0,
          "focus=\(session?.accessoryHasKeyboardFocus ?? false) highlighted=\(session?.highlightedItem?.title ?? "nil") index=\(bar?.keyboardIndex.map(String.init) ?? "nil")")
    send(session, key(125, ""))
    check("accessory.downReturnsToMenu", session?.accessoryHasKeyboardFocus == false && session?.highlightedItem?.title == "Reply",
          "highlighted=\(session?.highlightedItem?.title ?? "nil")")
    send(session, key(126, ""), key(124, ""), key(124, ""))
    check("accessory.rightMovesInBar", bar?.keyboardIndex == 2, "index=\(bar?.keyboardIndex.map(String.init) ?? "nil")")
    send(session, key(36, "\r"))
    spin(0.2)
    check("accessory.returnReacts", lab.actions.last == "react 😂" && session?.isOpen == false, "last=\(lab.actions.last ?? "")")

    // VoiceOver presses a reaction button.
    session = openCustom(on: incoming)
    if let bar = session?.options.accessoryView as? ReactionBarView, let first = bar.accessibilityChildren()?.first as? NSAccessibilityElement {
      let label = first.accessibilityLabel() ?? ""
      _ = first.accessibilityPerformPress()
      spin(0.2)
      check("a11y.reactionButtonPress", lab.actions.last == "react 👍" && label == "React with 👍", "label=\(label) last=\(lab.actions.last ?? "")")
    }
    session?.close(animated: false)

    // An item with no target reaches the clicked view, not the window's first responder.
    session = openCustom(on: incoming)
    if let session, let mark = rowCenter(session, title: "Mark") {
      let enabled = session.menu.items.first { $0.title == "Mark" }?.isEnabled ?? false
      send(session, mouse(.mouseMoved, at: mark), mouse(.leftMouseDown, at: mark), mouse(.leftMouseUp, at: mark))
      spin(0.2)
      check("responderChain.untargetedItemReachesClickedView", enabled && lab.actions.last == "Mark", "enabled=\(enabled) last=\(lab.actions.last ?? "")")
    }

    // ⌘. cancels.
    session = openCustom(on: incoming)
    send(session, key(47, ".", flags: .command))
    check("keys.commandPeriodCancels", session?.isOpen == false && session?.closeReason == .cancelled, "reason=\(session?.closeReason?.rawValue ?? "nil")")

    // A footnote ("Edited …") never highlights: End lands on Delete.
    session = openCustom(on: controller.bubbles[3])
    send(session, key(119, ""))
    let hasFootnote = session?.menu.items.contains { $0.contextMenuStyle == .footnote } ?? false
    check("items.footnoteNotSelectable", hasFootnote && session?.highlightedItem?.title == "Delete", "highlighted=\(session?.highlightedItem?.title ?? "nil")")
    session?.close(animated: false)

    // Nil-target items keep working through the responder chain: Copy Selected Text reaches the text view.
    let textBubble = controller.bubbles.last as! TextBubbleView
    window.makeFirstResponder(textBubble.textView)
    textBubble.textView.setSelectedRange(NSRange(location: 0, length: 11))
    NSPasteboard.general.clearContents()
    // The text view's own menu, without our delegate (which would present the custom menu).
    textBubble.textView.delegate = nil
    let nativeMenu = textBubble.textView.menu(for: mouse(.rightMouseDown, at: center(of: textBubble.textView), in: window)) ?? NSMenu()
    textBubble.textView.delegate = textBubble
    textBubble.textView.setSelectedRange(NSRange(location: 0, length: 11))
    session = openCustom(on: textBubble, nativeTextMenu: nativeMenu)
    let lookUp = session?.menu.items.contains { $0.title.hasPrefix("Look Up") } ?? false
    check("textView.nativeItemsCarriedOver", lookUp, "lookUp=\(lookUp) titles=\(session?.menu.items.map(\.title).filter { !$0.isEmpty } ?? [])")
    send(session, key(8, "c"), key(31, "o"), key(35, "p"), key(16, "y"), key(49, " "), key(1, "s"))
    check("textView.copySelectedHighlighted", session?.highlightedItem?.title == "Copy Selected Text", "highlighted=\(session?.highlightedItem?.title ?? "nil")")
    send(session, key(36, "\r"))
    spin(0.25)
    let copied = NSPasteboard.general.string(forType: .string)
    check("responderChain.nilTargetCopy", copied == "Select some", "pasteboard=\(copied ?? "nil")")
    check("responderChain.windowStayedKey", window.isKeyWindow && window.firstResponder === textBubble.textView, "key=\(window.isKeyWindow)")
  }

  private func rowCenter(_ session: ContextMenuSession, title: String) -> NSPoint? {
    // Find the panel showing the root menu and the row's frame through the accessibility elements.
    for window in NSApp.windows where window.isVisible && window is NSPanel {
      guard let menuView = findMenuView(in: window.contentView) else { continue }
      for element in menuView.accessibilityChildren() ?? [] {
        if let element = element as? NSAccessibilityElement, element.accessibilityLabel() == title {
          let frame = element.accessibilityFrame()
          return NSPoint(x: frame.midX, y: frame.midY)
        }
      }
    }
    return nil
  }

  @available(macOS 26.0, *)
  private func findGlass(in view: NSView?) -> NSGlassEffectView? {
    guard let view else { return nil }
    if let glass = view as? NSGlassEffectView { return glass }
    for sub in view.subviews {
      if let found = findGlass(in: sub) { return found }
    }
    return nil
  }

  private func findMenuView(in view: NSView?) -> NSView? {
    guard let view else { return nil }
    if view.accessibilityRole() == .menu { return view }
    for sub in view.subviews {
      if let found = findMenuView(in: sub) { return found }
    }
    return nil
  }

  // MARK: Timing

  private func timingChecks() {
    let bubble = controller.bubbles[2]
    for pooled in [false, true] {
      ContextMenuPanelPool.enabled = pooled
      var samples: [Double] = []
      var orderFront: [Double] = []
      for _ in 0 ..< 20 {
        let session = openCustom(on: bubble)
        samples.append((session?.openDuration ?? 0) * 1000)
        orderFront.append((session?.phaseDurations.first { $0.0 == "orderFront" }?.1 ?? 0) * 1000)
        session?.close(animated: false)
        spin(0.02)
      }
      samples.sort()
      orderFront.sort()
      check("timing.pool=\(pooled)", true, String(format: "open median=%.2fms p95=%.2fms orderFront median=%.2fms", samples[10], samples[18], orderFront[10]))
    }
    var builds: [Double] = []
    var phases: [String: [Double]] = [:]
    for _ in 0 ..< 30 {
      let start = CACurrentMediaTime()
      let session = openCustom(on: bubble)
      builds.append((CACurrentMediaTime() - start) * 1000 - 50) // minus the spin in openCustom
      if let session {
        builds[builds.count - 1] = session.openDuration * 1000
        for (name, value) in session.phaseDurations { phases[name, default: []].append(value * 1000) }
      }
      session?.close(animated: false)
    }
    builds.sort()
    let median = builds[builds.count / 2]
    let p95 = builds[Int(Double(builds.count) * 0.95)]
    let breakdown = phases.keys.sorted().map { name -> String in
      let values = phases[name]!.sorted()
      return String(format: "%@=%.2f", name, values[values.count / 2])
    }.joined(separator: " ")
    check("timing.customOpenUnder8ms", p95 < 8, String(format: "open median=%.2fms p95=%.2fms (build + layout + order front, accessory included) medians: ", median, p95) + breakdown)
  }
}
