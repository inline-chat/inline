import AppKit

/// Where the accessory view sits, named after Inline iOS's `ContextMenuAccessoryConfiguration`.
public struct ContextMenuAccessoryConfiguration {
  public enum Location {
    /// Above the menu, falling back to below when the screen has no room.
    case above
    case below
  }

  public enum Alignment {
    case leading
    case center
    case trailing
  }

  public var location: Location = .above
  /// Which edge of the menu the accessory lines up with.
  public var alignment: Alignment = .leading
  /// Gap between the accessory and the menu. Telegram leaves 10.
  public var spacing: CGFloat = 10
  /// Moves the accessory along the menu's edge, positive to the right, after the alignment.
  public var offset: CGFloat = 0
  /// Put the accessory on the menu's glass as a capsule. Off when the accessory draws its own background.
  public var usesMenuMaterial = true

  public init(
    location: Location = .above,
    alignment: Alignment = .leading,
    spacing: CGFloat = 10,
    offset: CGFloat = 0,
    usesMenuMaterial: Bool = true
  ) {
    self.location = location
    self.alignment = alignment
    self.spacing = spacing
    self.offset = offset
    self.usesMenuMaterial = usesMenuMaterial
  }
}

/// An accessory view that takes part in the menu's input. All requirements are optional to act on.
///
/// Pointer: the menu's own windows never get the opening press's drag and release (they go to the window
/// that got the mouse-down), so the session forwards them: hold right-click, move onto an emoji, let go.
/// Keyboard: Up from the menu's first row moves focus into the accessory (it sits above), Left and Right
/// move inside it, Return or Space activates, Down goes back to the menu.
@MainActor
public protocol ContextMenuAccessoryInteraction: AnyObject {
  func contextMenuTrackPointer(atScreen point: NSPoint?)
  /// Returns true when the release did something (the session then closes the menu).
  func contextMenuRelease(atScreen point: NSPoint) -> Bool
  /// Keyboard focus arrives (true) or leaves (false). Return false to decline focus.
  func contextMenuSetKeyboardFocus(_ focused: Bool) -> Bool
  /// Left (-1) or right (+1) while focused.
  func contextMenuMoveKeyboardFocus(by step: Int)
  /// Return or Space while focused. Returns true when it did something (the session then closes the menu).
  func contextMenuActivateKeyboardFocus() -> Bool
}

public extension ContextMenuAccessoryInteraction {
  func contextMenuSetKeyboardFocus(_ focused: Bool) -> Bool { false }
  func contextMenuMoveKeyboardFocus(by step: Int) {}
  func contextMenuActivateKeyboardFocus() -> Bool { false }
}

public struct ContextMenuOptions {
  public enum Animation {
    case none
    case fade
    /// Fade plus a spring scale from the pointer. Falls back to a fade when Reduce Motion is on.
    case pop
  }

  /// A view shown beside the menu, such as the quick reactions bar.
  public var accessoryView: NSView?
  public var accessoryConfiguration = ContextMenuAccessoryConfiguration()
  public var metrics = ContextMenuMetrics()
  public var material: ContextMenuMaterial = .automatic
  public var animation: Animation = .pop
  /// The hover effect for icons whose item sets none. Off: menus read calmer without it.
  public var defaultIconEffect: ContextMenuIconEffect = .none
  /// A left click outside closes the menu. Native menus swallow that click; pass it through instead when true.
  public var outsideClickPassesThrough = false
  /// A right click outside closes this menu and opens the next one in the same click.
  public var rightClickOutsideReopens = true
  /// Hover delay before a submenu opens.
  public var submenuDelay: TimeInterval = 0.1
  public var log: ((String) -> Void)?

  public init() {}
}

public enum ContextMenuCloseReason: String {
  case action
  case cancelled
  case outsideClick
  case appDeactivated
  case windowChanged
  case replaced
  case programmatic
}

/// Presents an NSMenu in our own panels. Callers keep building NSMenu and NSMenuItem as they do for the
/// native menu: targets and actions, nil targets through the responder chain, validation, submenus,
/// alternates, key equivalents, section headers, view items and menu delegates all keep working.
@MainActor
public final class ContextMenuSession: NSObject {
  public private(set) static weak var current: ContextMenuSession?
  private static var retained: Set<ContextMenuSession> = []

  public let menu: NSMenu
  public let options: ContextMenuOptions
  public private(set) weak var sourceView: NSView?
  public private(set) var isOpen = false
  public private(set) var closeReason: ContextMenuCloseReason?
  public var onClose: ((ContextMenuCloseReason) -> Void)?

  /// Seconds from the opening event to the panels being on screen, when an event opened the menu.
  public private(set) var eventToVisible: TimeInterval?
  /// Seconds spent inside `open()`, building and ordering the panels.
  public private(set) var openDuration: TimeInterval = 0
  /// Where `openDuration` went, in order.
  public private(set) var phaseDurations: [(String, TimeInterval)] = []

  public var openEventTimestamp: TimeInterval? { openEvent?.timestamp }

