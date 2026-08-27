import AppKit
import QuartzCore

@MainActor
public final class InlineTooltipManager: NSObject {
  public static let shared = InlineTooltipManager()

  private enum Timing {
    static let initialDelay: Duration = .milliseconds(1_200)
    static let handoffGraceMilliseconds: Int64 = 300
    static let exitGrace: Duration = .milliseconds(handoffGraceMilliseconds)
    static let handoffWindow = TimeInterval(handoffGraceMilliseconds) / 1_000
    static let fadeIn: TimeInterval = 0.14
    static let fadeOut: TimeInterval = 0.22
  }

  private let bubbleView = InlineTooltipBubbleView()
  private lazy var panel = InlineTooltipPanel(contentView: bubbleView)
  private var showTask: Task<Void, Never>?
  private var hideTask: Task<Void, Never>?
  private weak var pendingAnchor: NSView?
  private weak var currentAnchor: NSView?
  private weak var parentWindow: NSWindow?
  private var currentPresentation: InlineTooltipResolvedContent?
  private var currentAnchorRect: CGRect?
  private var currentPlacement: InlineTooltipPlacement?
  private var mouseDownMonitor: Any?
  private var immediatePresentationDeadline = Date.distantPast
  private var isPresented = false
  private var transitionGeneration = 0

  override private init() {
    super.init()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(contextInvalidated(_:)),
      name: NSScrollView.willStartLiveScrollNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  public func show(
    _ content: InlineTooltipContent,
    anchoredTo anchor: NSView,
    placement: InlineTooltipPlacement = .automatic
  ) {
    scheduleShow(content, anchoredTo: anchor, anchorRect: nil, placement: placement)
  }

  public func show(
    _ content: InlineTooltipContent,
    anchoredTo anchorRect: CGRect,
    in anchor: NSView,
    placement: InlineTooltipPlacement = .automatic
  ) {
    scheduleShow(content, anchoredTo: anchor, anchorRect: anchorRect, placement: placement)
  }

  private func scheduleShow(
    _ content: InlineTooltipContent,
    anchoredTo anchor: NSView,
    anchorRect: CGRect?,
    placement: InlineTooltipPlacement
  ) {
    guard anchor.window != nil else { return }
    let resolved = content.resolved
    guard !resolved.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      hide(anchoredTo: anchor)
      return
    }

    showTask?.cancel()
    hideTask?.cancel()

    if requestMatches(
      resolved,
      anchor: anchor,
      anchorRect: anchorRect,
      placement: placement
    ) {
      pendingAnchor = nil
      return
    }

    pendingAnchor = anchor
    installMouseDownMonitor()

    if isPresented || Date() < immediatePresentationDeadline {
      showImmediately(
        content,
        anchoredTo: anchor,
        anchorRect: anchorRect,
        placement: placement
      )
      return
    }

    showTask = Task { [weak self, weak anchor] in
      do {
        try await Task.sleep(for: Timing.initialDelay)
      } catch {
        return
      }
      guard let self, let anchor, self.pendingAnchor === anchor else { return }
      self.showImmediately(
        content,
        anchoredTo: anchor,
        anchorRect: anchorRect,
        placement: placement
      )
    }
  }

  public func hide(anchoredTo anchor: NSView) {
    if pendingAnchor === anchor {
      showTask?.cancel()
      pendingAnchor = nil
      if !isPresented {
        removeMouseDownMonitor()
      }
    }

    guard currentAnchor === anchor else { return }
    hideTask?.cancel()
    immediatePresentationDeadline = Date().addingTimeInterval(Timing.handoffWindow)
    hideTask = Task { [weak self, weak anchor] in
      do {
        try await Task.sleep(for: Timing.exitGrace)
      } catch {
        return
      }
      guard let self, let anchor, self.currentAnchor === anchor else { return }
      self.dismiss(animated: true, preserveHandoffWindow: true)
    }
  }

  public func hide() {
    dismiss(animated: true, preserveHandoffWindow: false)
  }

  public func hideImmediately() {
    dismiss(animated: false, preserveHandoffWindow: false)
  }

