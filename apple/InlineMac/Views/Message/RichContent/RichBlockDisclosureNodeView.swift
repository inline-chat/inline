import AppKit
import InlineKit

final class RichBlockDisclosureNodeView: RichBlockRenderableView {
  private let surface = RichBlockTextSurface(frame: .zero)
  private let activityIcon: NSImageView = {
    let view = NSImageView()
    view.symbolConfiguration = .init(pointSize: 11, weight: .regular)
    view.setAccessibilityElement(false)
    return view
  }()
  private let chevron = RichBlockDisclosureChevronView(frame: .zero)
  private let shimmer = RichBlockTextShimmerView(frame: .zero)
  private let statusIcon: NSImageView = {
    let view = NSImageView()
    view.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
    view.isHidden = true
    return view
  }()
  private let metaSurface = RichBlockTextSurface(frame: .zero)
  private var decoration: RichBlockDisclosureDecoration?
  private let toggleButton: NSButton = {
    let button = RichBlockDisclosureButton(title: "", target: nil, action: nil)
    button.isBordered = false
    button.isTransparent = true
    button.focusRingType = .none
    button.setButtonType(.momentaryChange)
    button.setAccessibilityElement(true)
    button.setAccessibilityRole(.button)
    return button
  }()

  private var path = BlockContentPath()
  private var expanded = false
  /// Nothing to disclose: no chevron, and clicks do not toggle.
  private var isEmpty = false
  private var progress = false
  private var activity: RichBlockActivityKind?
  private var isRTL = false
  private var onToggle: ((BlockContentPath, Bool) -> Void)?

  override var orderedTextSurfaces: [RichBlockTextSurface] { [surface] }

  init() {
    super.init(reuseKind: .disclosure)
    toggleButton.target = self
    toggleButton.action = #selector(toggleDisclosure)
    addSubview(toggleButton)
    addSubview(activityIcon)
    addSubview(surface)
    addSubview(chevron)
    addSubview(shimmer)
    addSubview(statusIcon)
    addSubview(metaSurface)
    metaSurface.isHidden = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func apply(node: RichBlockLayoutPlan.Node, context: RichBlockRenderContext) {
    guard case let .text(text) = node.kind,
          case let .disclosureSummary(progress, expanded, activity, isEmpty) = text.role
    else { return }
    let attributed = context.text(
      for: text,
      maximumWidth: RichBlockDisclosureMetrics.titleViewportWidth(
        containerWidth: node.frame.width,
        hasActivityIcon: activity != nil,
        hasChevron: !isEmpty
      )
    )
    self.path = node.path
    self.progress = progress
    self.activity = activity
    self.expanded = expanded
    self.isEmpty = isEmpty
    isRTL = text.isRTL
    onToggle = context.interactions.onDisclosureToggle
    chevron.tint = context.palette.secondary
    chevron.isHidden = isEmpty
    activityIcon.contentTintColor = context.palette.secondary
    activityIcon.image = activity.flatMap {
      NSImage(systemSymbolName: $0.symbolName, accessibilityDescription: nil)
    }
    activityIcon.isHidden = activity == nil
    updateChevron()
    surface.apply(
      text: attributed,
      linkColor: context.palette.link,
      singleLine: true,
      onEntityClick: context.interactions.onTextEntityClick
    )
    if isEmpty {
      surface.configurePlainSingleClick(nil)
    } else {
      surface.configurePlainSingleClick { [weak self] in
        self?.toggleDisclosure()
      }
    }
    shimmer.apply(color: .white)
    decoration = text.disclosure
    applyDecoration(context: context)
    let statusName = decoration?.status.map { ", \($0.accessibilityName)" } ?? ""
    toggleButton.setAccessibilityLabel(attributed.string + statusName)
    toggleButton.setAccessibilityValue(isEmpty ? nil : (expanded ? "Expanded" : "Collapsed"))
    toggleButton.setAccessibilityRole(isEmpty ? .staticText : .button)
    setContentVisible(context.isContentVisible)
    needsLayout = true
  }

  override func setContentVisible(_ visible: Bool) {
    super.setContentVisible(visible)
    let shouldAnimate = progress
      && visible
      && window != nil
      && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    shimmer.setAnimating(shouldAnimate)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    setContentVisible(isContentVisible)
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    surface.configurePlainSingleClick(nil)
    onToggle = nil
    isEmpty = false
    activity = nil
    activityIcon.image = nil
    activityIcon.isHidden = true
    decoration = nil
    statusIcon.isHidden = true
    metaSurface.isHidden = true
  }

  private func applyDecoration(context: RichBlockRenderContext) {
    let glyphStatus: RichBlockStatus? = switch decoration?.status {
    case .waiting?, .failed?, .cancelled?: decoration?.status
    default: nil
    }
    if let glyphStatus {
      statusIcon.image = NSImage(systemSymbolName: glyphStatus.symbolName, accessibilityDescription: nil)
      statusIcon.contentTintColor = glyphStatus.tint(context.palette)
      statusIcon.isHidden = false
    } else {
      statusIcon.isHidden = true
    }
    if let meta = decoration?.meta {
      metaSurface.apply(
        text: context.text(meta, role: .footer, isRTL: false, color: context.palette.tertiary),
        linkColor: context.palette.link,
        singleLine: true,
        onEntityClick: context.interactions.onTextEntityClick
      )
      metaSurface.isHidden = false
    } else {
      metaSurface.isHidden = true
    }
  }

  /// Width the planner reserved at the trailing end for status and meta.
  private var reservedTrailingWidth: CGFloat {
    guard let decoration else { return 0 }
    let glyph = statusIcon.isHidden ? 0 : RichBlockAgentMetrics.disclosureStatusSide + 4
    let visible = glyph + decoration.metaWidth
    return visible > 0 ? visible + RichBlockAgentMetrics.disclosureTrailingGap : 0
  }

  override func layout() {
    super.layout()
    toggleButton.frame = bounds
    let reserved = min(reservedTrailingWidth, max(0, bounds.width - 40))
    let rowBounds = isRTL
      ? CGRect(x: bounds.minX + reserved, y: bounds.minY, width: bounds.width - reserved, height: bounds.height)
      : CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width - reserved, height: bounds.height)
    let horizontalLayout = RichBlockDisclosureMetrics.horizontalLayout(
      bounds: rowBounds,
      intrinsicTitleWidth: surface.measuredWidth,
      isRTL: isRTL,
      hasActivityIcon: activity != nil,
      hasChevron: !isEmpty
    )
    surface.frame = horizontalLayout.titleFrame
    chevron.frame = horizontalLayout.chevronFrame
    activityIcon.frame = horizontalLayout.activityIconFrame ?? .zero
    shimmer.frame = surface.frame
    layoutDecoration(after: isRTL ? horizontalLayout.chevronFrame.minX : horizontalLayout.chevronFrame.maxX)
    surface.layoutSubtreeIfNeeded()
    shimmer.updateMask(from: surface)
  }

