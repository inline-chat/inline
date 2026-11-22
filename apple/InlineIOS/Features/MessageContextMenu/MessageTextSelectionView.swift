import InlineMessageLayout
import UIKit

/// Text selection over a message preview, Telegram style: a long press selects the word under
/// the finger and dragging extends it; the handles move either end. A rich body's blocks select
/// as one run. It draws from the message's own layouts, so it lines up with a live view and a
/// bitmap alike.
///
/// While a finger extends the selection or moves a handle, the system loupe magnifies the text
/// under it, and a finger near the top or bottom of the menu scrolls a tall message.
final class MessageTextSelectionView: UIView, UIGestureRecognizerDelegate {
  struct Colors {
    var highlight: UIColor
    var handle: UIColor
  }

  /// How far from text a press still starts a selection.
  static let pressPadding: CGFloat = 12

  let surfaces: TextSelectionSurfaces
  var onSelectionChange: ((NSRange?) -> Void)?
  private(set) var selectedRange: NSRange?

  private let highlightLayer = CAShapeLayer()
  private let startHandle: SelectionHandleView
  private let endHandle: SelectionHandleView
  private lazy var longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
  private lazy var handlePan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
  private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
  /// The fixed end while a handle moves.
  private var anchor = 0
  /// The word a long press selected first.
  private var anchorWord: NSRange?
  private var draggedHandle: (isStart: Bool, offset: CGPoint)?
  private let feedback = UISelectionFeedbackGenerator()
  /// `UITextLoupeSession` (iOS 17), stored untyped for the iOS 15 build. No loupe before 17.
  private var loupe: AnyObject?
  private let autoscroll = SelectionAutoscroll()

  init(text: TextSelectionSurfaces, colors: Colors) {
    surfaces = text
    startHandle = SelectionHandleView(color: colors.handle, knobAtTop: true)
    endHandle = SelectionHandleView(color: colors.handle, knobAtTop: false)
    super.init(frame: .zero)
    backgroundColor = .clear
    // Opaque fill under a translucent layer, so overlapping line rects never draw darker.
    var alpha: CGFloat = 1
    colors.highlight.getRed(nil, green: nil, blue: nil, alpha: &alpha)
    highlightLayer.fillColor = colors.highlight.withAlphaComponent(1).cgColor
    highlightLayer.opacity = Float(alpha)
    layer.addSublayer(highlightLayer)
    for handle in [startHandle, endHandle] {
      handle.isHidden = true
      addSubview(handle)
    }
    longPress.minimumPressDuration = 0.3
    longPress.allowableMovement = 8
    for gesture in [longPress, handlePan, tap] as [UIGestureRecognizer] {
      gesture.delegate = self
      addGestureRecognizer(gesture)
    }
    autoscroll.onScroll = { [weak self] in self?.continueDrag() }
    isAccessibilityElement = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  var hasSelection: Bool { (selectedRange?.length ?? 0) > 0 }
  var selectsAllText: Bool { selectedRange == NSRange(location: 0, length: surfaces.length) }

  func selectAll() {
    setSelection(NSRange(location: 0, length: surfaces.length))
  }

  func clearSelection() {
    setSelection(nil)
  }

  #if DEBUG
  func selectForTesting(_ range: NSRange) {
    setSelection(surfaces.selectionRange(from: range.location, to: NSMaxRange(range)))
  }
  #endif

  /// True when `point` (in this view's coordinates) is on a handle, so the scroll view under
  /// the menu leaves the drag to the handle.
  func isHandle(at point: CGPoint) -> Bool {
    guard hasSelection else { return false }
    return [startHandle, endHandle].contains { !$0.isHidden && $0.touchFrame.contains(point) }
  }

  /// True when a press at `point` would start a selection.
  func isText(at point: CGPoint) -> Bool {
    surfaces.surface(at: point, padding: Self.pressPadding) != nil
  }

  // MARK: - Selection

  private func setSelection(_ range: NSRange?) {
    let range = range.flatMap { $0.length > 0 ? $0 : nil }
    guard range != selectedRange else { return }
    let appears = selectedRange == nil && range != nil
    if range != nil, selectedRange != nil {
      feedback.selectionChanged()
    }
    selectedRange = range
    updateSelectionViews(appearing: appears)
    onSelectionChange?(range)
  }

  private func updateSelectionViews(appearing: Bool = false) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    guard let range = selectedRange else {
      highlightLayer.path = nil
      startHandle.isHidden = true
      endHandle.isHidden = true
      return
    }
    let path = UIBezierPath()
    // Glyph segments, so mixed-direction lines highlight exactly the selected characters; small
    // gaps between lines are closed, so the selection reads as one shape.
    for rect in surfaces.highlightRects(for: range) {
      path.append(UIBezierPath(rect: rect))
    }
    highlightLayer.path = path.cgPath
    // A caret scrolled out of a code block or table has no handle.
    let start = surfaces.caretRect(at: range.location, affinity: .downstream)
    let end = surfaces.caretRect(at: NSMaxRange(range), affinity: .upstream)
    if let start { startHandle.caret = start }
    if let end { endHandle.caret = end }
    startHandle.isHidden = start == nil
    endHandle.isHidden = end == nil
    if appearing {
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 0
      fade.duration = 0.18
      highlightLayer.add(fade, forKey: "appear")
      for handle in [startHandle, endHandle] {
        handle.layer.add(fade, forKey: "appear")
      }
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    highlightLayer.frame = bounds
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    // Handles reach past the text; keep them touchable at the preview's edges.
    super.point(inside: point, with: event) || isHandle(at: point)
  }

  // MARK: - Gestures

  override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    let point = gestureRecognizer.location(in: self)
    switch gestureRecognizer {
    case handlePan:
      return isHandle(at: point)
    case tap:
      // Without a selection a tap falls through to the menu, which closes it.
      return hasSelection && !isHandle(at: point)
    case longPress:
      return isText(at: point)
    default:
      return true
    }
  }