  private(set) var surfaces: [ContextMenuSurface] = []
  private var accessoryPanel: ContextMenuPanel?
  private var accessoryChrome: ContextMenuChromeView?
  private var accessoryIsAbove = true
  private weak var parentWindow: NSWindow?
  private let openEvent: NSEvent?
  private let anchor: NSPoint
  private var monitor: Any?
  private var observers: [NSObjectProtocol] = []
  private var modifiers: NSEvent.ModifierFlags = []
  private var typeSelect = ""
  private var typeSelectAt: CFTimeInterval = 0
  private var submenuTimer: Timer?
  private var deferredHover: Timer?
  private var lastPointer: NSPoint?
  private var openedAt: CFTimeInterval = 0
  /// The button that opened the menu is still held: its release can pick an item.
  private var openButtonHeld = false
  private var openButtonUp: NSEvent.EventType?
  private var pointerMovedSinceOpen = false
  private var pressInMenu: NSEvent.EventType?
  private var swallowUp: NSEvent.EventType?
  private var isActivating = false
  /// Opened at the pointer (a click) rather than at a given point (a button, a key).
  private var anchorIsPointer = true

  // MARK: Presenting

  @discardableResult
  public static func popUp(
    _ menu: NSMenu,
    with event: NSEvent?,
    for view: NSView,
    at screenPoint: NSPoint? = nil,
    options: ContextMenuOptions = ContextMenuOptions()
  ) -> ContextMenuSession? {
    current?.close(animated: false, reason: .replaced)
    guard let window = view.window else { return nil }
    let point: NSPoint
    if let screenPoint {
      point = screenPoint
    } else if let event, event.type != .keyDown {
      let eventWindow = event.window ?? window
      point = eventWindow.convertPoint(toScreen: event.locationInWindow)
    } else {
      point = NSEvent.mouseLocation
    }
    let session = ContextMenuSession(menu: menu, event: event, view: view, window: window, anchor: point, options: options)
    session.anchorIsPointer = screenPoint == nil
    session.open()
    return session
  }

  public static func closeAll() {
    current?.close(animated: false, reason: .programmatic)
  }

  private init(menu: NSMenu, event: NSEvent?, view: NSView, window: NSWindow, anchor: NSPoint, options: ContextMenuOptions) {
    self.menu = menu
    self.openEvent = event
    self.sourceView = view
    self.parentWindow = window
    self.anchor = anchor
    self.options = options
    super.init()
  }

  private func log(_ message: @autoclosure () -> String) {
    options.log?(message())
  }

  private var visibleFrame: NSRect {
    let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? parentWindow?.screen ?? NSScreen.main
    return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
  }

  private func open() {
    let start = CACurrentMediaTime()
    openedAt = start
    modifiers = NSEvent.modifierFlags

    if let openEvent {
      switch openEvent.type {
      case .rightMouseDown:
        openButtonHeld = true
        openButtonUp = .rightMouseUp
      case .leftMouseDown:
        openButtonHeld = true
        openButtonUp = .leftMouseUp
      case .otherMouseDown:
        openButtonHeld = true
        openButtonUp = .otherMouseUp
      default:
        break
      }
    }

    var marks: [(String, CFTimeInterval)] = []
    func mark(_ name: String) { marks.append((name, CACurrentMediaTime())) }
    prepare(menu)
    if let openEvent { sourceView?.willOpenMenu(menu, with: openEvent) }
    menu.delegate?.menuWillOpen?(menu)
    mark("prepare")

    let root = makeSurface(for: menu, parentRowIndex: nil)
    mark("makeSurface")
    let visible = visibleFrame
    let body = root.reload(modifiers: modifiers, maxHeight: visible.height - 16)
    mark("reload")
    let offset = anchorIsPointer ? options.metrics.pointerOffset : .zero
    var origin = NSPoint(x: anchor.x + offset.x, y: anchor.y + offset.y - body.height)
    // Native puts the menu's top-left at the pointer, flipping up or left where the screen ends.
    if origin.y < visible.minY { origin.y = anchor.y - offset.y }
    if origin.y + body.height > visible.maxY { origin.y = visible.maxY - body.height }
    if origin.x + body.width > visible.maxX { origin.x = anchor.x - offset.x - body.width }
    origin.x = max(origin.x, visible.minX)
    var menuRect = NSRect(origin: origin, size: body)

    if let accessory = options.accessoryView {
      menuRect = placeAccessory(accessory, menuRect: menuRect, visible: visible)
    }
    mark("accessory")
    root.setBodyOrigin(menuRect.origin)
    surfaces = [root]

    installMonitors()
    isOpen = true
    Self.current = self
    Self.retained.insert(self)

    if let accessoryPanel {
      show(accessoryPanel, chrome: accessoryChrome, pop: true)
    }
    show(root.panel, chrome: root.chrome, pop: false)
    mark("orderFront")

    NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
    NSAccessibility.post(element: root.content, notification: NSAccessibility.Notification(rawValue: "AXMenuOpened"))

    openDuration = CACurrentMediaTime() - start
    var previous = start
    phaseDurations = marks.map { name, time in
      defer { previous = time }
      return (name, time - previous)
    }
    if let openEvent {
      eventToVisible = ProcessInfo.processInfo.systemUptime - openEvent.timestamp
    }
    log("open items=\(root.content.rows.count) build=\(String(format: "%.1f", openDuration * 1000))ms eventToVisible=\(eventToVisible.map { String(format: "%.1f", $0 * 1000) } ?? "-")ms")
  }

