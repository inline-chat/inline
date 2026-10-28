import InlineMessageLayout
import UIKit

/// Inline's own message context menu, after Telegram iOS's context controller.
///
/// The bubble lifts out of the chat into an overlay over the window: a blur and dim, then one
/// scrolling column with the reaction bar, the bubble and the actions. A bubble taller than the
/// screen scrolls with its menu, opening at the bottom so the actions show. The preview can be
/// a live message view, and its text can be selected. The keyboard is left alone; the column
/// fits above it, so the chat underneath never moves.
@MainActor
final class MessageContextMenuController: NSObject, UIGestureRecognizerDelegate {
  struct Source {
    /// Draws the bubble: a live message view or a bitmap, sized to `frame`.
    var preview: UIView
    /// The bubble's frame in window coordinates, without the press shrink.
    var frame: CGRect
    /// The press shrink on the source as the menu opens; the preview grows from it.
    var pressedScale: CGFloat = 1
    var alignment: ContextMenuLayout.Alignment
    var selectableText: SelectableText?
    /// The bubble's frame now, in window coordinates, for the flight back; nil once it's gone.
    var currentFrame: () -> CGRect?
    var setHidden: (Bool) -> Void
  }

  struct SelectableText {
    var layout: TextLayout
    /// The text block in the preview's coordinates.
    var frame: CGRect
    var colors: MessageTextSelectionView.Colors
  }

  struct Content {
    /// Builds the actions. While part of the text is selected the menu shows its own Copy and
    /// Select All above them, so a builder drops its whole-message Copy.
    var menu: (_ hasTextSelection: Bool) -> UIMenu
    /// A view above the bubble, such as the reaction bar, sized by its own constraints.
    var accessory: UIView?
    /// Copies the selected text; the default puts it on the pasteboard as plain text.
    var copySelection: ((String) -> Void)?
  }

  /// The menu starts closing.
  var onWillDismiss: (() -> Void)?
  /// The menu is gone and the source shows again.
  var onDidDismiss: (() -> Void)?
  private(set) var isDismissing = false

  private let source: Source
  private let content: Content
  private let configuration: MessageContextMenuConfiguration
  private weak var window: UIWindow?

  private let overlay = OverlayView()
  private let blurView = UIVisualEffectView(effect: nil)
  private let dimView = UIView()
  private let scrollView = MenuScrollView()
  private let previewHost = PreviewHostView()
  private let accessoryHost = UIView()
  private let actionsView: MessageContextMenuActionsView
  private var selectionView: MessageTextSelectionView?
  private var safeInsets = ContextMenuLayout.Insets.zero
  private var plan: ContextMenuLayout.Result?
  private var selectionState: (hasSelection: Bool, selectsAll: Bool) = (false, false)
  private var holdStart: CGPoint?
  private var isTrackingHold = false
  private var pendingActions: [() -> Void] = []

  init(source: Source, content: Content, configuration: MessageContextMenuConfiguration = .standard) {
    self.source = source
    self.content = content
    self.configuration = configuration
    actionsView = MessageContextMenuActionsView(menu: content.menu(false), style: configuration.style)
    super.init()
  }

  // MARK: - Presenting

