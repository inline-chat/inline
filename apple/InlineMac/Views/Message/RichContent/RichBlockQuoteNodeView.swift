import AppKit

final class RichBlockQuoteNodeView: RichBlockRenderableView {
  private let iconView: NSImageView = {
    let view = NSImageView(frame: .zero)
    view.imageScaling = .scaleProportionallyDown
    view.image = NSImage(
      systemSymbolName: "quote.closing",
      accessibilityDescription: "Quote"
    )?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
    return view
  }()

  private var isRTL = false
  private var railColor = NSColor.separatorColor
  private var fillColor = NSColor.clear

  init() {
    super.init(reuseKind: .quote)
    wantsLayer = true
    layer?.cornerRadius = RichBlockQuoteMetrics.cornerRadius
    layer?.masksToBounds = true
    addSubview(iconView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func apply(node: RichBlockLayoutPlan.Node, context: RichBlockRenderContext) {
    guard case let .quote(quote) = node.kind else { return }
    isRTL = quote.isRTL
    railColor = context.palette.link.withAlphaComponent(0.72)
    fillColor = context.palette.subtleFill
    iconView.contentTintColor = context.palette.link.withAlphaComponent(0.72)
    needsDisplay = true
  }

  override func layout() {
    super.layout()
    let iconX = isRTL
      ? RichBlockQuoteMetrics.iconTrailingInset
      : max(
        RichBlockQuoteMetrics.iconTrailingInset,
        bounds.width - RichBlockQuoteMetrics.iconTrailingInset - RichBlockQuoteMetrics.iconSize
      )
    iconView.frame = CGRect(
      x: iconX,
      y: RichBlockQuoteMetrics.iconTopInset,
      width: RichBlockQuoteMetrics.iconSize,
      height: RichBlockQuoteMetrics.iconSize
    )
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let background = NSBezierPath(
      roundedRect: bounds,
      xRadius: RichBlockQuoteMetrics.cornerRadius,
      yRadius: RichBlockQuoteMetrics.cornerRadius
    )
    fillColor.setFill()
    background.fill()

    let railRect = CGRect(
      x: isRTL ? max(0, bounds.width - RichBlockQuoteMetrics.railWidth) : 0,
      y: 0,
      width: RichBlockQuoteMetrics.railWidth,
      height: bounds.height
    )
    railColor.setFill()
    NSBezierPath(
      roundedRect: railRect,
      xRadius: RichBlockQuoteMetrics.railWidth / 2,
      yRadius: RichBlockQuoteMetrics.railWidth / 2
    ).fill()
  }
}
