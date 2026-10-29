import InlineMessageLayout
import UIKit

/// Inline's own message context menu, after Telegram iOS's context controller.
///
/// The bubble lifts out of the chat into an overlay: a blur and dim, then one scrolling column
/// with the bubble and the actions, and the reaction bar pinned on screen above it. A bubble
/// taller than the screen scrolls with its menu, opening at the bottom so the actions show,
/// while the reaction bar stays below the top inset over the message. The preview can be a live
/// message view, and its text can be selected.
///
/// With the keyboard up, the overlay goes inside the keyboard's own window (`KeyboardHostWindow`),
/// so the blur and menu cover the keyboard and the composer keeps focus, as in Telegram.
/// Otherwise it gets a window of its own, one level above the scene's windows; that window never
/// becomes key, so the chat's first responder stays the host's.
@MainActor
final class MessageContextMenuController: NSObject, UIGestureRecognizerDelegate, UIScrollViewDelegate {
  struct Source {
    /// Draws the bubble: a live message view or a bitmap, sized to `frame`.
    var preview: UIView
    /// The bubble's frame in the source window's coordinates, without the press shrink.
    var frame: CGRect
    /// The press shrink on the source as the menu opens; the preview grows from it.
    var pressedScale: CGFloat = 1
    var alignment: ContextMenuLayout.Alignment
    var selectableText: SelectableText?
    /// The bubble's frame now, in the source window's coordinates, for the flight back; nil once
    /// it's gone.
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
  /// The menu's own window, when it has one rather than sharing the keyboard's.
  private(set) var presentationWindow: UIWindow?
  /// The menu draws inside the keyboard's window, over the keyboard.
  var isOverKeyboard: Bool { hostWindow != nil && hostWindow !== presentationWindow }

  private let source: Source
  private let content: Content
  private let configuration: MessageContextMenuConfiguration
  private weak var sourceWindow: UIWindow?
  /// The window the overlay is in: the keyboard's or the menu's own.
  private weak var hostWindow: UIWindow?
  private var keyboardObserver: NSObjectProtocol?

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
  private var isAccessoryOverContent = false
  private var selectionState: (hasSelection: Bool, selectsAll: Bool) = (false, false)
  private var holdStart: CGPoint?
  private var isTrackingHold = false
  private var pendingActions: [() -> Void] = []

  init(source: Source, content: Content, configuration: MessageContextMenuConfiguration = .standard) {
    self.source = source
    self.content = content
    self.configuration = configuration
    actionsView = MessageContextMenuActionsView(menu: content.menu(false), style: configuration.style)
    actionsView.motion = configuration.motion
    super.init()
  }

  // MARK: - Presenting

  /// Shows the menu over `sourceWindow`'s scene. With `keyboardWindow`, the window hosting a
  /// visible keyboard, the menu draws inside it, over the keyboard.
  func present(from sourceWindow: UIWindow, overKeyboardIn keyboardWindow: UIWindow? = nil) {
    guard let scene = sourceWindow.windowScene else { return }
    self.sourceWindow = sourceWindow
    let host: UIView
    if let keyboardWindow {
      hostWindow = keyboardWindow
      host = keyboardWindow
      // The keyboard's window can go away under the menu, as when the app moves to the
      // background; the menu then moves to a window of its own.
      keyboardObserver = NotificationCenter.default.addObserver(
        forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { _ = self?.moveToOwnWindow() }
      }
    } else {
      host = makeOwnWindow(in: scene)
    }

    overlay.frame = host.bounds
    overlay.overrideUserInterfaceStyle = sourceWindow.traitCollection.userInterfaceStyle
    overlay.tintColor = sourceWindow.tintColor
    overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    overlay.accessibilityViewIsModal = true
    overlay.onEscape = { [weak self] in
      self?.dismiss()
      return true
    }
    overlay.onSizeChange = { [weak self] in
      self?.dismiss(animated: false)
    }
    host.addSubview(overlay)

    blurView.frame = overlay.bounds
    blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    dimView.frame = overlay.bounds
    dimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    dimView.backgroundColor = configuration.dimColor
    dimView.alpha = 0
    dimView.isUserInteractionEnabled = false
    overlay.addSubview(blurView)
    overlay.addSubview(dimView)

    scrollView.frame = overlay.bounds
    scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.showsVerticalScrollIndicator = false
    scrollView.delaysContentTouches = false
    scrollView.canCancelContentTouches = true
    scrollView.delegate = self
    scrollView.blocksPan = { [weak self] point in
      guard let self, let selectionView else { return false }
      return selectionView.isHandle(at: scrollView.convert(point, to: selectionView))
    }
    overlay.addSubview(scrollView)
    // The same screen as the source, whose safe area is already known.
    let safe = sourceWindow.safeAreaInsets
    safeInsets = ContextMenuLayout.Insets(top: safe.top, left: safe.left, bottom: safe.bottom, right: safe.right)

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

    actionsView.onSelect = { [weak self] row in self?.select(row) }
    actionsView.onLayoutChange = { [weak self] in self?.layOutForNewMenuSize() }
    actionsView.prepareFeedback()
    scrollView.addSubview(actionsView)

    // Over the column, so it stays on screen while the column scrolls.
    if let accessory = content.accessory {
      accessory.translatesAutoresizingMaskIntoConstraints = false
      accessoryHost.addSubview(accessory)
      NSLayoutConstraint.activate([
        accessory.centerXAnchor.constraint(equalTo: accessoryHost.centerXAnchor),
        accessory.centerYAnchor.constraint(equalTo: accessoryHost.centerYAnchor),
      ])
      accessoryHost.layer.shadowColor = UIColor.black.cgColor
      accessoryHost.layer.shadowRadius = 16
      accessoryHost.layer.shadowOffset = CGSize(width: 0, height: 4)
      accessoryHost.layer.shadowOpacity = 0
      overlay.addSubview(accessoryHost)
    }

    let tap = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap))
    tap.delegate = self
    scrollView.addGestureRecognizer(tap)