  private func layoutDecoration(after edge: CGFloat) {
    let gap = RichBlockAgentMetrics.disclosureTrailingGap
    let glyphSide = RichBlockAgentMetrics.disclosureStatusSide
    let metaWidth = metaSurface.isHidden ? 0 : (decoration?.metaWidth ?? 0)
    if isRTL {
      var x = edge - gap
      if !statusIcon.isHidden {
        x -= glyphSide
        statusIcon.frame = CGRect(x: x, y: floor((bounds.height - glyphSide) / 2), width: glyphSide, height: glyphSide)
        x -= 4
      }
      metaSurface.frame = CGRect(x: x - metaWidth, y: 0, width: metaWidth, height: bounds.height)
    } else {
      var x = edge + gap
      if !statusIcon.isHidden {
        statusIcon.frame = CGRect(x: x, y: floor((bounds.height - glyphSide) / 2), width: glyphSide, height: glyphSide)
        x += glyphSide + 4
      }
      metaSurface.frame = CGRect(x: x, y: 0, width: metaWidth, height: bounds.height)
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    interactiveHitTest(convert(point, from: superview))
  }

  /// Message gesture routing already supplies a point in this node's coordinates.
  func interactiveHitTest(_ point: NSPoint) -> NSView? {
    MessageGestureTrace.trace("Disclosure.hitTest local=\(MessageGestureTrace.point(point)) node=\(MessageGestureTrace.view(self)) selection=\(AppSettings.shared.richTextMultiSurfaceSelectionEnabled)")
    guard !isHidden, bounds.contains(point) else { return nil }
    let surfacePoint = surface.convert(point, from: self)
    if surface.hasInteractiveEntity(at: surfacePoint) {
      return surface.hitTest(surfacePoint) ?? toggleButton
    }
    if AppSettings.shared.richTextMultiSurfaceSelectionEnabled,
       let hit = surface.hitTest(surfacePoint)
    {
      return hit
    }
    return toggleButton
  }

  override func accessibilityPerformPress() -> Bool {
    guard !isEmpty else { return false }
    toggleDisclosure()
    return true
  }

  @objc private func toggleDisclosure() {
    MessageGestureTrace.debug("Disclosure.toggle path=\(path) from=\(expanded) callback=\(onToggle != nil)")
    guard !isEmpty else { return }
    expanded.toggle()
    updateChevron(animated: true)
    toggleButton.setAccessibilityValue(expanded ? "Expanded" : "Collapsed")
    onToggle?(path, expanded)
  }

  private func updateChevron(animated: Bool = false) {
    chevron.update(
      expanded: expanded,
      isRTL: isRTL,
      animated: animated && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    )
  }
}

/// The sidebar's section chevron in AppKit: one glyph that turns a quarter
/// toward the content when open, instead of swapping images.
private final class RichBlockDisclosureChevronView: NSView {
  var tint: NSColor = .secondaryLabelColor {
    didSet {
      guard tint != oldValue else { return }
      renderGlyph()
    }
  }