  func targetWasRemoved(_ anchor: NSView) {
    guard pendingAnchor === anchor || currentAnchor === anchor else { return }
    dismiss(animated: false, preserveHandoffWindow: false)
  }

  func showImmediately(
    _ content: InlineTooltipContent,
    anchoredTo anchor: NSView,
    anchorRect: CGRect? = nil,
    placement: InlineTooltipPlacement
  ) {
    guard let sourceWindow = anchor.window else { return }
    let resolved = content.resolved

    showTask?.cancel()
    hideTask?.cancel()
    if requestMatches(
      resolved,
      anchor: anchor,
      anchorRect: anchorRect,
      placement: placement
    ) {
      pendingAnchor = nil
      return
    }

    let wasPresented = panel.isVisible
    bubbleView.update(resolved)
    let targetFrame = tooltipFrame(
      for: anchor,
      anchorRect: anchorRect,
      in: sourceWindow,
      size: bubbleView.intrinsicContentSize,
      placement: placement
    )

    pendingAnchor = nil
    currentAnchor = anchor
    currentPresentation = resolved
    currentAnchorRect = anchorRect
    currentPlacement = placement
    isPresented = true
    transitionGeneration += 1

    attachPanel(to: sourceWindow)
    installMouseDownMonitor()
    panel.setFrame(targetFrame, display: false)
    bubbleView.layoutSubtreeIfNeeded()
    panel.displayIfNeeded()

    if wasPresented {
      panel.alphaValue = 1
      return
    }

    panel.alphaValue = 0
    panel.orderFront(nil)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Timing.fadeIn
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().alphaValue = 1
    }
  }

  private func dismiss(animated: Bool, preserveHandoffWindow: Bool) {
    showTask?.cancel()
    hideTask?.cancel()
    showTask = nil
    hideTask = nil
    pendingAnchor = nil
    currentAnchor = nil
    currentPresentation = nil
    currentAnchorRect = nil
    currentPlacement = nil
    isPresented = false
    if !preserveHandoffWindow {
      immediatePresentationDeadline = .distantPast
    }

    transitionGeneration += 1
    let generation = transitionGeneration
    guard panel.isVisible else {
      finishDismissal(generation: generation)
      return
    }

    guard animated else {
      panel.alphaValue = 0
      finishDismissal(generation: generation)
      return
    }

    NSAnimationContext.runAnimationGroup({ context in
      context.duration = Timing.fadeOut
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      panel.animator().alphaValue = 0
    }, completionHandler: { [weak self] in
      Task { @MainActor in
        self?.finishDismissal(generation: generation)
      }
    })
  }

  private func finishDismissal(generation: Int) {
    guard generation == transitionGeneration, !isPresented else { return }
    removeMouseDownMonitor()
    if let parentWindow {
      parentWindow.removeChildWindow(panel)
      removeParentWindowObservers(from: parentWindow)
    }
    parentWindow = nil
    panel.orderOut(nil)
    panel.alphaValue = 1
  }

  private func requestMatches(
    _ presentation: InlineTooltipResolvedContent,
    anchor: NSView,
    anchorRect: CGRect?,
    placement: InlineTooltipPlacement
  ) -> Bool {
    isPresented
      && currentAnchor === anchor
      && currentPresentation == presentation
      && currentAnchorRect == anchorRect
      && currentPlacement == placement
  }

  private func installMouseDownMonitor() {
    guard mouseDownMonitor == nil else { return }
    mouseDownMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    ) { [weak self] event in
      MainActor.assumeIsolated {
        self?.hideImmediately()
      }
      return event
    }
  }

  private func removeMouseDownMonitor() {
    guard let mouseDownMonitor else { return }
    NSEvent.removeMonitor(mouseDownMonitor)
    self.mouseDownMonitor = nil
  }

  private func attachPanel(to sourceWindow: NSWindow) {
    if parentWindow !== sourceWindow {
      if let parentWindow {
        parentWindow.removeChildWindow(panel)
        removeParentWindowObservers(from: parentWindow)
      }
      sourceWindow.addChildWindow(panel, ordered: .above)
      addParentWindowObservers(to: sourceWindow)
      parentWindow = sourceWindow
    }
  }

  private func addParentWindowObservers(to window: NSWindow) {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(contextInvalidated(_:)),
      name: NSWindow.didMoveNotification,
      object: window
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(contextInvalidated(_:)),
      name: NSWindow.didResizeNotification,
      object: window
    )
  }

  private func removeParentWindowObservers(from window: NSWindow) {
    NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: window)
    NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: window)
  }

  @objc private func contextInvalidated(_: Notification) {
    hideImmediately()
  }

  private func tooltipFrame(
    for anchor: NSView,
    anchorRect: CGRect?,
    in sourceWindow: NSWindow,
    size: CGSize,
    placement: InlineTooltipPlacement
  ) -> CGRect {
    let frameOnScreen: CGRect
    let screen: NSScreen?
    if placement == .cursor {
      let cursorPoint = NSEvent.mouseLocation
      frameOnScreen = CGRect(origin: cursorPoint, size: .zero)
      screen = NSScreen.screens.first(where: { $0.frame.contains(cursorPoint) })
        ?? sourceWindow.screen
        ?? NSScreen.main
    } else {
      let frameInWindow = anchor.convert(anchorRect ?? anchor.bounds, to: nil)
      frameOnScreen = sourceWindow.convertToScreen(frameInWindow)
      screen = sourceWindow.screen
        ?? NSScreen.screens.first(where: { $0.frame.intersects(frameOnScreen) })
        ?? NSScreen.main
    }
    let visibleFrame = screen?.visibleFrame ?? frameOnScreen.insetBy(dx: -100, dy: -100)
    return InlineTooltipGeometry.frame(
      anchorFrame: frameOnScreen,
      tooltipSize: size,
      visibleFrame: visibleFrame,
      placement: placement,
      renderingInset: bubbleView.renderingInset
    )
  }
}

