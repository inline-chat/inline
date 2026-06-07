import AppKit
import InlineProtocol
import SwiftUI

@MainActor
final class BotPresenceWindow {
  private static let size = BotPresenceLayout.windowSize
  private static let margin: CGFloat = 24
  private static let originXKey = "BotPresence.window.origin.x"
  private static let originYKey = "BotPresence.window.origin.y"

  private var window: BotPresencePanel?
  private var hostingView: BotPresenceHostingView?
  private var surfaceModel: BotPresenceSurfaceModel?

  private(set) var avatar: InlineProtocol.BotAvatar?

  func show(
    avatar: InlineProtocol.BotAvatar,
    state: InlineProtocol.BotPresenceState,
    onIdle: @escaping @MainActor () -> Void,
    onClose: @escaping @MainActor () -> Void
  ) {
    self.avatar = avatar

    let shouldPlace = window?.isVisible != true
    let panel = window ?? makeWindow()
    let surfaceModel = surfaceModel ?? BotPresenceSurfaceModel(
      avatar: avatar,
      state: state,
      onIdle: onIdle,
      onClose: onClose,
      onJump: { [weak self] in
        self?.jump()
      },
      onDragEnd: { [weak self] in
        self?.saveWindowOrigin()
      }
    )
    surfaceModel.update(
      avatar: avatar,
      state: state,
      onIdle: onIdle,
      onClose: onClose,
      onJump: { [weak self] in
        self?.jump()
      },
      onDragEnd: { [weak self] in
        self?.saveWindowOrigin()
      }
    )

    let hostingView = hostingView ?? BotPresenceHostingView(
      rootView: AnyView(BotPresenceView(surface: surfaceModel))
    )

    panel.contentView = hostingView
    if shouldPlace {
      panel.setFrame(initialWindowFrame(), display: true)
    }
    panel.orderFront(nil)
    panel.refreshMouseHandling()

    window = panel
    self.hostingView = hostingView
    self.surfaceModel = surfaceModel
  }

  func hide() {
    window?.orderOut(nil)
  }

  private func makeWindow() -> BotPresencePanel {
    let panel = BotPresencePanel(
      contentRect: NSRect(origin: .zero, size: Self.size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.isMovableByWindowBackground = false
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    return panel
  }

  private func initialWindowFrame() -> NSRect {
    storedWindowFrame() ?? defaultWindowFrame()
  }

  private func defaultWindowFrame() -> NSRect {
    let bounds = anchorFrame()
    return NSRect(
      x: bounds.maxX - Self.size.width - Self.margin,
      y: bounds.minY + Self.margin,
      width: Self.size.width,
      height: Self.size.height
    )
  }

  private func storedWindowFrame() -> NSRect? {
    let defaults = UserDefaults.standard
    guard let x = defaults.object(forKey: Self.originXKey) as? Double,
          let y = defaults.object(forKey: Self.originYKey) as? Double
    else {
      return nil
    }

    return NSRect(
      x: CGFloat(x),
      y: CGFloat(y),
      width: Self.size.width,
      height: Self.size.height
    )
  }

  private func saveWindowOrigin() {
    guard let window else { return }
    let defaults = UserDefaults.standard
    defaults.set(Double(window.frame.minX), forKey: Self.originXKey)
    defaults.set(Double(window.frame.minY), forKey: Self.originYKey)
  }

  private func jump() {
    guard let window else { return }

    let origin = window.frame.origin
    let raised = NSPoint(x: origin.x, y: origin.y + 26)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.12
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      window.animator().setFrameOrigin(raised)
    } completionHandler: {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.16
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        window.animator().setFrameOrigin(origin)
      }
    }
  }

  private func anchorFrame() -> NSRect {
    if let window = NSApp.keyWindow, !(window is NSPanel) {
      return window.frame
    }

    if let window = NSApp.mainWindow, !(window is NSPanel) {
      return window.frame
    }

    if let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) {
      return window.frame
    }

    return NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
  }
}

private final class BotPresencePanel: NSPanel {
  private var mouseTimer: Timer?

  override init(
    contentRect: NSRect,
    styleMask style: NSWindow.StyleMask,
    backing backingStoreType: NSWindow.BackingStoreType,
    defer flag: Bool
  ) {
    super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
    acceptsMouseMovedEvents = true
  }

  deinit {
    stopMouseHandling()
  }

  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }

  override func orderFront(_ sender: Any?) {
    super.orderFront(sender)
    startMouseHandling()
    refreshMouseHandling()
  }

  override func orderOut(_ sender: Any?) {
    stopMouseHandling()
    ignoresMouseEvents = false
    super.orderOut(sender)
  }

  override func mouseMoved(with event: NSEvent) {
    refreshMouseHandling()
    super.mouseMoved(with: event)
  }

  fileprivate func refreshMouseHandling() {
    guard isVisible, let contentView else {
      ignoresMouseEvents = false
      return
    }

    let mouse = NSEvent.mouseLocation
    guard frame.contains(mouse) else {
      ignoresMouseEvents = false
      return
    }

    let windowPoint = convertPoint(fromScreen: mouse)
    let contentPoint = contentView.convert(windowPoint, from: nil)
    let hit = contentView.hitTest(contentPoint)
    let shouldIgnore = hit?.hasBotPresenceHitTargetAncestor != true
      && !BotPresenceLayout.characterRect(in: contentView.bounds, flipped: contentView.isFlipped).contains(contentPoint)
    if ignoresMouseEvents != shouldIgnore {
      ignoresMouseEvents = shouldIgnore
    }
  }

  private func startMouseHandling() {
    guard mouseTimer == nil else { return }
    let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      self?.refreshMouseHandling()
    }
    RunLoop.main.add(timer, forMode: .common)
    mouseTimer = timer
  }

  private func stopMouseHandling() {
    mouseTimer?.invalidate()
    mouseTimer = nil
  }
}

private final class BotPresenceHostingView: NSHostingView<AnyView> {
  override var isOpaque: Bool { false }

  @MainActor @preconcurrency required init(rootView: AnyView) {
    super.init(rootView: rootView)
    configure()
  }

  @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    configure()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    if let hit = super.hitTest(point), hit.hasBotPresenceHitTargetAncestor {
      return hit
    }

    guard BotPresenceLayout.characterRect(in: bounds, flipped: isFlipped).contains(point) else {
      return nil
    }

    return firstBotPresenceInteractionTarget(role: .character)
  }

  private func configure() {
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    layer?.isOpaque = false
  }
}

private extension NSView {
  var hasBotPresenceHitTargetAncestor: Bool {
    var view: NSView? = self
    while let current = view {
      if current is BotPresenceInteractionNSView || current is BotPresenceCloseButtonNSView {
        return true
      }
      view = current.superview
    }
    return false
  }

  func firstBotPresenceInteractionTarget(role: BotPresenceInteractionRole) -> BotPresenceInteractionNSView? {
    if let target = self as? BotPresenceInteractionNSView, target.role == role {
      return target
    }

    for subview in subviews {
      if let target = subview.firstBotPresenceInteractionTarget(role: role) {
        return target
      }
    }

    return nil
  }
}
