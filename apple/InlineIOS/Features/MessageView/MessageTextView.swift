import CoreText
import InlineMessageLayout
import UIKit

/// Draws a prepared `TextLayout` with Core Text. It never measures: its frame comes from the
/// plan, and the same layout answers hit tests.
final class MessageTextView: UIView {
  /// Minimum room around the line boxes on every side.
  static let minimumBleed: CGFloat = 4

  private(set) var layout: TextLayout = .empty
  /// Characters drawn while a message streams; nil draws everything. The newest characters
  /// fade in over `revealFadeWidth`.
  var revealedLength: Int? {
    didSet { if revealedLength != oldValue { setNeedsDisplay() } }
  }

  static let revealFadeWidth: CGFloat = 24
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

  private func draw(_ line: TextLayout.Line, in context: CGContext) {
    context.saveGState()
    context.translateBy(x: line.frame.minX, y: line.baseline)
    context.scaleBy(x: 1, y: -1)
    context.textPosition = .zero
    CTLineDraw(line.ctLine, context)
    context.restoreGState()
  }

  /// The line holding the reveal frontier: solid up to just before it, then a short fade.
  private func drawFrontier(_ line: TextLayout.Line, revealed: Int, in context: CGContext) {
    let offset = CTLineGetOffsetForStringIndex(line.ctLine, revealed, nil)
    let fade = Self.revealFadeWidth
    let top = line.frame.minY - bleed.top
    let height = line.frame.height + bleed.top + bleed.bottom
    let isRightToLeft = line.direction == .rightToLeft
    // Text coordinates of the frontier; right-to-left lines reveal leftward.
    let edge = line.frame.minX + offset
    let solid = isRightToLeft
      ? CGRect(x: edge + fade, y: top, width: max(0, line.frame.maxX + bleed.right - edge - fade), height: height)
      : CGRect(x: line.frame.minX - bleed.left, y: top, width: max(0, edge - fade - line.frame.minX + bleed.left), height: height)
    if solid.width > 0 {
      context.saveGState()
      context.clip(to: solid)
      draw(line, in: context)
      context.restoreGState()
    }
    let ramp = CGRect(x: isRightToLeft ? edge : edge - fade, y: top, width: fade, height: height)
    if let mask = isRightToLeft ? Self.risingMask : Self.fallingMask {
      context.saveGState()
      context.clip(to: ramp, mask: mask)
      draw(line, in: context)
      context.restoreGState()
    }
  }

  /// One-pixel-tall gray ramps for `clip(to:mask:)`: white shows, black hides.
  private static let fallingMask = ramp(from: 255, to: 0)
  private static let risingMask = ramp(from: 0, to: 255)

  private static func ramp(from start: UInt8, to end: UInt8) -> CGImage? {
    let width = 32
    let pixels = (0 ..< width).map { index in
      UInt8(Double(start) + (Double(end) - Double(start)) * Double(index) / Double(width - 1))
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    return CGImage(
      width: width,
      height: 1,
      bitsPerComponent: 8,
      bitsPerPixel: 8,
      bytesPerRow: width,
      space: CGColorSpaceCreateDeviceGray(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: true,
      intent: .defaultIntent
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
      if let revealed = revealedLength {
        if line.range.location >= revealed { continue }
        if NSMaxRange(line.range) > revealed {
          drawFrontier(line, revealed: revealed, in: context)
          continue
        }
      }
      draw(line, in: context)
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