@MainActor
private final class InlineTooltipPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  init(contentView: NSView) {
    super.init(
      contentRect: CGRect(origin: .zero, size: contentView.intrinsicContentSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    self.contentView = contentView
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    ignoresMouseEvents = true
    isReleasedWhenClosed = false
    isFloatingPanel = true
    becomesKeyOnlyIfNeeded = false
    animationBehavior = .none
    level = .floating
    collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]
  }
}

@MainActor
final class InlineTooltipBubbleView: NSView {
  private enum Layout {
    static let renderingInset: CGFloat = 12
    static let horizontalPadding: CGFloat = 7
    static let verticalPadding: CGFloat = 2
    static let minimumSurfaceHeight: CGFloat = 24
    static let cornerRadius: CGFloat = minimumSurfaceHeight / 2
    static let shadowOpacity: Float = 0.14
    static let shadowRadius: CGFloat = 7
    static let shadowOffset = CGSize(width: 0, height: -2)
  }

  private let contentView = InlineTooltipContentView()
  private let surfaceContentView = NSView()
  private let surfaceView: NSView
  private var presentation: InlineTooltipResolvedContent?

  var renderingInset: CGFloat { Layout.renderingInset }

  override init(frame frameRect: NSRect) {
    if #available(macOS 26.0, *) {
      let glassView = NSGlassEffectView()
      glassView.style = .regular
      glassView.cornerRadius = Layout.cornerRadius
      glassView.contentView = surfaceContentView
      surfaceView = glassView
    } else {
      let effectView = NSVisualEffectView()
      effectView.material = .popover
      effectView.blendingMode = .behindWindow
      effectView.state = .active
      surfaceView = effectView
    }

    super.init(frame: frameRect)
    wantsLayer = true
    layer?.masksToBounds = false
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = Layout.shadowOpacity
    layer?.shadowRadius = Layout.shadowRadius
    layer?.shadowOffset = Layout.shadowOffset
    surfaceView.frame = bounds
    addSubview(surfaceView)

