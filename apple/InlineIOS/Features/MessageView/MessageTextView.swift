import CoreText
import InlineMessageLayout
import UIKit

/// Draws a prepared `TextLayout` with Core Text. It never measures: its frame comes from the
/// plan, and the same layout answers hit tests.
final class MessageTextView: UIView {
  /// Minimum room around the line boxes on every side.
  static let minimumBleed: CGFloat = 4

  private(set) var layout: TextLayout = .empty
  /// Room around the line boxes for ink that overhangs them: italics, tall emoji, stacked
  /// marks. Sized from the layout's glyph bounds, never less than `minimumBleed`.
  private(set) var bleed = UIEdgeInsets(top: minimumBleed, left: minimumBleed, bottom: minimumBleed, right: minimumBleed)

  /// Places the view so its text occupies `textFrame` in the superview's coordinates.
  var textFrame: CGRect {
    get { frame.inset(by: bleed) }
    set { frame = newValue.inset(by: UIEdgeInsets(top: -bleed.top, left: -bleed.left, bottom: -bleed.bottom, right: -bleed.right)) }
  }

  /// Converts a rect in text coordinates to this view's coordinates.
  func viewRect(forTextRect rect: CGRect) -> CGRect {
    rect.offsetBy(dx: bleed.left, dy: bleed.top)
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    backgroundColor = .clear
    // Frames animate while the drawn content stays at its final size, anchored at the top.
    contentMode = .topLeft
    isUserInteractionEnabled = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setLayout(_ layout: TextLayout) {
    guard !layout.drawsIdentically(to: self.layout) else { return }
    let textFrame = self.textFrame
    self.layout = layout
    bleed = Self.bleed(for: layout)
    self.textFrame = textFrame
    setNeedsDisplay()
  }

  private static func bleed(for layout: TextLayout) -> UIEdgeInsets {
    let ink = layout.inkBounds
    guard !ink.isNull else {
      return UIEdgeInsets(top: minimumBleed, left: minimumBleed, bottom: minimumBleed, right: minimumBleed)
    }
    func room(_ overhang: CGFloat) -> CGFloat { max(minimumBleed, ceil(overhang) + 1) }
    return UIEdgeInsets(
      top: room(-ink.minY),
      left: room(-ink.minX),
      bottom: room(ink.maxY - layout.size.height),
      right: room(ink.maxX - layout.size.width)
    )
  }

  /// Character under a point in this view's coordinates.
  func characterIndex(at point: CGPoint) -> Int? {
    layout.characterIndex(at: CGPoint(x: point.x - bleed.left, y: point.y - bleed.top))
  }

  override func draw(_ rect: CGRect) {
    guard let context = UIGraphicsGetCurrentContext(), layout.lineCount > 0 else { return }
    context.translateBy(x: bleed.left, y: bleed.top)
    let rect = rect.offsetBy(dx: -bleed.left, dy: -bleed.top)
    let attributed = layout.text.attributedString
    let fullRange = NSRange(location: 0, length: attributed.length)

    attributed.enumerateAttribute(.backgroundColor, in: fullRange) { value, range, _ in
      guard let color = value as? UIColor else { return }
      color.setFill()
      for box in layout.rects(for: range) where box.intersects(rect) {
        UIBezierPath(roundedRect: box.insetBy(dx: -1, dy: 0), cornerRadius: 3).fill()
      }
    }

    context.saveGState()
    context.textMatrix = .identity
    for line in layout.lines where line.frame.intersects(rect) {
      context.saveGState()
      context.translateBy(x: line.frame.minX, y: line.baseline)
      context.scaleBy(x: 1, y: -1)
      context.textPosition = .zero
      CTLineDraw(line.ctLine, context)
      context.restoreGState()
    }
    context.restoreGState()

    // Core Text draws underlines but not strikethrough.
    attributed.enumerateAttribute(.strikethroughStyle, in: fullRange) { value, range, _ in
      guard let style = value as? Int, style != 0 else { return }
      let color = attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor
      let font = attributed.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont
      let thickness = max(1 / max(traitCollection.displayScale, 1), font.map { $0.pointSize / 17 } ?? 1)
      (color ?? .label).setFill()
      for line in layout.lines where NSIntersectionRange(line.range, range).length > 0 {
        let midline = line.baseline - (font?.xHeight ?? line.ascent * 0.45) / 2
        for box in layout.rects(for: NSIntersectionRange(line.range, range)) {
          context.fill(CGRect(x: box.minX, y: midline - thickness / 2, width: box.width, height: thickness))
        }
      }
    }
  }
}

extension NSAttributedString {
  /// Adds Core Text's own color keys so `CTLineDraw` paints UIKit colors, resolved for `traits`.
  func coreTextReady(for traits: UITraitCollection) -> NSAttributedString {
    let result = NSMutableAttributedString(attributedString: self)
    let fullRange = NSRange(location: 0, length: length)
    let foreground = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
    result.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
      let color = (value as? UIColor) ?? .label
      result.addAttribute(foreground, value: color.resolvedColor(with: traits).cgColor, range: range)
    }
    let underlineColor = NSAttributedString.Key(kCTUnderlineColorAttributeName as String)
    result.enumerateAttribute(.underlineColor, in: fullRange) { value, range, _ in
      guard let color = value as? UIColor else { return }
      result.addAttribute(underlineColor, value: color.resolvedColor(with: traits).cgColor, range: range)
    }
    return result
  }
}
