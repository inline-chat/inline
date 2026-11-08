import AppKit

/// A message view that offers actions for text selected inside it.
@MainActor
protocol MessageSelectionMenuProviding: AnyObject {
  /// Actions for the current selection, or none when nothing in the message is selected.
  func messageSelectionMenuItems() -> [MessageSelectionMenu.Item]
}

/// The small glass capsule that floats above text once a mouse selection in a message ends,
/// so quoting part of a message doesn't need a right click. It lives inside the message list,
/// like the no-bubble quick actions, so its glass samples the messages behind it.
@MainActor
final class MessageSelectionMenu {
  struct Item {
    let title: String
    let handler: () -> Void
  }

  private static let shared = MessageSelectionMenu()

  private var menuView: MessageSelectionMenuView?
  private var eventMonitor: Any?
  private var observers: [NSObjectProtocol] = []
  private var pendingShow = 0

  /// Called after a mouse selection gesture in a message text view finishes.
  static func selectionTrackingEnded(in textView: NSTextView, at windowPoint: NSPoint) {
    shared.selectionTrackingEnded(in: textView, at: windowPoint)
  }

  private func selectionTrackingEnded(in textView: NSTextView, at windowPoint: NSPoint) {
    dismiss()
    pendingShow += 1
    let token = pendingShow
    // Let rich blocks finish coordinating a selection that spans surfaces first.
    Task { @MainActor [weak self, weak textView] in
      guard let self, let textView, token == self.pendingShow else { return }
      self.show(for: textView, at: windowPoint)
    }
  }

  private func show(for textView: NSTextView, at windowPoint: NSPoint) {
    guard let window = textView.window, window.isKeyWindow,
          let provider = provider(for: textView),
          let host = host(for: textView)
    else { return }
    let items = provider.messageSelectionMenuItems()
    guard !items.isEmpty else { return }

    let menuView = MessageSelectionMenuView(items: items) { [weak self] item in
      self?.dismiss()
      item.handler()
    }
    guard let frame = frame(for: menuView.frame.size, in: host, textView: textView, windowPoint: windowPoint)
    else { return }
    menuView.frame = frame
    menuView.alphaValue = 0
    host.addSubview(menuView, positioned: .above, relativeTo: nil)
    self.menuView = menuView
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.12
      menuView.animator().alphaValue = 1
    }
    startObserving(window)
  }

  private func dismiss() {
    pendingShow += 1
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers = []
    menuView?.removeFromSuperview()
    menuView = nil
  }

  private func provider(for view: NSView) -> MessageSelectionMenuProviding? {
    var current: NSView? = view
    while let candidate = current {
      if let provider = candidate as? MessageSelectionMenuProviding { return provider }
      current = candidate.superview
    }
    return nil
  }

  /// The message list's document view (outermost scroll view, past code-block scrollers),
  /// or the window content when the text isn't in a list.
  private func host(for view: NSView) -> NSView? {
    var outermost: NSScrollView?
    var current = view.superview
    while let candidate = current {
      if let scrollView = candidate as? NSScrollView { outermost = scrollView }
      current = candidate.superview
    }
    return outermost?.documentView ?? view.window?.contentView
  }

  /// Centers the menu on the pointer, just above the first selected line; below it when the
  /// top of the selection is scrolled away or there is no room above. Returns `host` coordinates.
  private func frame(for size: NSSize, in host: NSView, textView: NSTextView, windowPoint: NSPoint) -> NSRect? {
    guard let window = textView.window else { return nil }
    let gap: CGFloat = 6
    let visibleInWindow = textView.convert(textView.visibleRect, to: nil)

    var anchor = NSRect(x: windowPoint.x, y: windowPoint.y - 9, width: 0, height: 18)
    let selection = textView.selectedRange()
    if selection.length > 0 {
      let firstLine = window.convertFromScreen(textView.firstRect(forCharacterRange: selection, actualRange: nil))
      if !firstLine.isEmpty, firstLine.maxY <= visibleInWindow.maxY, firstLine.minY >= visibleInWindow.minY {
        anchor = firstLine
      }
    }

    // Work in window coordinates (y up), then convert into the host.
    let viewport = host.convert(host.visibleRect, to: nil)
    guard viewport.width >= size.width + 16, viewport.height >= size.height + 8 else { return nil }
    var y = anchor.maxY + gap
    if y + size.height > viewport.maxY - 4 {
      y = anchor.minY - gap - size.height
    }
    y = min(max(y, viewport.minY + 4), viewport.maxY - size.height - 4)
    let x = min(max(windowPoint.x - size.width / 2, viewport.minX + 8), viewport.maxX - size.width - 8)
    return host.convert(NSRect(x: x, y: y, width: size.width, height: size.height), from: nil)
  }

  private func startObserving(_ window: NSWindow) {
    eventMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
    ) { [weak self] event in
      MainActor.assumeIsolated {
        guard let self else { return }
        if event.type == .leftMouseDown, let menuView = self.menuView, event.window === menuView.window,
           menuView.bounds.contains(menuView.convert(event.locationInWindow, from: nil)) {
          return
        }
        self.dismiss()
      }
      return event
    }
    observers = [
      dismissObserver(NSWindow.didResignKeyNotification, window),
      dismissObserver(NSWindow.didResizeNotification, window),
      dismissObserver(NSWindow.willCloseNotification, window),
      dismissObserver(NSApplication.didResignActiveNotification, nil),
    ]
  }

  private func dismissObserver(_ name: Notification.Name, _ object: Any?) -> NSObjectProtocol {
    NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.dismiss() }
    }
  }
}

