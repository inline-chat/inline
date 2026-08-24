import AppKit
import InlineKit
import InlineProtocol

final class RichBlockContentView: NSView {
  var onDisclosureToggle: ((BlockContentPath, Bool) -> Void)?
  var onTextEntityClick: ((MessageTextEntityHit, NSAttributedString) -> Bool)?

  private var nodeViews: [BlockContentPath: RichBlockRenderableView] = [:]
  private var previousContent: InlineProtocol.BlockContent?
  private var currentPlan: RichBlockLayoutPlan?
  private var messageStableID: Int64?
  private var isContentVisible = true

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    clipsToBounds = true
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
    guard bounds.contains(point), var candidate = hitTest(point) else { return false }
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
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.16
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      for (view, frame) in changes {
        view.animator().frame = frame
      }
    }
  }
}