    let sourceFrame = viewportRect(fromSource: source.frame)
    let plan = makePlan(sourceInViewport: sourceFrame)
    apply(plan, updatesOffset: true)
    source.setHidden(true)
    animateIn(plan, from: sourceFrame)

    UIAccessibility.post(notification: .screenChanged, argument: actionsView.firstRow)
  }

  /// A window of the menu's own, one level above the scene's windows and never key. Returns
  /// the view the overlay goes in.
  private func makeOwnWindow(in scene: UIWindowScene) -> UIView {
    let window = MessageContextMenuWindow(windowScene: scene)
    let topLevel = scene.windows.filter { !$0.isHidden }.map(\.windowLevel.rawValue).max() ?? 0
    window.windowLevel = UIWindow.Level(rawValue: max(topLevel, sourceWindow?.windowLevel.rawValue ?? 0) + 1)
    window.backgroundColor = .clear
    let root = UIViewController()
    root.view.backgroundColor = .clear
    window.rootViewController = root
    window.frame = sourceWindow?.frame ?? window.frame
    // Shown before the content goes in, so the root view has its final size for the layout.
    window.isHidden = false
    root.view.frame = window.bounds
    presentationWindow = window
    hostWindow = window
    return root.view
  }

  /// Moves the menu out of the keyboard's window into one of its own, and returns that window.
  /// Anything presented over the open menu, like the emoji picker, goes in a window above it: a
  /// sheet can't show over the keyboard's window.
  func moveToOwnWindow() -> UIWindow? {
    if let presentationWindow { return presentationWindow }
    guard !isDismissing, overlay.superview != nil, let scene = sourceWindow?.windowScene else { return nil }
    removeKeyboardObserver()
    let host = makeOwnWindow(in: scene)
    UIView.performWithoutAnimation {
      overlay.frame = host.bounds
      host.addSubview(overlay)
    }
    return presentationWindow
  }

  private func removeKeyboardObserver() {
    if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) }
    keyboardObserver = nil
  }

  /// `rect` in the source window's coordinates, in the menu's viewport.
  private func viewportRect(fromSource rect: CGRect) -> CGRect {
    guard let hostWindow, let sourceWindow else { return rect }
    return overlay.convert(hostWindow.convert(rect, from: sourceWindow), from: hostWindow)
  }

  private var availableWidth: CGFloat {
    max(0, overlay.bounds.width - safeInsets.left - safeInsets.right - configuration.layoutMetrics.sideInset * 2)
  }

  private func makePlan(sourceInViewport: CGRect) -> ContextMenuLayout.Result {
    let menuSize = actionsView.sizeThatFits(CGSize(width: availableWidth, height: .greatestFiniteMagnitude))
    let accessorySize = content.accessory.map { $0.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize) }
    let scale = sourceWindow?.screen.scale ?? 3
    return ContextMenuLayout.plan(ContextMenuLayout.Input(
      viewport: overlay.bounds.size,
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
    accessoryHost.layer.anchorPoint = CGPoint(x: plan.menuAnchor.x, y: 1)
    layOutAccessory(animated: false)
  }

  /// Keeps the reaction bar on screen as the column scrolls, with a shadow while the message
  /// is under it.
  private func layOutAccessory(animated: Bool) {
    guard accessoryHost.superview != nil,
          let pinned = plan?.pinnedAccessory(atContentOffsetY: scrollView.contentOffset.y)
    else { return }
    accessoryHost.untransformedFrame = pinned.frame
    guard pinned.isOverContent != isAccessoryOverContent else { return }
    isAccessoryOverContent = pinned.isOverContent
    let opacity: Float = pinned.isOverContent ? 0.18 : 0
    if animated {
      let animation = CABasicAnimation(keyPath: "shadowOpacity")
      animation.fromValue = accessoryHost.layer.presentation()?.shadowOpacity ?? accessoryHost.layer.shadowOpacity
      animation.toValue = opacity
      animation.duration = 0.25
      accessoryHost.layer.add(animation, forKey: "shadowOpacity")
    }
    accessoryHost.layer.shadowOpacity = opacity
  }

  private func animateIn(_ plan: ContextMenuLayout.Result, from sourceFrame: CGRect) {
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
    let start = plan.contentRect(fromViewport: sourceFrame)
    let delta = CGPoint(x: start.midX - plan.preview.midX, y: start.midY - plan.preview.midY)
    let offset = NSValue(cgPoint: delta)
    let zero = NSValue(cgPoint: .zero)
    previewHost.layer.addContextMenuSpring("position", from: offset, to: zero, additive: true, motion: motion)
    if source.pressedScale < 1 {
      previewHost.layer.addContextMenuSpring(
        "transform.scale", from: source.pressedScale, to: 1.0, additive: false, motion: motion
      )
    }

    actionsView.alpha = 0
    UIView.animate(withDuration: 0.08, delay: 0, options: [.allowUserInteraction]) { self.actionsView.alpha = 1 }
    actionsView.layer.addContextMenuSpring("transform.scale", from: 0.01, to: 1.0, additive: false, motion: motion)
    actionsView.layer.addContextMenuSpring("position", from: offset, to: zero, additive: true, motion: motion)

    if accessoryHost.superview != nil {
      accessoryHost.alpha = 0
      UIView.animate(withDuration: 0.08, delay: 0, options: [.allowUserInteraction]) { self.accessoryHost.alpha = 1 }
      accessoryHost.layer.addContextMenuSpring("transform.scale", from: 0.2, to: 1.0, additive: false, motion: motion)
      // A pinned bar grows in place; one above the bubble rides with it.
      if !isAccessoryOverContent {
        accessoryHost.layer.addContextMenuSpring("position", from: offset, to: zero, additive: true, motion: motion)
      }
    }
  }

  /// Lays the column out for the menu's new size, keeping the bubble where it is unless the
  /// menu no longer fits under it. Runs inside the menu's own animation.
  private func layOutForNewMenuSize() {
    guard !isDismissing, plan != nil else { return }
    let current = previewHost.untransformedFrame.offsetBy(dx: 0, dy: -scrollView.contentOffset.y)
    apply(makePlan(sourceInViewport: current), updatesOffset: true)
  }

  // MARK: - Dismissing

  /// Closes the menu, flying the bubble back to the chat, then runs `action`.
  func dismiss(animated: Bool = true, then action: (() -> Void)? = nil) {
    if let action { pendingActions.append(action) }
    guard !isDismissing else { return }
    isDismissing = true
    removeKeyboardObserver()
    overlay.isUserInteractionEnabled = false
    onWillDismiss?()

    let finish = { [self] in
      source.setHidden(false)
      overlay.removeFromSuperview()
      presentationWindow?.isHidden = true
      presentationWindow?.rootViewController = nil
      presentationWindow = nil
      // Actions first, as UIKit's menu does: one that presents a sheet takes focus before the
      // host would give it back to the composer.
      let actions = pendingActions
      pendingActions.removeAll()
      actions.forEach { $0() }
      onDidDismiss?()
    }
    guard animated, overlay.window?.isHidden == false else {
      finish()
      return
    }

    for view in [previewHost, actionsView, accessoryHost] {
      view.layer.freezeContextMenuAnimations()
    }
    let target = UIAccessibility.isReduceMotionEnabled
      ? nil
      : source.currentFrame().map { scrollView.convert(viewportRect(fromSource: $0), from: overlay) }
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
    // With a selection, a tap on the bubble clears it instead of closing the menu.
    if previewHost.frame.contains(point), selectionView?.hasSelection == true { return false }
    return true
  }

  // MARK: - Scrolling

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    layOutAccessory(animated: true)
  }

  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    actionsView.cancelTracking()
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

  /// Where the opening hold's finger was when the menu opened, in the source window's
  /// coordinates. Movement from here decides whether the finger slid onto an action.
  func beginHold(at point: CGPoint) {
    holdStart = point
    isTrackingHold = false
  }

  /// The opening hold's finger moved, in the source window's coordinates. Once it has really
  /// moved, the row under it highlights, unless the column scrolls (then the finger has to lift
  /// first).
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
    let local = actionsView.convert(viewportRect(fromSource: CGRect(origin: point, size: .zero)).origin, from: overlay)
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

  #if DEBUG
  /// Drives the menu from device tests.
  var actionsViewForTesting: MessageContextMenuActionsView { actionsView }
  var selectionViewForTesting: MessageTextSelectionView? { selectionView }
  var scrollViewForTesting: UIScrollView { scrollView }
  var accessoryHostForTesting: UIView { accessoryHost }
  #endif
}

// MARK: - Views

/// The menu's window. It never becomes key, so the first responder under it stays the host's.
private final class MessageContextMenuWindow: UIWindow {
  override var canBecomeKey: Bool { false }
}

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
