import AppKit

final class RichBlockTableNodeView: RichBlockRenderableView {
  private static let horizontalPadding: CGFloat = 10
  private static let verticalPadding: CGFloat = 7

  private let canvasView = RichBlockTableCanvasView(frame: .zero)
  private lazy var scrollView: RichBlockHorizontalScrollView = {
    let view = RichBlockHorizontalScrollView()
    view.borderType = .noBorder
    view.drawsBackground = false
    view.hasHorizontalScroller = false
    view.hasVerticalScroller = false
    view.autohidesScrollers = true
    view.horizontalScrollElasticity = .automatic
    view.verticalScrollElasticity = .none
    view.documentView = canvasView
    return view
  }()

  private var cellViews: [Int: RichBlockTextSurface] = [:]
  private var cells: [RichBlockLayoutPlan.TableNode.Cell] = []
  private var contentWidth: CGFloat = 0

  override var orderedTextSurfaces: [RichBlockTextSurface] {
    cells.indices.compactMap { cellViews[$0] }
  }

  init() {
    super.init(reuseKind: .table)
    wantsLayer = true
    layer?.cornerRadius = 7
    layer?.masksToBounds = true
    addSubview(scrollView)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Table")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func apply(node: RichBlockLayoutPlan.Node, context: RichBlockRenderContext) {
    guard case let .table(table) = node.kind else { return }
    let preservedOffset = scrollView.contentView.bounds.minX
    cells = table.cells
    contentWidth = table.contentWidth
    canvasView.apply(
      cells: cells,
      separatorColor: context.palette.separator,
      headerFillColor: context.palette.subtleFill
    )

    let indices = Set(cells.indices)
    for index in Array(cellViews.keys) where !indices.contains(index) {
      if let removed = cellViews.removeValue(forKey: index) {
        removed.configureMultiSurfaceSelection(
          mouseDown: nil,
          mouseDragged: nil,
          mouseUp: nil,
          trackingEnded: nil,
          shouldSuppressPlainClick: nil
        )
        removed.clearCoordinatedSelection()
        removed.removeFromSuperview()
      }
    }
    for (index, cell) in cells.enumerated() {
      let view = cellViews[index] ?? {
        let view = RichBlockTextSurface(frame: .zero)
        cellViews[index] = view
        canvasView.addSubview(view)
        return view
      }()
      view.apply(
        text: context.tableText(for: cell, isRTL: table.isRTL),
        linkColor: context.palette.link,
        onEntityClick: context.interactions.onTextEntityClick
      )
    }
    restoreHorizontalOffset(preservedOffset)
    needsLayout = true
  }

  override func updateLayout(node: RichBlockLayoutPlan.Node) {
    guard case let .table(table) = node.kind else { return }
    cells = table.cells
    contentWidth = table.contentWidth
    canvasView.updateGeometry(cells: cells)
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let preservedOffset = scrollView.contentView.bounds.minX
    scrollView.frame = bounds
    let canvasFrame = CGRect(
      x: 0,
      y: 0,
      width: max(bounds.width, contentWidth),
      height: bounds.height
    )
    // The rules span the canvas; content changes redraw through `apply`.
    if canvasView.frame != canvasFrame {
      canvasView.frame = canvasFrame
      canvasView.needsDisplay = true
    }
    for (index, cell) in cells.enumerated() {
      cellViews[index]?.frame = cell.frame.insetBy(
        dx: Self.horizontalPadding,
        dy: Self.verticalPadding
      )
    }
    restoreHorizontalOffset(preservedOffset)
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    for view in cellViews.values {
      view.removeFromSuperview()
    }
    cellViews.removeAll(keepingCapacity: true)
    cells = []
    contentWidth = 0
    canvasView.apply(cells: [], separatorColor: .clear, headerFillColor: .clear)
    restoreHorizontalOffset(0)
  }

  private func restoreHorizontalOffset(_ proposedOffset: CGFloat) {
    let maximumOffset = max(0, contentWidth - bounds.width)
    scrollView.contentView.scroll(
      to: CGPoint(x: min(max(0, proposedOffset), maximumOffset), y: 0)
    )
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }
}

/// Header fill plus row and column rules, as on iOS: one device pixel wide,
/// starting on the cell edge. Columns come from cell frames, so the rules follow
/// whichever side the first column is on.
private final class RichBlockTableCanvasView: NSView {
  private var cells: [RichBlockLayoutPlan.TableNode.Cell] = []
  private var separatorColor = NSColor.separatorColor
  private var headerFillColor = NSColor.clear

  override var isFlipped: Bool { true }

  func apply(
    cells: [RichBlockLayoutPlan.TableNode.Cell],
    separatorColor: NSColor,
    headerFillColor: NSColor
  ) {
    guard cells != self.cells
      || !separatorColor.isEqual(self.separatorColor)
      || !headerFillColor.isEqual(self.headerFillColor)
    else { return }
    self.cells = cells
    self.separatorColor = separatorColor
    self.headerFillColor = headerFillColor
    needsDisplay = true
  }

  func updateGeometry(cells: [RichBlockLayoutPlan.TableNode.Cell]) {
    guard cells != self.cells else { return }
    self.cells = cells
    needsDisplay = true
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    needsDisplay = true
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard !cells.isEmpty else { return }
    let scale = max(1, window?.backingScaleFactor ?? 2)
    let hairline = 1 / scale
    func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }

    let headerBottom = cells.reduce(CGFloat(0)) { $1.isHeader ? max($0, $1.frame.maxY) : $0 }
    if headerBottom > 0 {
      headerFillColor.setFill()
      CGRect(x: 0, y: 0, width: bounds.width, height: snap(headerBottom)).fill(using: .sourceOver)
    }

    separatorColor.setFill()
    let rowTops = Set(cells.map(\.frame.minY))
    for top in rowTops where top > 0.5 && top < bounds.height - 0.5 {
      CGRect(x: 0, y: snap(top), width: bounds.width, height: hairline).fill(using: .sourceOver)
    }
    // Every row shares the column edges; the first row is enough.
    guard let firstRowTop = rowTops.min() else { return }
    let tableMaxX = cells.reduce(CGFloat(0)) { max($0, $1.frame.maxX) }
    var columnEdges = Set<CGFloat>()
    for cell in cells where cell.frame.minY == firstRowTop {
      columnEdges.insert(cell.frame.minX)
      columnEdges.insert(cell.frame.maxX)
    }
    for edge in columnEdges where edge > 0.5 && edge < tableMaxX - 0.5 {
      CGRect(x: snap(edge), y: 0, width: hairline, height: bounds.height).fill(using: .sourceOver)
    }
  }
}