    if #unavailable(macOS 26.0) {
      surfaceView.wantsLayer = true
      surfaceView.layer?.cornerRadius = Layout.cornerRadius
      surfaceView.layer?.masksToBounds = true
      surfaceView.addSubview(surfaceContentView)
    }

    surfaceContentView.addSubview(contentView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    let contentSize = contentView.intrinsicContentSize
    return NSSize(
      width: contentSize.width + Layout.horizontalPadding * 2 + Layout.renderingInset * 2,
      height: max(
        Layout.minimumSurfaceHeight,
        contentSize.height + Layout.verticalPadding * 2
      ) + Layout.renderingInset * 2
    )
  }

  override func layout() {
    super.layout()
    surfaceView.frame = bounds.insetBy(dx: Layout.renderingInset, dy: Layout.renderingInset)
    layer?.shadowPath = CGPath(
      roundedRect: surfaceView.frame,
      cornerWidth: Layout.cornerRadius,
      cornerHeight: Layout.cornerRadius,
      transform: nil
    )
    surfaceContentView.frame = surfaceView.bounds
    contentView.frame = surfaceContentView.bounds.insetBy(
      dx: Layout.horizontalPadding,
      dy: Layout.verticalPadding
    )
    contentView.layoutSubtreeIfNeeded()
  }

  @discardableResult
  func update(_ presentation: InlineTooltipResolvedContent) -> Bool {
    guard self.presentation != presentation else { return false }
    self.presentation = presentation
    contentView.update(presentation)
    invalidateIntrinsicContentSize()
    needsLayout = true
    return true
  }

}

@MainActor
private final class InlineTooltipContentView: NSView {
  private enum Layout {
    static let contentSpacing: CGFloat = 5
    static let descriptionSpacing: CGFloat = 1
    static let maximumTextWidth: CGFloat = 280
  }

  private let textField = NSTextField(labelWithString: "")
  private let descriptionField = NSTextField(wrappingLabelWithString: "")
  private let shortcutView = InlineTooltipShortcutView()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    textField.font = .systemFont(ofSize: 11, weight: .regular)
    textField.textColor = .labelColor
    textField.lineBreakMode = .byTruncatingTail
    textField.maximumNumberOfLines = 1
    descriptionField.font = .systemFont(ofSize: 10, weight: .regular)
    descriptionField.textColor = .secondaryLabelColor
    descriptionField.lineBreakMode = .byWordWrapping
    descriptionField.maximumNumberOfLines = 3
    descriptionField.preferredMaxLayoutWidth = Layout.maximumTextWidth
    descriptionField.isHidden = true
    addSubview(textField)
    addSubview(descriptionField)
    addSubview(shortcutView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    let textSize = measuredTextSize
    let descriptionSize = measuredDescriptionSize
    let shortcutSize = shortcutView.intrinsicContentSize
    let hasShortcut = !shortcutView.isHidden
    let hasDescription = !descriptionField.isHidden
    let titleRowWidth = textSize.width + (hasShortcut ? Layout.contentSpacing + shortcutSize.width : 0)
    let titleRowHeight = max(textSize.height, hasShortcut ? shortcutSize.height : 0)
    return NSSize(
      width: max(titleRowWidth, hasDescription ? descriptionSize.width : 0),
      height: titleRowHeight + (hasDescription ? Layout.descriptionSpacing + descriptionSize.height : 0)
    )
  }

  override func layout() {
    super.layout()
    let textSize = measuredTextSize
    let descriptionSize = measuredDescriptionSize
    let shortcutSize = shortcutView.intrinsicContentSize
    let hasShortcut = !shortcutView.isHidden
    let hasDescription = !descriptionField.isHidden
    let titleRowHeight = max(textSize.height, hasShortcut ? shortcutSize.height : 0)
    let titleRowY = hasDescription
      ? descriptionSize.height + Layout.descriptionSpacing
      : backingPixelAligned((bounds.height - titleRowHeight) / 2)
    textField.frame = NSRect(
      x: 0,
      y: backingPixelAligned(titleRowY + (titleRowHeight - textSize.height) / 2),
      width: textSize.width,
      height: textSize.height
    )

    if hasShortcut {
      shortcutView.frame = NSRect(
        x: textSize.width + Layout.contentSpacing,
        y: backingPixelAligned(titleRowY + (titleRowHeight - shortcutSize.height) / 2),
        width: shortcutSize.width,
        height: shortcutSize.height
      )
    }

    if hasDescription {
      descriptionField.frame = NSRect(
        x: 0,
        y: 0,
        width: min(bounds.width, descriptionSize.width),
        height: descriptionSize.height
      )
    }
  }