/// Text buttons on the same glass capsule as the no-bubble message quick actions
/// (`MessageQuickActionsView`): regular glass, interactive on macOS 27, soft shadow.
@MainActor
private final class MessageSelectionMenuView: NSView {
  enum Layout {
    static let height: CGFloat = 26
    static let padding: CGFloat = 2
    static let buttonHeight: CGFloat = height - padding * 2
    static let buttonPadding: CGFloat = 10
    static let dividerHeight: CGFloat = 12
    static var font: NSFont { .systemFont(ofSize: NSFont.smallSystemFontSize) }
  }

  private let surfaceView: NSView

  init(items: [MessageSelectionMenu.Item], onSelect: @escaping (MessageSelectionMenu.Item) -> Void) {
    let content = NSView()
    var x = Layout.padding
    for (index, item) in items.enumerated() {
      if index > 0 {
        let divider = NSBox()
        divider.boxType = .separator
        divider.frame = NSRect(
          x: x, y: (Layout.height - Layout.dividerHeight) / 2, width: 1, height: Layout.dividerHeight
        )
        content.addSubview(divider)
        x += 1
      }
      let button = MessageSelectionMenuButton(title: item.title) { onSelect(item) }
      let width = ceil(button.attributedTitle.size().width) + Layout.buttonPadding * 2
      button.frame = NSRect(x: x, y: Layout.padding, width: width, height: Layout.buttonHeight)
      content.addSubview(button)
      x += width
    }
    let size = NSSize(width: x + Layout.padding, height: Layout.height)
    let radius = Layout.height / 2

    if #available(macOS 26.0, *) {
      let glass = NSGlassEffectView()
      glass.style = .regular
      glass.cornerRadius = radius
      glass.contentView = content
      if #available(macOS 27.0, *) {
        glass.effectIsInteractive = true
      }
      surfaceView = glass
    } else {
      let surface = NSView()
      surface.wantsLayer = true
      surface.layer?.cornerRadius = radius
      surface.addSubview(content)
      surfaceView = surface
    }

    super.init(frame: NSRect(origin: .zero, size: size))
    wantsLayer = true
    layer?.masksToBounds = false
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = 0.1
    layer?.shadowRadius = 4
    layer?.shadowOffset = NSSize(width: 0, height: -2)
    layer?.shadowPath = CGPath(
      roundedRect: NSRect(origin: .zero, size: size), cornerWidth: radius, cornerHeight: radius, transform: nil
    )
    surfaceView.frame = bounds
    content.frame = bounds
    addSubview(surfaceView)
    updateAppearance()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateAppearance()
  }

  private func updateAppearance() {
    if #unavailable(macOS 26.0) {
      effectiveAppearance.performAsCurrentDrawingAppearance {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        surfaceView.layer?.backgroundColor = (isDark ? NSColor.controlBackgroundColor : .white).cgColor
      }
    }
  }
}

@MainActor
private final class MessageSelectionMenuButton: NSButton {
  private let onPress: () -> Void
  private var hoverTrackingArea: NSTrackingArea?
  private var isHovered = false {
    didSet { updateHoverFill() }
  }

  init(title: String, onPress: @escaping () -> Void) {
    self.onPress = onPress
    super.init(frame: .zero)
    self.title = title
    attributedTitle = NSAttributedString(string: title, attributes: [
      .font: MessageSelectionMenuView.Layout.font,
      .foregroundColor: NSColor.labelColor,
    ])
    isBordered = false
    bezelStyle = .smallSquare
    setButtonType(.momentaryChange)
    focusRingType = .none
    target = self
    action = #selector(press)
    setAccessibilityLabel(title)
    wantsLayer = true
    layer?.cornerRadius = MessageSelectionMenuView.Layout.buttonHeight / 2
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(bounds, cursor: .arrow)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    hoverTrackingArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    isHovered = true
    NSCursor.arrow.set()
  }

  override func mouseExited(with event: NSEvent) {
    isHovered = false
  }

  override func cursorUpdate(with event: NSEvent) {
    NSCursor.arrow.set()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateHoverFill()
  }

  /// Same light hover treatment as the quick action buttons.
  private func updateHoverFill() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = isHovered
        ? NSColor.gray.withAlphaComponent(0.1).cgColor
        : NSColor.clear.cgColor
    }
  }

  @objc private func press() {
    onPress()
  }
}