  /// Positions the accessory beside the menu and returns the menu's final rect (it may move to make room).
  private func placeAccessory(_ accessory: NSView, menuRect: NSRect, visible: NSRect) -> NSRect {
    var menuRect = menuRect
    let size = accessory.fittingSize == .zero ? accessory.frame.size : accessory.fittingSize
    let metrics = options.metrics
    let configuration = options.accessoryConfiguration
    let panel = ContextMenuPanelPool.take()
    panel.appearance = parentWindow?.effectiveAppearance
    let margin = metrics.shadowMargin
    let chrome: ContextMenuChromeView?
    if configuration.usesMenuMaterial {
      let view = ContextMenuChromeView(margin: margin, radius: size.height / 2, material: options.material)
      view.frame = NSRect(x: 0, y: 0, width: size.width + 2 * margin, height: size.height + 2 * margin)
      accessory.frame = NSRect(origin: .zero, size: size)
      view.contentContainer.frame = NSRect(origin: .zero, size: size)
      view.contentContainer.addSubview(accessory)
      panel.contentView = view
      chrome = view
    } else {
      let host = NSView(frame: NSRect(x: 0, y: 0, width: size.width + 2 * margin, height: size.height + 2 * margin))
      accessory.frame = NSRect(x: margin, y: margin, width: size.width, height: size.height)
      host.addSubview(accessory)
      panel.contentView = host
      chrome = nil
    }
    panel.setContentSize(NSSize(width: size.width + 2 * margin, height: size.height + 2 * margin))

    let gap = configuration.spacing
    var x = switch configuration.alignment {
    case .leading: menuRect.minX
    case .center: menuRect.midX - size.width / 2
    case .trailing: menuRect.maxX - size.width
    }
    x += configuration.offset
    if x + size.width > visible.maxX { x = visible.maxX - size.width }
    x = max(x, visible.minX)
    var y: CGFloat
    let roomAbove = menuRect.maxY + gap + size.height <= visible.maxY
    let roomBelow = menuRect.minY - gap - size.height >= visible.minY
    defer { accessoryIsAbove = y > menuRect.midY }
    if configuration.location == .above, roomAbove {
      y = menuRect.maxY + gap
    } else if configuration.location == .below, roomBelow {
      y = menuRect.minY - gap - size.height
    } else if roomAbove {
      y = menuRect.maxY + gap
    } else if roomBelow {
      y = menuRect.minY - gap - size.height
    } else {
      // No room either side: slide the menu down under the accessory.
      y = visible.maxY - size.height
      menuRect.origin.y = min(menuRect.origin.y, y - gap - menuRect.height)
      menuRect.origin.y = max(menuRect.origin.y, visible.minY)
    }
    panel.setFrameOrigin(NSPoint(x: x - margin, y: y - margin))
    accessoryPanel = panel
    accessoryChrome = chrome
    return menuRect
  }

  private func makeSurface(for menu: NSMenu, parentRowIndex: Int?) -> ContextMenuSurface {
    let surface = ContextMenuSurface(
      menu: menu,
      metrics: options.metrics,
      material: options.material,
      parentRowIndex: parentRowIndex,
      appearance: parentWindow?.effectiveAppearance
    )
    surface.content.defaultIconEffect = options.defaultIconEffect
    surface.content.openSubmenuContent = { [weak self, weak surface] index in
      guard let self, let surface, let depth = self.surfaces.firstIndex(where: { $0 === surface }), depth + 1 < self.surfaces.count,
            self.surfaces[depth + 1].parentRowIndex == index else { return nil }
      return self.surfaces[depth + 1].content
    }
    surface.content.onAccessibilityPress = { [weak self, weak surface] index in
      guard let self, let surface, let depth = self.surfaces.firstIndex(where: { $0 === surface }) else { return }
      self.activate(depth: depth, row: index)
    }
    let tracker = ContextMenuTrackingView(frame: .zero) { [weak self] in
      self?.trackPointer(NSEvent.mouseLocation)
    }
    tracker.frame = surface.chrome.bounds
    tracker.autoresizingMask = [.width, .height]
    surface.chrome.addSubview(tracker, positioned: .below, relativeTo: nil)
    return surface
  }

  /// Delegate population and validation, as AppKit does right before showing a menu.
  private func prepare(_ menu: NSMenu) {
    if let delegate = menu.delegate {
      if let count = delegate.numberOfItems?(in: menu), count >= 0 {
        while menu.numberOfItems < count { menu.addItem(NSMenuItem()) }
        while menu.numberOfItems > count { menu.removeItem(at: menu.numberOfItems - 1) }
        for index in 0 ..< count {
          let keepGoing = delegate.menu?(menu, update: menu.items[index], at: index, shouldCancel: false) ?? true
          if !keepGoing { break }
        }
      }
      delegate.menuNeedsUpdate?(menu)
    }
    resolveContextTargets(in: menu)
    menu.update()
  }

  /// A context menu's items without a target act on the view that was clicked: AppKit looks for the
  /// action up that view's responder chain, not from the window's first responder (which is often the
  /// compose field). Validation and the action then reach the same object. Items whose action no view
  /// in that chain handles keep a nil target and go through the first responder chain as usual.
  private func resolveContextTargets(in menu: NSMenu) {
    for item in menu.items where item.target == nil {
      guard let action = item.action else { continue }
      var responder: NSResponder? = sourceView
      while let current = responder {
        if current.responds(to: action) {
          item.target = current
          break
        }
        responder = current.nextResponder
      }
    }
  }

