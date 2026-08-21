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
    canvasView.apply(cells: cells, separatorColor: context.palette.separator)

    let indices = Set(cells.indices)
    for index in Array(cellViews.keys) where !indices.contains(index) {
      cellViews.removeValue(forKey: index)?.removeFromSuperview()
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
    canvasView.frame = CGRect(
      x: 0,
      y: 0,
      width: max(bounds.width, contentWidth),
      height: bounds.height
    )
    for (index, cell) in cells.enumerated() {
      cellViews[index]?.frame = cell.frame.insetBy(
        dx: Self.horizontalPadding,
        dy: Self.verticalPadding
      )
    }
    canvasView.needsDisplay = true
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
    canvasView.apply(cells: [], separatorColor: .clear)
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

private final class RichBlockTableCanvasView: NSView {
  private var cells: [RichBlockLayoutPlan.TableNode.Cell] = []
  private var separatorColor = NSColor.separatorColor

  override var isFlipped: Bool { true }

  func apply(cells: [RichBlockLayoutPlan.TableNode.Cell], separatorColor: NSColor) {
    self.cells = cells
    self.separatorColor = separatorColor
    needsDisplay = true
  }

  func updateGeometry(cells: [RichBlockLayoutPlan.TableNode.Cell]) {
    self.cells = cells
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard !cells.isEmpty else { return }
    separatorColor.setStroke()
    let rules = NSBezierPath()
    rules.lineWidth = 1
    for edge in Set(cells.map { $0.frame.maxY }).sorted() where edge < bounds.height - 0.5 {
      rules.move(to: CGPoint(x: 0, y: edge))
      rules.line(to: CGPoint(x: bounds.width, y: edge))
    }
    rules.stroke()
  }
}