  /// Shows the menu over `window`. `keyboardHeight` is how far the keyboard reaches up from the
  /// window's bottom; the column stays above it.
  func present(in window: UIWindow, keyboardHeight: CGFloat) {
    self.window = window
    overlay.frame = window.bounds
    overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    overlay.accessibilityViewIsModal = true
    overlay.onEscape = { [weak self] in
      self?.dismiss()
      return true
    }
    overlay.onSizeChange = { [weak self] in
      self?.dismiss(animated: false)
    }

    blurView.frame = overlay.bounds
    blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    dimView.frame = overlay.bounds
    dimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    dimView.backgroundColor = configuration.dimColor
    dimView.alpha = 0
    dimView.isUserInteractionEnabled = false
    overlay.addSubview(blurView)
    overlay.addSubview(dimView)

    let keyboard = max(0, keyboardHeight)
    scrollView.frame = CGRect(x: 0, y: 0, width: window.bounds.width, height: window.bounds.height - keyboard)
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.showsVerticalScrollIndicator = false
    scrollView.delaysContentTouches = false
    scrollView.canCancelContentTouches = true
    scrollView.blocksPan = { [weak self] point in
      guard let self, let selectionView else { return false }
      return selectionView.isHandle(at: scrollView.convert(point, to: selectionView))
    }
    overlay.addSubview(scrollView)
    let safe = window.safeAreaInsets
    safeInsets = ContextMenuLayout.Insets(
      top: safe.top,
      left: safe.left,
      bottom: keyboard > 0 ? 0 : safe.bottom,
      right: safe.right
    )

    previewHost.frame = CGRect(origin: .zero, size: source.frame.size)
    source.preview.frame = previewHost.bounds
    source.preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    previewHost.addSubview(source.preview)
    if let text = source.selectableText {
      let view = MessageTextSelectionView(layout: text.layout, textFrame: text.frame, colors: text.colors)
      view.frame = previewHost.bounds
      view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      view.onSelectionChange = { [weak self] _ in self?.selectionChanged() }
      previewHost.addSubview(view)
      previewHost.selectionView = view
      selectionView = view
    }
    scrollView.addSubview(previewHost)

    if let accessory = content.accessory {
      accessory.translatesAutoresizingMaskIntoConstraints = false
      accessoryHost.addSubview(accessory)
      NSLayoutConstraint.activate([
        accessory.centerXAnchor.constraint(equalTo: accessoryHost.centerXAnchor),
        accessory.centerYAnchor.constraint(equalTo: accessoryHost.centerYAnchor),
      ])
      scrollView.addSubview(accessoryHost)
    }

    actionsView.onSelect = { [weak self] row in self?.select(row) }
    actionsView.onContentSizeChange = { [weak self] in self?.relayout(animated: true) }
    actionsView.prepareFeedback()
    scrollView.addSubview(actionsView)

    let tap = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap))
    tap.delegate = self
    scrollView.addGestureRecognizer(tap)

    window.addSubview(overlay)
    let plan = makePlan(sourceInViewport: source.frame)
    apply(plan, updatesOffset: true)
    source.setHidden(true)
    animateIn(plan)

    UIAccessibility.post(notification: .screenChanged, argument: actionsView.firstRow)
  }

  private var availableWidth: CGFloat {
    let width = window?.bounds.width ?? scrollView.bounds.width
    return max(0, width - safeInsets.left - safeInsets.right - configuration.layoutMetrics.sideInset * 2)
  }

  private func makePlan(sourceInViewport: CGRect) -> ContextMenuLayout.Result {
    let menuSize = actionsView.sizeThatFits(CGSize(width: availableWidth, height: .greatestFiniteMagnitude))
    let accessorySize = content.accessory.map { $0.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize) }
    let scale = window?.screen.scale ?? 3
    return ContextMenuLayout.plan(ContextMenuLayout.Input(
      viewport: scrollView.bounds.size,
      safeInsets: safeInsets,
      source: sourceInViewport,
      menuSize: menuSize,
      accessorySize: accessorySize,
      alignment: source.alignment,
      metrics: configuration.layoutMetrics,
      grid: PixelGrid(scale: scale)
    ))
  }

  private func apply(_ plan: ContextMenuLayout.Result, updatesOffset: Bool) {
    self.plan = plan
    scrollView.contentSize = plan.contentSize
    scrollView.alwaysBounceVertical = plan.isScrollable
    if updatesOffset {
      scrollView.contentOffset = CGPoint(x: 0, y: plan.contentOffsetY)
    }
    previewHost.untransformedFrame = plan.preview
    actionsView.layer.anchorPoint = plan.menuAnchor
    actionsView.untransformedFrame = plan.menu
    if let frame = plan.accessory {
      accessoryHost.layer.anchorPoint = CGPoint(x: plan.menuAnchor.x, y: 1)
      accessoryHost.untransformedFrame = frame
    }
  }

  private func animateIn(_ plan: ContextMenuLayout.Result) {
    let motion = configuration.motion
    let blur = configuration.backgroundBlur.map { UIBlurEffect(style: $0) }
    let animated = [previewHost, actionsView, accessoryHost]

    if UIAccessibility.isReduceMotionEnabled {
      animated.forEach { $0.alpha = 0 }
      UIView.animate(withDuration: motion.backgroundDuration) { [self] in
        blurView.effect = blur
        dimView.alpha = 1
        animated.forEach { $0.alpha = 1 }
      }
      return
    }

    UIView.animate(
      withDuration: motion.backgroundDuration,
      delay: 0,
      options: [.curveEaseOut, .allowUserInteraction]
    ) { [self] in
      blurView.effect = blur
      dimView.alpha = 1
    }

    // Everything rides from where the bubble was in the chat.
    let start = plan.contentRect(fromViewport: source.frame)
    let delta = CGPoint(x: start.midX - plan.preview.midX, y: start.midY - plan.preview.midY)
    let offset = NSValue(cgPoint: delta)
    let zero = NSValue(cgPoint: .zero)
    previewHost.layer.addContextMenuSpring("position", from: offset, to: zero, additive: true, motion: motion)
    if source.pressedScale < 1 {
      previewHost.layer.addContextMenuSpring(
        "transform.scale", from: source.pressedScale, to: 1.0, additive: false, motion: motion
      )
    }

    for (view, initialScale) in [(actionsView as UIView, 0.01), (accessoryHost, 0.2)] where view.superview != nil {
      view.alpha = 0
      UIView.animate(withDuration: 0.08, delay: 0, options: [.allowUserInteraction]) { view.alpha = 1 }
      view.layer.addContextMenuSpring("transform.scale", from: initialScale, to: 1.0, additive: false, motion: motion)
      view.layer.addContextMenuSpring("position", from: offset, to: zero, additive: true, motion: motion)
    }
  }

  /// Lays the column out again after the menu changed size, keeping the bubble where it is
  /// unless the menu no longer fits under it.
  private func relayout(animated: Bool) {
    guard !isDismissing, plan != nil else { return }
    let current = previewHost.untransformedFrame.offsetBy(dx: 0, dy: -scrollView.contentOffset.y)
    let plan = makePlan(sourceInViewport: current)
    let changes = { [self] in
      apply(plan, updatesOffset: true)
      actionsView.layoutIfNeeded()
    }
    if animated, !UIAccessibility.isReduceMotionEnabled {
      UIView.animate(
        springDuration: 0.35,
        bounce: 0,
        initialSpringVelocity: 0,
        delay: 0,
        options: [.beginFromCurrentState, .allowUserInteraction],
        animations: changes
      )
    } else {
      changes()
    }
  }

  // MARK: - Dismissing

  /// Closes the menu, flying the bubble back to the chat, then runs `action`.
  func dismiss(animated: Bool = true, then action: (() -> Void)? = nil) {
    if let action { pendingActions.append(action) }
    guard !isDismissing else { return }
    isDismissing = true
    overlay.isUserInteractionEnabled = false
    onWillDismiss?()

    let finish = { [self] in
      source.setHidden(false)
      overlay.removeFromSuperview()
      onDidDismiss?()
      let actions = pendingActions
      pendingActions.removeAll()
      actions.forEach { $0() }
    }
    guard animated, overlay.window != nil else {
      finish()
      return
    }

    for view in [previewHost, actionsView, accessoryHost] {
      view.layer.freezeContextMenuAnimations()
    }
    let target = UIAccessibility.isReduceMotionEnabled
      ? nil
      : source.currentFrame().map { scrollView.convert($0, from: nil) }
    UIView.animate(
      withDuration: configuration.motion.dismissDuration,
      delay: 0,
      options: [.curveEaseInOut, .beginFromCurrentState]
    ) { [self] in
      blurView.effect = nil
      dimView.alpha = 0
      for view in [actionsView as UIView, accessoryHost] {
        view.transform = CGAffineTransform(scaleX: 0.01, y: 0.01)
        view.alpha = 0
      }
      selectionView?.alpha = 0
      if let target {
        previewHost.transform = .identity
        previewHost.untransformedFrame = target
      } else {
        previewHost.alpha = 0
      }
    } completion: { _ in
      finish()
    }
  }

  @objc private func handleBackgroundTap() {
    dismiss()
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    let point = touch.location(in: scrollView)
    if actionsView.frame.contains(point) { return false }
    if accessoryHost.superview != nil, accessoryHost.frame.contains(point) { return false }
    // With a selection, a tap on the bubble clears it instead of closing the menu.
    if previewHost.frame.contains(point), selectionView?.hasSelection == true { return false }
    return true
  }

  // MARK: - Actions

  private func select(_ row: MessageContextMenuRowView) {
    guard !isDismissing else { return }
    switch row.element {
    case let .action(action):
      guard !action.attributes.contains(.disabled) else { return }
      if action.attributes.contains(.keepsMenuPresented) {
        row.sendAction(action)
      } else {
        // The handler runs once the menu is gone, so anything it presents shows on top.
        dismiss { row.sendAction(action) }
      }
    case let .submenu(menu):
      actionsView.open(menu)
    case .back:
      actionsView.goBack()
    }
  }

  // MARK: - Hold tracking

  /// Where the opening hold's finger was when the menu opened, in window coordinates. Movement
  /// from here decides whether the finger slid onto an action.
  func beginHold(at point: CGPoint) {
    holdStart = point
    isTrackingHold = false
  }

  /// The opening hold's finger moved, in window coordinates. Once it has really moved, the row
  /// under it highlights, unless the column scrolls (then the finger has to lift first).
  func trackHold(at point: CGPoint) {
    guard !isDismissing, plan?.isScrollable == false else { return }
    guard let start = holdStart else {
      holdStart = point
      return
    }
    if !isTrackingHold, hypot(point.x - start.x, point.y - start.y) > 8 {
      isTrackingHold = true
    }
    guard isTrackingHold else { return }
    let local = actionsView.convert(point, from: nil)
    actionsView.highlightRow(at: actionsView.bounds.contains(local) ? local : nil, feedback: true)
  }

  /// The opening hold's finger lifted: picks the row under it, if the finger slid onto one.
  func endHold(at point: CGPoint) {
    defer {
      holdStart = nil
      isTrackingHold = false
    }
    guard !isDismissing else { return }
    // A quick slide can lift before any move reached here; the lift position still counts.
    trackHold(at: point)
    guard isTrackingHold else { return }
    actionsView.selectHighlightedRow()
  }

  // MARK: - Selection

  private func selectionChanged() {
    guard let selectionView, !isDismissing else { return }
    let state = (hasSelection: selectionView.hasSelection, selectsAll: selectionView.selectsAllText)
    guard state != selectionState else { return }
    selectionState = state
    actionsView.setMenu(content.menu(state.hasSelection), leadingActions: selectionActions(), animated: true)
  }

  private func selectionActions() -> [UIAction] {
    guard let selectionView, selectionView.hasSelection else { return [] }
    var actions = [
      UIAction(title: "Copy", image: UIImage(systemName: "square.on.square")) { [weak self, weak selectionView] _ in
        guard let text = selectionView?.selectedText else { return }
        if let copy = self?.content.copySelection {
          copy(text)
        } else {
          UIPasteboard.general.string = text
        }
      },
    ]
    if !selectionView.selectsAllText {
      actions.append(UIAction(
        title: "Select All",
        image: UIImage(systemName: "selection.pin.in.out"),
        attributes: .keepsMenuPresented
      ) { [weak selectionView] _ in
        selectionView?.selectAll()
      })
    }
    return actions
  }
}

// MARK: - Views

private final class OverlayView: UIView {
  var onSizeChange: (() -> Void)?
  var onEscape: (() -> Bool)?
  private var laidOutSize: CGSize?

  override func layoutSubviews() {
    super.layoutSubviews()
    if let laidOutSize, laidOutSize != bounds.size {
      onSizeChange?()
    }
    laidOutSize = bounds.size
  }

  override func accessibilityPerformEscape() -> Bool {
    onEscape?() ?? false
  }
}

/// Leaves drags that start on a selection handle to the handle.
private final class MenuScrollView: UIScrollView {
  var blocksPan: ((CGPoint) -> Bool)?

  override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    if gestureRecognizer === panGestureRecognizer, blocksPan?(gestureRecognizer.location(in: self)) == true {
      return false
    }
    return super.gestureRecognizerShouldBegin(gestureRecognizer)
  }
}

/// Holds the preview and its selection; selection handles reach past its edges.
private final class PreviewHostView: UIView {
  weak var selectionView: MessageTextSelectionView?

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    if super.point(inside: point, with: event) { return true }
    guard let selectionView else { return false }
    return selectionView.isHandle(at: convert(point, to: selectionView))
  }
}