  func update(_ presentation: InlineTooltipResolvedContent) {
    textField.stringValue = presentation.text
    descriptionField.stringValue = presentation.description ?? ""
    descriptionField.isHidden = presentation.description?.isEmpty != false
    shortcutView.update(labels: presentation.shortcut?.keycapLabels ?? [])
    invalidateIntrinsicContentSize()
    needsLayout = true
  }

  private var measuredTextSize: NSSize {
    let rawSize = textField.cell?.cellSize ?? textField.intrinsicContentSize
    return NSSize(
      width: min(ceil(rawSize.width), Layout.maximumTextWidth),
      height: ceil(rawSize.height)
    )
  }

  private var measuredDescriptionSize: NSSize {
    guard !descriptionField.isHidden else { return .zero }
    let naturalSize = descriptionField.intrinsicContentSize
    let width = min(ceil(naturalSize.width), Layout.maximumTextWidth)
    let rawSize = descriptionField.cell?.cellSize(
      forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
    ) ?? naturalSize
    return NSSize(width: width, height: ceil(rawSize.height))
  }
}

@MainActor
private final class InlineTooltipShortcutView: NSView {
  private static let spacing: CGFloat = 2
  private var keycapViews: [InlineTooltipKeycapView] = []
  private var visibleCount = 0

  override var intrinsicContentSize: NSSize {
    let visibleViews = keycapViews.prefix(visibleCount)
    let width = visibleViews.reduce(CGFloat.zero) { $0 + $1.intrinsicContentSize.width }
      + CGFloat(max(0, visibleCount - 1)) * Self.spacing
    let height = visibleViews.map(\.intrinsicContentSize.height).max() ?? 0
    return NSSize(width: width, height: height)
  }

  override func layout() {
    super.layout()
    var x: CGFloat = 0
    for keycap in keycapViews.prefix(visibleCount) {
      let size = keycap.intrinsicContentSize
      keycap.frame = NSRect(
        x: x,
        y: backingPixelAligned((bounds.height - size.height) / 2),
        width: size.width,
        height: size.height
      )
      x += size.width + Self.spacing
    }
  }

  func update(labels: [String]) {
    while keycapViews.count < labels.count {
      let keycap = InlineTooltipKeycapView()
      keycapViews.append(keycap)
      addSubview(keycap)
    }

    visibleCount = labels.count
    isHidden = labels.isEmpty
    for (index, keycap) in keycapViews.enumerated() {
      keycap.isHidden = index >= labels.count
      if index < labels.count {
        keycap.text = labels[index]
      }
    }
    invalidateIntrinsicContentSize()
    needsLayout = true
  }
}

@MainActor
private final class InlineTooltipKeycapView: NSView {
  private let textField = NSTextField(labelWithString: "")

  var text: String {
    get { textField.stringValue }
    set {
      textField.stringValue = newValue
      invalidateIntrinsicContentSize()
      needsLayout = true
    }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = 4
    textField.font = .systemFont(ofSize: 11, weight: .regular)
    textField.textColor = .secondaryLabelColor
    textField.alignment = .center
    addSubview(textField)
    updateBackground()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    let isCompactKey = text.count == 1
    let textWidth = ceil(textField.cell?.cellSize.width ?? textField.intrinsicContentSize.width)
    return NSSize(width: isCompactKey ? 16 : max(16, textWidth + 4), height: 16)
  }

  override func layout() {
    super.layout()
    let textSize = textField.cell?.cellSize ?? textField.intrinsicContentSize
    let scale = backingScaleFactor
    let height = ceil(textSize.height * scale) / scale
    textField.frame = NSRect(
      x: 0,
      y: round((bounds.height - height) * scale / 2) / scale,
      width: bounds.width,
      height: height
    )
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateBackground()
  }

  private func updateBackground() {
    let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(isDark ? 0.10 : 0.06).cgColor
    layer?.borderWidth = 0
  }
}

@MainActor
private extension NSView {
  var backingScaleFactor: CGFloat {
    window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
  }

  func backingPixelAligned(_ value: CGFloat) -> CGFloat {
    round(value * backingScaleFactor) / backingScaleFactor
  }
}