  private let glyph = CALayer()
  private var isRTL = false
  private var expanded = false

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    glyph.contentsGravity = .center
    layer?.addSublayer(glyph)
    setAccessibilityElement(false)
    renderGlyph()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(expanded: Bool, isRTL: Bool, animated: Bool) {
    if isRTL != self.isRTL {
      self.isRTL = isRTL
      renderGlyph()
    }
    guard expanded != self.expanded else { return }
    let from = glyph.presentation()?.transform ?? glyph.transform
    self.expanded = expanded
    let to = turn(expanded: expanded)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    glyph.transform = to
    CATransaction.commit()
    guard animated else {
      glyph.removeAnimation(forKey: "turn")
      return
    }
    let animation = CABasicAnimation(keyPath: "transform")
    animation.fromValue = from
    animation.toValue = to
    animation.duration = SidebarDisclosureMotion.duration
    animation.timingFunction = CAMediaTimingFunction(
      controlPoints: Float(SidebarDisclosureMotion.controlPoint1.x),
      Float(SidebarDisclosureMotion.controlPoint1.y),
      Float(SidebarDisclosureMotion.controlPoint2.x),
      Float(SidebarDisclosureMotion.controlPoint2.y)
    )
    glyph.add(animation, forKey: "turn")
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    glyph.position = CGPoint(x: bounds.midX, y: bounds.midY)
    CATransaction.commit()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    renderGlyph()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    renderGlyph()
  }

  /// A quarter turn toward the content: clockwise from `chevron.right`,
  /// counterclockwise from `chevron.left`. The view is flipped, so a positive
  /// angle turns clockwise on screen.
  private func turn(expanded: Bool) -> CATransform3D {
    guard expanded else { return CATransform3DIdentity }
    return CATransform3DMakeRotation((isRTL ? -1 : 1) * .pi / 2, 0, 0, 1)
  }

  private func renderGlyph() {
    let configuration = NSImage.SymbolConfiguration(
      pointSize: RichBlockDisclosureMetrics.chevronPointSize,
      weight: .semibold
    )
    .applying(.init(paletteColors: [tint]))
    guard let image = NSImage(
      systemSymbolName: isRTL ? "chevron.left" : "chevron.right",
      accessibilityDescription: nil
    )?.withSymbolConfiguration(configuration) else { return }
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    var contents: Any?
    effectiveAppearance.performAsCurrentDrawingAppearance {
      contents = image.layerContents(forContentsScale: scale)
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    glyph.contents = contents
    glyph.contentsScale = scale
    glyph.bounds = CGRect(origin: .zero, size: image.size)
    glyph.position = CGPoint(x: bounds.midX, y: bounds.midY)
    CATransaction.commit()
  }
}

private final class RichBlockDisclosureButton: NSButton {
  override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    MessageGestureTrace.debug("DisclosureButton.mouseDown \(MessageGestureTrace.eventDescription(event)) button=\(MessageGestureTrace.view(self))")
    super.mouseDown(with: event)
    MessageGestureTrace.debug("DisclosureButton.mouseDown returned")
  }

  override func accessibilityPerformPress() -> Bool {
    guard isEnabled, let action else { return false }
    let handled = NSApp.sendAction(action, to: target, from: self)
    MessageGestureTrace.debug("DisclosureButton.accessibilityPress handled=\(handled)")
    return handled
  }
}
