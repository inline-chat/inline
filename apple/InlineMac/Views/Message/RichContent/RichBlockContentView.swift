import AppKit
import InlineKit
import InlineProtocol

final class RichBlockContentView: NSView {
  var onDisclosureToggle: ((BlockContentPath, Bool) -> Void)?
  var onTextEntityClick: ((MessageTextEntityHit, NSAttributedString) -> Bool)?
  var onTextLongPress: ((NSEvent) -> Void)?

  private var nodeViews: [BlockContentPath: RichBlockRenderableView] = [:]
  private var previousContent: InlineProtocol.BlockContent?
  private var currentPlan: RichBlockLayoutPlan?
  private var messageStableID: Int64?
  private var isContentVisible = true

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    clipsToBounds = true
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(
    plan: RichBlockLayoutPlan,
    content: InlineProtocol.BlockContent,
    attributedText: NSAttributedString,
    baseFontSize: CGFloat,
    palette: RichBlockPalette,
    relatedMessage: InlineKit.Message,
    codePresentation: RichBlockCodePresentation = .syntaxHighlighted,
    renderStyle: MessageRenderStyle,
    animated: Bool
  ) {
    if messageStableID != relatedMessage.stableId {
      prepareForReuse()
      messageStableID = relatedMessage.stableId
    }
    let reconciliation = BlockContentReconciler.reconcile(previous: previousContent, current: content)
    previousContent = content
    currentPlan = plan
    let context = RichBlockRenderContext(
      attributedText: attributedText,
      baseFontSize: baseFontSize,
      palette: palette,
      relatedMessage: relatedMessage,
      interactions: .init(
        onTextEntityClick: { [weak self] hit, text in
          self?.onTextEntityClick?(hit, text) ?? false
        },
        onDisclosureToggle: { [weak self] path, expanded in
          self?.onDisclosureToggle?(path, expanded)
        }
      ),
      isContentVisible: isContentVisible,
      codePresentation: codePresentation,
      renderStyle: renderStyle,
      contentHorizontalInset: plan.contentHorizontalInset
    )

    let currentPaths = Set(plan.nodes.map(\.path))
    for path in Array(nodeViews.keys) where !currentPaths.contains(path) {
      if let removed = nodeViews.removeValue(forKey: path) {
        removed.prepareForReuse()
        removed.removeFromSuperview()
      }
    }

    let shouldAnimate = animated && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    var frameChanges: [(RichBlockRenderableView, CGRect)] = []
    for node in plan.nodes {
      let view: RichBlockRenderableView
      if reconciliation.reusablePaths.contains(node.path),
         let reusable = nodeViews[node.path],
         reusable.reuseKind == node.reuseKind
      {
        view = reusable
      } else {
        if let replaced = nodeViews.removeValue(forKey: node.path) {
          replaced.prepareForReuse()
          replaced.removeFromSuperview()
        }
        view = RichBlockViewFactory.make(for: node)
        nodeViews[node.path] = view
        addSubview(view)
      }
      // New renderers need their measured bounds before apply; image views use
      // those bounds to choose an initial decode target.
      if view.frame == .zero {
        view.frame = node.frame
      }
      view.apply(node: node, context: context)
      // Rich child text views perform their own native tracking. Connect their
      // existing hold timer independently of the optional selection experiment.
      let supportsTextHold: Bool = switch node.reuseKind {
      case .disclosure, .code: false
      default: onTextLongPress != nil
      }
      for surface in view.orderedTextSurfaces {
        surface.configureTextLongPress(supportsTextHold ? { [weak self] event in
          self?.onTextLongPress?(event)
        } : nil)
      }
      view.setContentVisible(isContentVisible)
      if shouldAnimate, view.frame != .zero, view.frame != node.frame {
        frameChanges.append((view, node.frame))
      } else {
        view.frame = node.frame
      }
    }

    animate(frameChanges)
  }

  func applyLayout(_ plan: RichBlockLayoutPlan, animated: Bool) {
    currentPlan = plan
    let shouldAnimate = animated && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let frameChanges = plan.nodes.compactMap { node -> (RichBlockRenderableView, CGRect)? in
      guard let view = nodeViews[node.path], view.reuseKind == node.reuseKind else { return nil }
      view.updateLayout(node: node)
      if shouldAnimate, view.frame != .zero, view.frame != node.frame {
        return (view, node.frame)
      }
      view.frame = node.frame
      return nil
    }
    animate(frameChanges)
  }

  func setContentVisible(_ visible: Bool) {
    guard isContentVisible != visible else { return }
    isContentVisible = visible
    for view in nodeViews.values {
      view.setContentVisible(visible)
    }
  }

  func consumeNestedHorizontalScroll(_ event: NSEvent) -> Bool {
    guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return false }
    let point = convert(event.locationInWindow, from: nil)
    guard bounds.contains(point),
          var candidate = hitTest(convert(point, to: superview)) else { return false }
    while candidate !== self {
      // Native nested scroll views already applied AppKit's natural direction,
      // momentum, and edge behavior. If the event continues up the responder
      // chain, consume it here so message swipe-to-reply cannot also claim it.
      if candidate is NSScrollView {
        return true
      }
      if let surface = candidate as? RichBlockHorizontalScrollSurface {
        return surface.consumeHorizontalScroll(event)
      }
      guard let parent = candidate.superview else { return false }
      candidate = parent
    }
    return false
  }

  /// Route native controls and selectable text within their actual bounds.
  func interactiveTextHitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, bounds.contains(point) else { return nil }
    func find(in view: NSView) -> NSView? {
      let local = view.convert(point, from: self)
      // visibleRect can extend outside a non-clipping view's bounds. Without
      // this check, an earlier paragraph steals clicks from following blocks.
      guard !view.isHidden, view.bounds.contains(local), view.visibleRect.contains(local) else { return nil }
      if let disclosure = view as? RichBlockDisclosureNodeView {
        return disclosure.interactiveHitTest(local)
      }
      if let text = view as? NSTextView, text.isSelectable { return text }
      if view is NSControl { return view }
      for child in view.subviews.reversed() {
        if let hit = find(in: child) { return hit }
      }
      return nil
    }
    for node in currentPlan?.nodes ?? [] {
      if let view = nodeViews[node.path], let hit = find(in: view) { return hit }
    }
    return nil
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    for view in nodeViews.values {
      view.prepareForReuse()
      view.removeFromSuperview()
    }
    nodeViews.removeAll(keepingCapacity: true)
    previousContent = nil
    currentPlan = nil
    messageStableID = nil
  }

  private func animate(_ changes: [(RichBlockRenderableView, CGRect)]) {
    guard !changes.isEmpty else { return }
    // Honor the enclosing row's immediate layout for local disclosure clicks.
    guard NSAnimationContext.current.duration > 0 else {
      for (view, frame) in changes { view.frame = frame }
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.16
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      for (view, frame) in changes {
        view.animator().frame = frame
      }
    }
  }
}