  /// The open animation after Reduce Motion: no scaling, only the fade.
  private var effectiveAnimation: ContextMenuOptions.Animation {
    if options.animation == .pop, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return .fade }
    return options.animation
  }

  private func show(_ panel: NSPanel, chrome: NSView?, pop: Bool) {
    panel.orderFront(nil)
    switch effectiveAnimation {
    case .none:
      panel.alphaValue = 1
    case .fade:
      panel.alphaValue = 0
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.1
        panel.animator().alphaValue = 1
      }
    case .pop:
      panel.alphaValue = 0
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.12
        panel.animator().alphaValue = 1
      }
      if let layer = chrome?.layer {
        let local = panel.convertPoint(fromScreen: anchor)
        let point = chrome!.convert(local, from: nil)
        let fromScale: CGFloat = pop ? 0.6 : 0.88
        var transform = CATransform3DMakeTranslation(point.x, point.y, 0)
        transform = CATransform3DScale(transform, fromScale, fromScale, 1)
        transform = CATransform3DTranslate(transform, -point.x, -point.y, 0)
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: transform)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.mass = 1
        spring.stiffness = pop ? 320 : 420
        spring.damping = pop ? 22 : 30
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "pop")
      }
    }
  }

  // MARK: Closing

  /// Closes the menu and leaves the accessory where it is, for an accessory that grows into its own UI
  /// in place (the reactions bar opening the full emoji picker from its +). The menu's input handling
  /// ends here; close the returned handle when that UI is done. Nil when the menu has no accessory.
  @discardableResult
  public func closeMenuKeepingAccessory() -> ContextMenuDetachedAccessory? {
    guard isOpen, let panel = accessoryPanel else { return nil }
    if accessoryHasKeyboardFocus { _ = setAccessoryFocus(false) }
    accessoryPanel = nil
    accessoryChrome = nil
    close(animated: true, reason: .action)
    return ContextMenuDetachedAccessory(panel: panel)
  }

  public func close(animated: Bool = true, reason: ContextMenuCloseReason = .programmatic) {
    guard isOpen else { return }
    isOpen = false
    closeReason = reason
    submenuTimer?.invalidate()
    deferredHover?.invalidate()
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    observers = []

    if accessoryHasKeyboardFocus { _ = setAccessoryFocus(false) }
    for surface in surfaces.reversed() {
      surface.content.highlightedIndex = nil
      surface.menu.delegate?.menuDidClose?(surface.menu)
    }
    sourceView?.didCloseMenu(menu, with: openEvent)
    NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)

    var panels = surfaces.map(\.panel)
    if let accessoryPanel { panels.append(accessoryPanel) }
    let finish: () -> Void = { [surfaces] in
      for panel in panels {
        if let panel = panel as? ContextMenuPanel { ContextMenuPanelPool.give(panel) } else { panel.orderOut(nil) }
      }
      // View items go back to being free for the next presentation.
      for surface in surfaces {
        for row in surface.content.rows where row.kind == .view {
          row.item.view?.removeFromSuperview()
        }
      }
      Self.retained.remove(self)
    }
    if Self.current === self { Self.current = nil }
    log("close reason=\(reason.rawValue)")
    onClose?(reason)

    if animated, options.animation != .none {
      panels.forEach { $0.ignoresMouseEvents = true }
      NSAnimationContext.runAnimationGroup({ context in
        context.duration = reason == .action ? 0.18 : 0.12
        panels.forEach { $0.animator().alphaValue = 0 }
      }, completionHandler: finish)
    } else {
      finish()
    }
  }

  // MARK: Events

  private func installMonitors() {
    let mask: NSEvent.EventTypeMask = [
      .mouseMoved, .mouseEntered, .mouseExited,
      .leftMouseDown, .leftMouseUp, .leftMouseDragged,
      .rightMouseDown, .rightMouseUp, .rightMouseDragged,
      .otherMouseDown, .otherMouseUp, .otherMouseDragged,
      .scrollWheel, .keyDown, .keyUp, .flagsChanged,
    ]
    monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      guard let self else { return event }
      return self.handle(event)
    }
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.close(animated: false, reason: .appDeactivated) }
    })
    if let parentWindow {
      for name in [NSWindow.didResignKeyNotification, NSWindow.willMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
        observers.append(center.addObserver(forName: name, object: parentWindow, queue: .main) { [weak self] note in
          let reason = note.name.rawValue
          MainActor.assumeIsolated {
            self?.log("window \(reason)")
            self?.close(animated: false, reason: .windowChanged)
          }
        })
      }
    }
    observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.close(animated: false, reason: .windowChanged) }
    })
  }

  private func screenPoint(of event: NSEvent) -> NSPoint {
    if let window = event.window {
      return window.convertPoint(toScreen: event.locationInWindow)
    }
    return event.locationInWindow
  }

  private func surfaceDepth(at point: NSPoint) -> Int? {
    surfaces.lastIndex { $0.bodyScreenFrame.contains(point) }
  }

  private func accessoryContains(_ point: NSPoint) -> Bool {
    guard let accessoryPanel else { return false }
    let margin = options.metrics.shadowMargin
    return accessoryPanel.frame.insetBy(dx: margin, dy: margin).contains(point)
  }

  private var interactiveAccessory: ContextMenuAccessoryInteraction? {
    options.accessoryView as? ContextMenuAccessoryInteraction
  }

  /// Keyboard focus is in the accessory rather than the menu.
  public private(set) var accessoryHasKeyboardFocus = false

  private func setAccessoryFocus(_ focused: Bool) -> Bool {
    guard focused != accessoryHasKeyboardFocus, let accessory = interactiveAccessory else { return false }
    if focused {
      guard accessory.contextMenuSetKeyboardFocus(true) else { return false }
      accessoryHasKeyboardFocus = true
      if let root = surfaces.first {
        closeSubmenus(deeperThan: 0)
        root.content.highlightedIndex = nil
      }
    } else {
      _ = accessory.contextMenuSetKeyboardFocus(false)
      accessoryHasKeyboardFocus = false
    }
    return true
  }

  /// Routes one event while the menu is open. Returns the event to let it through, nil to swallow it.
  /// Public so a test can drive the menu with synthetic events.
  public func handle(_ event: NSEvent) -> NSEvent? {
    guard isOpen else { return event }
    if isActivating, event.type != .flagsChanged { return nil }
    switch event.type {
    case .keyDown:
      handleKeyDown(event)
      return nil
    case .keyUp:
      return nil
    case .flagsChanged:
      updateModifiers(event.modifierFlags)
      return event

    case .mouseMoved, .mouseEntered, .mouseExited, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
      let point = event.type == .mouseEntered || event.type == .mouseExited ? NSEvent.mouseLocation : screenPoint(of: event)
      if openButtonHeld, hypot(point.x - anchor.x, point.y - anchor.y) > 3 { pointerMovedSinceOpen = true }
      trackPointer(point)
      if accessoryContains(point) { return event }
      return event.type == .mouseEntered || event.type == .mouseExited ? event : nil

    case .leftMouseDown, .rightMouseDown, .otherMouseDown:
      let point = screenPoint(of: event)
      if let depth = surfaceDepth(at: point) {
        pressInMenu = upType(for: event.type)
        trackPointer(point)
        _ = depth
        return nil
      }
      if accessoryContains(point) { return event }
      close(animated: true, reason: .outsideClick)
      let passes = (event.type == .rightMouseDown && options.rightClickOutsideReopens) || options.outsideClickPassesThrough
      guard passes else {
        swallowUp = upType(for: event.type)
        return nil
      }
      // A click in a panel's shadow margin belongs to the window underneath.
      if event.window is ContextMenuPanel {
        redispatch(event, at: point)
        return nil
      }
      return event

    case .leftMouseUp, .rightMouseUp, .otherMouseUp:
      let point = screenPoint(of: event)
      if openButtonHeld, event.type == openButtonUp {
        openButtonHeld = false
        return releaseOpeningPress(at: point) ? nil : (accessoryContains(point) ? event : nil)
      }
      if pressInMenu == event.type {
        pressInMenu = nil
        if let depth = surfaceDepth(at: point), let row = surfaces[depth].rowIndex(atScreen: point) {
          activate(depth: depth, row: row)
        }
        return nil
      }
      if swallowUp == event.type {
        swallowUp = nil
        return nil
      }
      return event

    case .scrollWheel:
      let point = screenPoint(of: event)
      if surfaceDepth(at: point) != nil || accessoryContains(point) { return event }
      return nil

    default:
      return event
    }
  }

  private func redispatch(_ event: NSEvent, at point: NSPoint) {
    let target = NSApp.orderedWindows.first { !($0 is ContextMenuPanel) && $0.isVisible && $0.frame.contains(point) }
    guard let target, let copy = NSEvent.mouseEvent(
      with: event.type, location: target.convertPoint(fromScreen: point), modifierFlags: event.modifierFlags,
      timestamp: event.timestamp, windowNumber: target.windowNumber, context: nil,
      eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure
    ) else { return }
    NSApp.postEvent(copy, atStart: true)
  }

  private func upType(for down: NSEvent.EventType) -> NSEvent.EventType {
    switch down {
    case .leftMouseDown: .leftMouseUp
    case .rightMouseDown: .rightMouseUp
    default: .otherMouseUp
    }
  }

  /// The release of the press that opened the menu. A click (no movement) leaves the menu open;
  /// a press-drag-release picks what it ends on.
  private func releaseOpeningPress(at point: NSPoint) -> Bool {
    guard pointerMovedSinceOpen else {
      log("opening press released in place, menu stays")
      return true
    }
    if let depth = surfaceDepth(at: point), let row = surfaces[depth].rowIndex(atScreen: point) {
      log("press-drag-release on row \(row)")
      activate(depth: depth, row: row)
      return true
    }
    if accessoryContains(point), let tracking = interactiveAccessory {
      if tracking.contextMenuRelease(atScreen: point) {
        log("press-drag-release on accessory")
        close(animated: true, reason: .action)
      }
      return true
    }
    return true
  }

  // MARK: Pointer

  /// Hover from screen points, so it works the same for mouse-moved over our panels and for drags
  /// that the chat window owns.
  func trackPointer(_ point: NSPoint) {
    guard isOpen, !isActivating else { return }
    let previous = lastPointer
    lastPointer = point
    if openButtonHeld || accessoryContains(point) {
      interactiveAccessory?.contextMenuTrackPointer(atScreen: accessoryContains(point) ? point : nil)
    }

    guard let depth = surfaceDepth(at: point) else {
      // Off every menu: drop the highlight unless it holds an open submenu.
      if let last = surfaces.last, let index = last.content.highlightedIndex, last.content.rows[index].item.submenu == nil {
        setHighlight(depth: surfaces.count - 1, row: nil, viaMouse: true)
      }
      return
    }
    let row = surfaces[depth].rowIndex(atScreen: point)

    // Heading diagonally from a submenu's parent row toward the submenu: hold the highlight a moment.
    if depth + 1 < surfaces.count, let previous, isHeading(from: previous, to: point, toward: surfaces[depth + 1]) {
      deferredHover?.invalidate()
      deferredHover = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, let pointer = self.lastPointer, pointer == point else { return }
          self.setHighlight(depth: depth, row: row, viaMouse: true)
        }
      }
      RunLoop.current.add(deferredHover!, forMode: .common)
      return
    }
    deferredHover?.invalidate()
    setHighlight(depth: depth, row: row, viaMouse: true)
  }

  private func isHeading(from previous: NSPoint, to point: NSPoint, toward child: ContextMenuSurface) -> Bool {
    let frame = child.bodyScreenFrame
    let towardRight = frame.minX >= previous.x
    let edgeX = towardRight ? frame.minX : frame.maxX
    let top = NSPoint(x: edgeX, y: frame.maxY)
    let bottom = NSPoint(x: edgeX, y: frame.minY)
    return pointInTriangle(point, previous, top, bottom) && (towardRight ? point.x > previous.x : point.x < previous.x)
  }

  private func pointInTriangle(_ p: NSPoint, _ a: NSPoint, _ b: NSPoint, _ c: NSPoint) -> Bool {
    func sign(_ p1: NSPoint, _ p2: NSPoint, _ p3: NSPoint) -> CGFloat {
      (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y)
    }
    let d1 = sign(p, a, b), d2 = sign(p, b, c), d3 = sign(p, c, a)
    let hasNeg = d1 < 0 || d2 < 0 || d3 < 0
    let hasPos = d1 > 0 || d2 > 0 || d3 > 0
    return !(hasNeg && hasPos)
  }

  // MARK: Highlight and submenus

  /// The deepest surface with a highlight, or the deepest surface.
  private var activeDepth: Int {
    surfaces.lastIndex { $0.content.highlightedIndex != nil } ?? surfaces.count - 1
  }

  public var highlightedItem: NSMenuItem? {
    let surface = surfaces[activeDepth]
    return surface.content.highlightedIndex.map { surface.content.rows[$0].item }
  }

  public var openMenus: [NSMenu] { surfaces.map(\.menu) }

  // MARK: Inspection, for tests and probes

  /// Icon effects played in the root menu since it opened.
  public var rootIconEffectsPlayed: Int { surfaces.first?.content.iconEffectsPlayed ?? 0 }
  public var rootIconViewCount: Int { surfaces.first?.content.iconViewCount ?? 0 }
  public func rootIconTint(title: String) -> NSColor? {
    guard let content = surfaces.first?.content, let index = content.rows.firstIndex(where: { $0.item.title == title }) else { return nil }
    return content.iconTint(row: index)
  }
  /// The root menu's accessibility element for an item, as VoiceOver gets it.
  public func rootAccessibilityElement(title: String) -> NSAccessibilityElement? {
    guard let content = surfaces.first?.content, let index = content.rows.firstIndex(where: { $0.item.title == title }) else { return nil }
    return content.accessibilityElement(forRow: index)
  }
  public var rootPanel: NSPanel? { surfaces.first?.panel }

  /// Visible bodies on screen, for tests and for callers that place things around the menu.
  public var menuScreenFrames: [NSRect] { surfaces.map(\.bodyScreenFrame) }
  public var accessoryScreenFrame: NSRect? {
    accessoryPanel.map { $0.frame.insetBy(dx: options.metrics.shadowMargin, dy: options.metrics.shadowMargin) }
  }

  private func setHighlight(depth: Int, row: Int?, viaMouse: Bool) {
    let surface = surfaces[depth]
    let selectable = row.flatMap { surface.content.rows[$0].isSelectable ? $0 : nil }
    if selectable != nil, accessoryHasKeyboardFocus {
      _ = setAccessoryFocus(false)
    }
    if surface.content.highlightedIndex != selectable {
      surface.content.highlightedIndex = selectable
      surface.menu.delegate?.menu?(surface.menu, willHighlight: selectable.map { surface.content.rows[$0].item })
      if let selectable { surface.content.playIconEffect(row: selectable) }
    }
    if !viaMouse, let selectable { surface.scrollToVisible(selectable) }

    if depth + 1 < surfaces.count, surfaces[depth + 1].parentRowIndex != selectable {
      if viaMouse, selectable == nil {
        // Leaving the parent row into empty space keeps the submenu, like AppKit.
      } else {
        closeSubmenus(deeperThan: depth)
      }
    }
    submenuTimer?.invalidate()
    if viaMouse, let selectable, surface.content.rows[selectable].item.submenu != nil, depth + 1 >= surfaces.count {
      let timer = Timer(timeInterval: options.submenuDelay, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated { self?.openSubmenu(depth: depth, row: selectable, selectFirst: false) }
      }
      RunLoop.current.add(timer, forMode: .common)
      submenuTimer = timer
    }
  }

  private func closeSubmenus(deeperThan depth: Int) {
    while surfaces.count > depth + 1 {
      let surface = surfaces.removeLast()
      surface.content.highlightedIndex = nil
      surface.menu.delegate?.menuDidClose?(surface.menu)
      ContextMenuPanelPool.give(surface.panel)
    }
  }

  private func openSubmenu(depth: Int, row: Int, selectFirst: Bool) {
    guard isOpen, depth < surfaces.count else { return }
    let parent = surfaces[depth]
    guard parent.content.highlightedIndex == row, let submenu = parent.content.rows[row].item.submenu else { return }
    if depth + 1 < surfaces.count {
      if surfaces[depth + 1].parentRowIndex == row {
        if selectFirst { moveHighlight(by: 1, depth: depth + 1) }
        return
      }
      closeSubmenus(deeperThan: depth)
    }
    prepare(submenu)
    submenu.delegate?.menuWillOpen?(submenu)
    let surface = makeSurface(for: submenu, parentRowIndex: row)
    let visible = visibleFrame
    let body = surface.reload(modifiers: modifiers, maxHeight: visible.height - 16)
    let parentFrame = parent.bodyScreenFrame
    let rowFrame = parent.rowScreenFrame(row)
    var origin = NSPoint(x: parentFrame.maxX - 2, y: rowFrame.maxY + options.metrics.verticalPadding - body.height)
    if origin.x + body.width > visible.maxX { origin.x = parentFrame.minX - body.width + 2 }
    origin.y = max(origin.y, visible.minY)
    origin.y = min(origin.y, visible.maxY - body.height)
    surface.setBodyOrigin(origin)
    surfaces.append(surface)
    show(surface.panel, chrome: surface.chrome, pop: false)
    if selectFirst { moveHighlight(by: 1, depth: depth + 1) }
    log("submenu open \(submenu.title)")
  }

  // MARK: Keyboard

  private func handleKeyDown(_ event: NSEvent) {
    let flags = event.modifierFlags.intersection(MenuModel.relevantModifiers)
    // ⌘. cancels, as it does a native menu and most of the system.
    if flags == .command, event.charactersIgnoringModifiers == "." {
      close(animated: true, reason: .cancelled)
      return
    }
    if accessoryHasKeyboardFocus, !flags.contains(.command), !flags.contains(.control), handleAccessoryKey(event) {
      return
    }
    if flags.contains(.command) || flags.contains(.control) {
      for depth in surfaces.indices.reversed() {
        if let (item, row) = matchKeyEquivalent(event, in: surfaces[depth]) {
          log("key equivalent \(item.title)")
          activate(depth: depth, row: row)
          return
        }
      }
      NSSound.beep()
      return
    }
    let depth = activeDepth
    switch Int(event.keyCode) {
    case 125:
      if depth == 0, !accessoryIsAbove, isAtEdge(last: true), setAccessoryFocus(true) { return }
      moveHighlight(by: 1, depth: depth)
    case 126:
      if depth == 0, accessoryIsAbove, isAtEdge(last: false), setAccessoryFocus(true) { return }
      moveHighlight(by: -1, depth: depth)
    case 115, 116: moveHighlight(toEnd: false, depth: depth)
    case 119, 121: moveHighlight(toEnd: true, depth: depth)
    case 124:
      if let row = surfaces[depth].content.highlightedIndex, surfaces[depth].content.rows[row].item.submenu != nil {
        openSubmenu(depth: depth, row: row, selectFirst: true)
      }
    case 123:
      if depth > 0 { closeSubmenus(deeperThan: depth - 1) }
    case 49 where !typeSelect.isEmpty && CACurrentMediaTime() - typeSelectAt < 1.0:
      typeSelect += " "
      typeSelectAt = CACurrentMediaTime()
    case 36, 76, 49:
      if let row = surfaces[depth].content.highlightedIndex {
        activate(depth: depth, row: row)
      }
    case 53:
      close(animated: true, reason: .cancelled)
    default:
      guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty,
            characters.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == " " })
      else { return }
      let now = CACurrentMediaTime()
      if now - typeSelectAt > 1.0 { typeSelect = "" }
      typeSelect += characters
      typeSelectAt = now
      if let row = MenuModel.typeSelectMatch(typeSelect, in: surfaces[depth].content.rows) {
        setHighlight(depth: depth, row: row, viaMouse: false)
      }
    }
  }

  /// The root menu's highlight is on its first (or last) selectable row.
  private func isAtEdge(last: Bool) -> Bool {
    guard let root = surfaces.first, let index = root.content.highlightedIndex else { return false }
    let rows = root.content.rows
    return index == (last ? rows.lastIndex(where: \.isSelectable) : rows.firstIndex(where: \.isSelectable))
  }

  /// Keys while the accessory has focus. Returns false to let the menu handle the key (type-select).
  private func handleAccessoryKey(_ event: NSEvent) -> Bool {
    guard let accessory = interactiveAccessory else { return false }
    switch Int(event.keyCode) {
    case 123: accessory.contextMenuMoveKeyboardFocus(by: -1)
    case 124: accessory.contextMenuMoveKeyboardFocus(by: 1)
    case 36, 76, 49:
      if accessory.contextMenuActivateKeyboardFocus() {
        log("accessory activated from the keyboard")
        close(animated: true, reason: .action)
      }
    case 125, 126:
      let toMenu = (Int(event.keyCode) == 125) == accessoryIsAbove
      if toMenu {
        _ = setAccessoryFocus(false)
        moveHighlight(toEnd: !accessoryIsAbove, depth: 0)
      }
    case 53:
      close(animated: true, reason: .cancelled)
    default:
      // Typing a title leaves the accessory for the menu.
      _ = setAccessoryFocus(false)
      return false
    }
    return true
  }

  private func moveHighlight(by step: Int, depth: Int) {
    let content = surfaces[depth].content
    let rows = content.rows
    guard !rows.isEmpty else { return }
    var index = content.highlightedIndex ?? (step > 0 ? -1 : rows.count)
    for _ in 0 ..< rows.count {
      index += step
      guard rows.indices.contains(index) else { return }
      if rows[index].isSelectable {
        setHighlight(depth: depth, row: index, viaMouse: false)
        return
      }
    }
  }

  private func moveHighlight(toEnd: Bool, depth: Int) {
    let rows = surfaces[depth].content.rows
    let index = toEnd ? rows.lastIndex(where: \.isSelectable) : rows.firstIndex(where: \.isSelectable)
    if let index { setHighlight(depth: depth, row: index, viaMouse: false) }
  }

  private func matchKeyEquivalent(_ event: NSEvent, in surface: ContextMenuSurface) -> (NSMenuItem, Int)? {
    let typed = (event.charactersIgnoringModifiers ?? "").lowercased()
    let flags = event.modifierFlags.intersection(MenuModel.relevantModifiers)
    // Match every item, alternates included: ⌥⌘C reaches the folded alternate even if ⌥ was pressed late.
    for item in surface.menu.items where !item.isHidden && item.isEnabled && item.submenu == nil && !item.keyEquivalent.isEmpty {
      var mask = item.keyEquivalentModifierMask.intersection(MenuModel.relevantModifiers)
      var key = item.keyEquivalent
      if key.count == 1, key != key.lowercased() {
        mask.insert(.shift)
        key = key.lowercased()
      }
      let keyMatches = typed == key || (key == "\u{8}" && typed == "\u{7f}")
      guard keyMatches, flags == mask else { continue }
      if let row = surface.content.rows.firstIndex(where: { $0.item === item }) {
        return (item, row)
      }
      // A folded alternate: show it, then act on it.
      updateModifiers(flags)
      if let row = surface.content.rows.firstIndex(where: { $0.item === item }) {
        return (item, row)
      }
    }
    return nil
  }

  private func updateModifiers(_ flags: NSEvent.ModifierFlags) {
    let relevant = flags.intersection(MenuModel.relevantModifiers)
    guard relevant != modifiers.intersection(MenuModel.relevantModifiers) else { return }
    modifiers = flags
    let visible = visibleFrame
    for surface in surfaces {
      surface.reload(modifiers: flags, maxHeight: visible.height - 16)
    }
  }

  // MARK: Activation

  private func activate(depth: Int, row: Int) {
    guard isOpen, depth < surfaces.count else { return }
    let surface = surfaces[depth]
    guard surface.content.rows.indices.contains(row) else { return }
    let menuRow = surface.content.rows[row]
    guard menuRow.isSelectable else { return }
    let item = menuRow.item
    if item.submenu != nil {
      setHighlight(depth: depth, row: row, viaMouse: false)
      openSubmenu(depth: depth, row: row, selectFirst: true)
      return
    }
    surface.content.highlightedIndex = row
    isActivating = true
    // One blink, as AppKit confirms a pick, then close and send the action. Run-loop timers in common
    // modes, so this also runs inside nested run loops and event tracking.
    let step: TimeInterval = effectiveAnimation == .none ? 0 : 0.05
    after(step) {
      surface.content.highlightedIndex = nil
      self.after(step) {
        surface.content.highlightedIndex = row
        self.after(step) { self.finishActivation(item) }
      }
    }
  }

  private func after(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
    let timer = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated(body) }
    RunLoop.main.add(timer, forMode: .common)
  }

  private func finishActivation(_ item: NSMenuItem) {
    isActivating = false
    guard let owner = item.menu else { return }
    let index = owner.index(of: item)
    log("activate \(item.title)")
    close(animated: true, reason: .action)
    if index >= 0 {
      owner.performActionForItem(at: index)
    }
  }
}

/// Turns on mouse-moved delivery over a panel and reports the pointer.
final class ContextMenuTrackingView: NSView {
  private let onMove: () -> Void

  init(frame: NSRect, onMove: @escaping () -> Void) {
    self.onMove = onMove
    super.init(frame: frame)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self))
  }

  override func mouseMoved(with event: NSEvent) { onMove() }
  override func mouseEntered(with event: NSEvent) { onMove() }
  override func mouseExited(with event: NSEvent) { onMove() }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// An accessory left on screen after its menu closed (`closeMenuKeepingAccessory()`).
@MainActor
public final class ContextMenuDetachedAccessory {
  private var panel: ContextMenuPanel?

  init(panel: ContextMenuPanel) {
    self.panel = panel
  }

  public var isOpen: Bool { panel != nil }

  public func close(animated: Bool = true) {
    guard let panel else { return }
    self.panel = nil
    guard animated else {
      ContextMenuPanelPool.give(panel)
      return
    }
    panel.ignoresMouseEvents = true
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.15
      panel.animator().alphaValue = 0
    }, completionHandler: {
      MainActor.assumeIsolated { ContextMenuPanelPool.give(panel) }
    })
  }
}