  @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
    switch gesture.state {
    case .began:
      guard let word = surfaces.wordRange(at: gesture.location(in: self), padding: Self.pressPadding) else { return }
      anchorWord = word
      feedback.prepare()
      setSelection(word)
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      beginLoupe(at: gesture.location(in: self), widget: nil)
    case .changed:
      autoscroll.track(windowPoint: gesture.location(in: nil), in: self)
      continueDrag()
    default:
      anchorWord = nil
      endDrag()
    }
  }

  @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
    let point = gesture.location(in: self)
    switch gesture.state {
    case .began:
      guard let range = selectedRange else { return }
      let starts = !startHandle.isHidden && startHandle.touchFrame.contains(point)
      let ends = !endHandle.isHidden && endHandle.touchFrame.contains(point)
      let isStart = starts && (!ends || distance(point, startHandle.caret) <= distance(point, endHandle.caret))
      let caret = isStart ? startHandle.caret : endHandle.caret
      draggedHandle = (isStart, CGPoint(x: caret.midX - point.x, y: caret.midY - point.y))
      anchor = isStart ? NSMaxRange(range) : range.location
      feedback.prepare()
      beginLoupe(at: CGPoint(x: caret.midX, y: caret.midY), widget: isStart ? startHandle : endHandle)
    case .changed:
      autoscroll.track(windowPoint: gesture.location(in: nil), in: self)
      continueDrag()
    default:
      draggedHandle = nil
      endDrag()
    }
  }

  /// Applies the finger's place to the selection: after it moves, and after the menu scrolls
  /// under a finger held at its edge.
  private func continueDrag() {
    guard let windowPoint = autoscroll.windowPoint else { return }
    let point = convert(windowPoint, from: nil)
    if let word = anchorWord {
      // The first word stays selected; the selection grows from it toward the finger.
      let focus = surfaces.closestIndex(to: point)
      let selection = focus < word.location
        ? surfaces.selectionRange(from: NSMaxRange(word), to: focus)
        : surfaces.selectionRange(from: word.location, to: max(focus, NSMaxRange(word)))
      setSelection(selection)
      moveLoupe(to: point, caret: surfaces.caretRect(at: focus, affinity: focus < word.location ? .downstream : .upstream))
    } else if let handle = draggedHandle, let range = selectedRange {
      let target = CGPoint(x: point.x + handle.offset.x, y: point.y + handle.offset.y)
      var focus = surfaces.closestIndex(to: target)
      // An end never crosses the other; the selection keeps at least one character.
      if handle.isStart {
        focus = min(focus, NSMaxRange(range) - 1)
      } else {
        focus = max(focus, range.location + 1)
      }
      setSelection(surfaces.selectionRange(from: anchor, to: focus))
      let caret = handle.isStart ? startHandle.caret : endHandle.caret
      moveLoupe(to: CGPoint(x: caret.midX, y: caret.midY), caret: caret)
    }
  }

  private func endDrag() {
    autoscroll.stop()
    if #available(iOS 17.0, *) { (loupe as? UITextLoupeSession)?.invalidate() }
    loupe = nil
  }

  @objc private func handleTap() {
    clearSelection()
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    false
  }

  // MARK: - Loupe

  private func beginLoupe(at point: CGPoint, widget: UIView?) {
    guard #available(iOS 17.0, *) else { return }
    (loupe as? UITextLoupeSession)?.invalidate()
    loupe = UITextLoupeSession.begin(at: point, fromSelectionWidgetView: widget, in: self)
  }

  private func moveLoupe(to point: CGPoint, caret: CGRect?) {
    guard #available(iOS 17.0, *), let loupe = loupe as? UITextLoupeSession, let caret else { return }
    loupe.move(to: point, withCaretRect: caret, trackingCaret: true)
  }

  private func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
    hypot(point.x - rect.midX, point.y - rect.midY)
  }
}

