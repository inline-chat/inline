import InlineMessageLayout
import UIKit

/// Text selection over a message preview, Telegram style: a long press selects the word under
/// the finger and dragging extends it; the handles move either end. It draws from the message's
/// own `TextLayout`, so it lines up with a live view and a bitmap alike.
final class MessageTextSelectionView: UIView, UIGestureRecognizerDelegate {
  struct Colors {
    var highlight: UIColor
    var handle: UIColor
  }

  let layout: TextLayout
  /// The text block's frame in this view's coordinates.
  let textFrame: CGRect
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

  init(layout: TextLayout, textFrame: CGRect, colors: Colors) {
    self.layout = layout
    self.textFrame = textFrame
    startHandle = SelectionHandleView(color: colors.handle, knobAtTop: true)
    endHandle = SelectionHandleView(color: colors.handle, knobAtTop: false)
    super.init(frame: .zero)
    backgroundColor = .clear
    highlightLayer.fillColor = colors.highlight.cgColor
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
    isAccessibilityElement = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  var hasSelection: Bool { (selectedRange?.length ?? 0) > 0 }
  var selectsAllText: Bool { selectedRange == NSRange(location: 0, length: layout.length) }
  var selectedText: String? { selectedRange.map { layout.string(in: $0) } }

  func selectAll() {
    setSelection(NSRange(location: 0, length: layout.length))
  }

  func clearSelection() {
    setSelection(nil)
  }

  /// True when `point` (in this view's coordinates) is on a handle, so the scroll view under
  /// the menu leaves the drag to the handle.
  func isHandle(at point: CGPoint) -> Bool {
    guard hasSelection else { return false }
    return [startHandle, endHandle].contains { $0.touchFrame.contains(point) }
  }

  // MARK: - Geometry

  private func textPoint(_ point: CGPoint) -> CGPoint {
    CGPoint(x: point.x - textFrame.minX, y: point.y - textFrame.minY)
  }

  private func viewRect(_ rect: CGRect) -> CGRect {
    rect.offsetBy(dx: textFrame.minX, dy: textFrame.minY)
  }

  private func setSelection(_ range: NSRange?) {
    let range = range.flatMap { $0.length > 0 ? $0 : nil }
    guard range != selectedRange else { return }
    if range != nil, selectedRange != nil {
      feedback.selectionChanged()
    }
    selectedRange = range
    updateSelectionViews()
    onSelectionChange?(range)
  }

  private func updateSelectionViews() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    guard let range = selectedRange,
          let start = layout.caretRect(at: range.location, affinity: .downstream),
          let end = layout.caretRect(at: NSMaxRange(range), affinity: .upstream)
    else {
      highlightLayer.path = nil
      startHandle.isHidden = true
      endHandle.isHidden = true
      return
    }
    let path = UIBezierPath()
    // Glyph segments, so mixed-direction lines highlight exactly the selected characters.
    for rect in layout.rects(for: range) {
      path.append(UIBezierPath(roundedRect: viewRect(rect), cornerRadius: 2))
    }
    highlightLayer.path = path.cgPath
    startHandle.caret = viewRect(start)
    endHandle.caret = viewRect(end)
    startHandle.isHidden = false
    endHandle.isHidden = false
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
      return textFrame.insetBy(dx: -8, dy: -8).contains(point)
    default:
      return true
    }
  }

  @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
    let point = textPoint(gesture.location(in: self))
    switch gesture.state {
    case .began:
      let word = layout.wordRange(at: point)
      anchorWord = word
      feedback.prepare()
      setSelection(word)
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    case .changed:
      guard let word = anchorWord else { return }
      // The first word stays selected; the selection grows from it toward the finger.
      let focus = layout.closestCaretIndex(to: point)
      let selection = focus < word.location
        ? layout.selectionRange(from: NSMaxRange(word), to: focus)
        : layout.selectionRange(from: word.location, to: max(focus, NSMaxRange(word)))
      setSelection(selection)
    default:
      anchorWord = nil
    }
  }

  @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
    let point = gesture.location(in: self)
    switch gesture.state {
    case .began:
      guard let range = selectedRange else { return }
      let isStart = startHandle.touchFrame.contains(point)
        && (!endHandle.touchFrame.contains(point)
          || distance(point, startHandle.caret) <= distance(point, endHandle.caret))
      let caret = isStart ? startHandle.caret : endHandle.caret
      draggedHandle = (isStart, CGPoint(x: caret.midX - point.x, y: caret.midY - point.y))
      anchor = isStart ? NSMaxRange(range) : range.location
      feedback.prepare()
    case .changed:
      guard let handle = draggedHandle, let range = selectedRange else { return }
      let target = textPoint(CGPoint(x: point.x + handle.offset.x, y: point.y + handle.offset.y))
      var focus = layout.closestCaretIndex(to: target)
      // An end never crosses the other; the selection keeps at least one character.
      if handle.isStart {
        focus = min(focus, NSMaxRange(range) - 1)
      } else {
        focus = max(focus, range.location + 1)
      }
      setSelection(layout.selectionRange(from: anchor, to: focus))
    default:
      draggedHandle = nil
    }
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

  private func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
    hypot(point.x - rect.midX, point.y - rect.midY)
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
