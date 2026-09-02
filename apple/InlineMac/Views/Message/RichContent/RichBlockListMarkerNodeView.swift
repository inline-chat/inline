import AppKit

final class RichBlockListMarkerNodeView: RichBlockRenderableView {
  private var marker = ""
  private var isRTL = false
  private var color = NSColor.labelColor
  private var font = NSFont.systemFont(ofSize: 15)
  private(set) var selectionSource = NSAttributedString()

  init() {
    super.init(reuseKind: .listMarker)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func apply(node: RichBlockLayoutPlan.Node, context: RichBlockRenderContext) {
    guard case let .text(text) = node.kind,
          case .listMarker = text.role,
          let marker = text.literal
    else { return }
    self.marker = marker
    isRTL = text.isRTL
    color = context.palette.primary
    font = ChatTypography.current.font(sized: context.baseFontSize)
    selectionSource = NSAttributedString(
      string: marker,
      attributes: [.font: font, .foregroundColor: color]
    )
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    if marker == "•" {
      let diameter = RichBlockListMetrics.unorderedDiameter(baseFontSize: font.pointSize)
      let lineHeight = ceil(font.ascender - font.descender + font.leading)
      let markerX = isRTL
        ? RichBlockListMetrics.markerContentGap
        : bounds.width - RichBlockListMetrics.markerContentGap - diameter
      let rect = CGRect(
        x: floor(markerX),
        y: floor((min(bounds.height, lineHeight) - diameter) / 2) + 1,
        width: diameter,
        height: diameter
      )
      color.setFill()
      NSBezierPath(ovalIn: rect).fill()
      return
    }

    if marker == "☐" || marker == "☑" {
      let side = min(12, max(9, font.pointSize * 0.72))
      let markerX = isRTL
        ? RichBlockListMetrics.markerContentGap
        : bounds.width - RichBlockListMetrics.markerContentGap - side
      let rect = CGRect(
        x: floor(markerX) + 0.5,
        y: floor((min(bounds.height, font.pointSize * 1.25) - side) / 2) + 1.5,
        width: side,
        height: side
      )
      let box = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
      box.lineWidth = 1.25
      color.withAlphaComponent(0.72).setStroke()
      box.stroke()
      if marker == "☑" {
        let check = NSBezierPath()
        check.lineWidth = 1.55
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        check.move(to: CGPoint(x: rect.minX + side * 0.22, y: rect.midY))
        check.line(to: CGPoint(x: rect.minX + side * 0.43, y: rect.maxY - side * 0.25))
        check.line(to: CGPoint(x: rect.maxX - side * 0.18, y: rect.minY + side * 0.24))
        color.setStroke()
        check.stroke()
      }
      return
    }

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = isRTL ? .left : .right
    paragraph.baseWritingDirection = isRTL ? .rightToLeft : .leftToRight
    let markerRect = isRTL
      ? CGRect(
        x: RichBlockListMetrics.markerContentGap,
        y: 0,
        width: max(0, bounds.width - RichBlockListMetrics.markerContentGap),
        height: bounds.height
      )
      : CGRect(
        x: 0,
        y: 0,
        width: max(0, bounds.width - RichBlockListMetrics.markerContentGap),
        height: bounds.height
      )
    (marker as NSString).draw(
      in: markerRect,
      withAttributes: [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph,
      ]
    )
  }
}