/// Scrolls the scroll view holding a selection while a finger extending it rests near its top
/// or bottom edge, faster the closer it gets, as text views do.
@MainActor
private final class SelectionAutoscroll: NSObject {
  /// Runs after each scroll step, so the selection follows the content under the finger.
  var onScroll: (() -> Void)?
  /// The finger, in window coordinates.
  private(set) var windowPoint: CGPoint?
  private weak var scrollView: UIScrollView?
  private var link: CADisplayLink?
  private var lastTimestamp: CFTimeInterval?

  private static let edge: CGFloat = 72
  private static let maximumSpeed: CGFloat = 1_100

  func track(windowPoint: CGPoint, in view: UIView) {
    self.windowPoint = windowPoint
    if scrollView == nil {
      var candidate = view.superview
      while let current = candidate, !(current is UIScrollView) { candidate = current.superview }
      scrollView = candidate as? UIScrollView
    }
    if velocity() == 0 {
      stopLink()
    } else if link == nil {
      let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
      link.add(to: .main, forMode: .common)
      self.link = link
      lastTimestamp = nil
    }
  }

  func stop() {
    windowPoint = nil
    stopLink()
  }

  private func stopLink() {
    link?.invalidate()
    link = nil
    lastTimestamp = nil
  }

  /// Points per second: negative scrolls toward the top.
  private func velocity() -> CGFloat {
    guard let scrollView, let window = scrollView.window, let windowPoint else { return 0 }
    let inset = scrollView.adjustedContentInset
    guard scrollView.contentSize.height + inset.top + inset.bottom > scrollView.bounds.height + 1 else { return 0 }
    let visible = scrollView.convert(scrollView.bounds, to: nil)
      .inset(by: UIEdgeInsets(top: window.safeAreaInsets.top, left: 0, bottom: window.safeAreaInsets.bottom, right: 0))
    let offset = scrollView.contentOffset.y
    let top = -inset.top
    let bottom = max(top, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
    if windowPoint.y < visible.minY + Self.edge, offset > top + 0.5 {
      let depth = min(1, (visible.minY + Self.edge - windowPoint.y) / Self.edge)
      return -Self.maximumSpeed * depth * depth
    }
    if windowPoint.y > visible.maxY - Self.edge, offset < bottom - 0.5 {
      let depth = min(1, (windowPoint.y - (visible.maxY - Self.edge)) / Self.edge)
      return Self.maximumSpeed * depth * depth
    }
    return 0
  }

  @objc private func tick(_ link: CADisplayLink) {
    guard let scrollView else { return stopLink() }
    let speed = velocity()
    guard speed != 0 else { return stopLink() }
    let elapsed = lastTimestamp.map { min(link.timestamp - $0, 1.0 / 30) } ?? link.duration
    lastTimestamp = link.timestamp
    let inset = scrollView.adjustedContentInset
    let top = -inset.top
    let bottom = max(top, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
    let target = min(max(scrollView.contentOffset.y + speed * CGFloat(elapsed), top), bottom)
    guard target != scrollView.contentOffset.y else { return stopLink() }
    scrollView.contentOffset.y = target
    onScroll?()
  }
}

/// An iOS-style selection handle: a thin bar along the caret with a round knob at one end.
private final class SelectionHandleView: UIView {
  private static let barWidth: CGFloat = 2
  private static let knobDiameter: CGFloat = 10
  private static let touchSize: CGFloat = 44

  private let bar = UIView()
  private let knob = UIView()
  private let knobAtTop: Bool

  /// The caret this handle sits on, in the superview's coordinates.
  var caret: CGRect = .zero {
    didSet {
      let knob = Self.knobDiameter
      frame = CGRect(
        x: caret.midX - knob / 2,
        y: knobAtTop ? caret.minY - knob : caret.minY,
        width: knob,
        height: caret.height + knob
      )
      setNeedsLayout()
    }
  }

  /// Where a touch grabs the handle: at least 44 points around its bar and knob.
  var touchFrame: CGRect {
    let visual = frame
    let dx = max(0, (Self.touchSize - visual.width) / 2)
    let dy = max(0, (Self.touchSize - visual.height) / 2)
    return visual.insetBy(dx: -dx, dy: -dy)
  }

  init(color: UIColor, knobAtTop: Bool) {
    self.knobAtTop = knobAtTop
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    bar.backgroundColor = color
    knob.backgroundColor = color
    knob.layer.cornerRadius = Self.knobDiameter / 2
    addSubview(bar)
    addSubview(knob)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let knob = Self.knobDiameter
    let height = bounds.height
    bar.frame = CGRect(x: (knob - Self.barWidth) / 2, y: knobAtTop ? knob / 2 : 0, width: Self.barWidth, height: caret.height + knob / 2)
    self.knob.frame = CGRect(x: 0, y: knobAtTop ? 0 : height - knob, width: knob, height: knob)
  }
}
