import AppKit

/// Inline's context menu: an `NSMenu` that shows in our own panels instead of the system's.
///
/// Build it exactly like an `NSMenu` (items, targets and actions, nil targets through the responder
/// chain, validation, submenus, alternates, key equivalents, delegates), then hand it to AppKit through
/// one of the entry points below. Nothing here knows about messages: any view can use it, and any view
/// can sit beside it as its accessory (as on iOS), set with `accessoryViewProvider`.
///
/// AppKit's right-click path ends in a private `NSMenu` method, so overriding the public
/// `popUpContextMenu` catches nothing. The public hook is the menu request itself: every way to open a
/// context menu (right click, control-click, a text view through its delegate, VoiceOver's show menu on
/// a text view) asks a view for its menu first, so `intercept(_:for:in:)` presents there and returns
/// nil, and AppKit shows nothing.
///
/// ```swift
/// override func menu(for event: NSEvent) -> NSMenu? {
///   ContextMenu.intercept(makeMenu(), for: event, in: self)
/// }
/// func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at index: Int) -> NSMenu? {
///   ContextMenu.intercept(makeMenu(textItems: menu), for: event, in: view)
/// }
/// override func accessibilityPerformShowMenu() -> Bool {   // plain views only
///   ContextMenu.showForAccessibility(in: self) { makeMenu() }
/// }
/// ```
open class ContextMenu: NSMenu {
  /// False shows the system menu instead, with the same items.
  public var usesCustomPresentation = true
  public var options = ContextMenuOptions()
  /// Builds the accessory view (quick reactions, for a message) when the menu opens, so a menu that
  /// is never shown never builds one. Placement comes from `options.accessoryConfiguration`.
  public var accessoryViewProvider: (@MainActor () -> NSView?)?

  /// Fires on each presentation with the entry point used. For tests and diagnostics.
  @MainActor public static var presentationObserver: ((String) -> Void)?

  // MARK: Entry points

  /// For `menu(for:)`, `textView(_:menu:for:at:)` and any hook that returns the menu AppKit should
  /// show: presents a `ContextMenu` and returns nil; returns any other menu unchanged.
  @MainActor
  public static func intercept(_ menu: NSMenu?, for event: NSEvent, in view: NSView) -> NSMenu? {
    guard let menu else { return nil }
    return present(menu, event: event, view: view, at: nil, via: "intercept") ? nil : menu
  }

  /// For code that opens a menu itself (`NSMenu.popUpContextMenu`): ours for a `ContextMenu`, the
  /// system menu otherwise.
  @MainActor
  public static func popUp(_ menu: NSMenu, with event: NSEvent, for view: NSView) {
    if !present(menu, event: event, view: view, at: nil, via: "popUp") {
      NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
  }

  /// Opens a menu with its top-left at `point` in `view`, for menus opened from a button or a key.
  @MainActor
  public static func popUp(_ menu: NSMenu, at point: NSPoint, in view: NSView) {
    guard let window = view.window else { return }
    let screen = window.convertPoint(toScreen: view.convert(point, to: nil))
    if !present(menu, event: NSApp.currentEvent, view: view, at: screen, via: "popUpAtPoint") {
      menu.popUp(positioning: nil, at: point, in: view)
    }
  }

  /// VoiceOver's (and Full Keyboard Access's) show-menu on a plain view does not go through
  /// `menu(for:)`. Call this from `accessibilityPerformShowMenu()`; it opens the menu at the view.
  @MainActor
  public static func showForAccessibility(in view: NSView, menu makeMenu: () -> NSMenu?) -> Bool {
    guard let window = view.window, let menu = makeMenu() else { return false }
    let point = view.convert(NSPoint(x: min(40, view.bounds.midX), y: view.bounds.midY), to: nil)
    guard let event = NSEvent.mouseEvent(
      with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
    ) else { return false }
    popUp(menu, with: event, for: view)
    return true
  }

  /// Creates the panels ahead of the first menu, so the first right click opens as fast as later ones.
  @MainActor
  public static func prewarm() {
    ContextMenuPanelPool.prewarm()
  }

  /// The menu on screen, if any.
  @MainActor public static var current: ContextMenuSession? { ContextMenuSession.current }

  // MARK: Cancelling

  /// Code that cancels a menu it opened keeps working: this closes our panels when they show this menu.
  override open func cancelTracking() {
    if !closeOwnSession(animated: true) { super.cancelTracking() }
  }

  override open func cancelTrackingWithoutAnimation() {
    if !closeOwnSession(animated: false) { super.cancelTrackingWithoutAnimation() }
  }

  private func closeOwnSession(animated: Bool) -> Bool {
    let me = ObjectIdentifier(self)
    return MainActor.assumeIsolated {
      guard let session = ContextMenuSession.current, session.isOpen, ObjectIdentifier(session.menu) == me else { return false }
      session.close(animated: animated, reason: .programmatic)
      return true
    }
  }

  // MARK: Presenting

  @MainActor
  private static func present(_ menu: NSMenu, event: NSEvent?, view: NSView, at point: NSPoint?, via entry: String) -> Bool {
    guard let menu = menu as? ContextMenu, menu.usesCustomPresentation, view.window != nil else { return false }
    // AppKit asks for the menu twice for one control-click; the second ask must not reopen it.
    if let current = ContextMenuSession.current, current.isOpen, current.sourceView === view,
       let event, current.openEventTimestamp == event.timestamp {
      return true
    }
    presentationObserver?(entry)
    var options = menu.options
    if let accessory = menu.accessoryViewProvider?() {
      options.accessoryView = accessory
    }
    return ContextMenuSession.popUp(menu, with: event, for: view, at: point, options: options) != nil
  }
}
