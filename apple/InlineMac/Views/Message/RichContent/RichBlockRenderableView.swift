import AppKit

@MainActor
class RichBlockRenderableView: NSView {
  let reuseKind: RichBlockRenderKind
  private(set) var isContentVisible = true

  override var isFlipped: Bool { true }

  init(reuseKind: RichBlockRenderKind) {
    self.reuseKind = reuseKind
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func apply(node _: RichBlockLayoutPlan.Node, context _: RichBlockRenderContext) {}

  /// Canonical visual order for text holds and optional message-local selection.
  /// Most rich nodes are not text and intentionally return no surfaces.
  var orderedTextSurfaces: [RichBlockTextSurface] { [] }

  /// Refreshes width-dependent geometry without reapplying content or starting
  /// asynchronous work. Composite nodes override this when their child frames
  /// are carried inside the layout-plan payload.
  func updateLayout(node _: RichBlockLayoutPlan.Node) {}

  func setContentVisible(_ visible: Bool) {
    isContentVisible = visible
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    setContentVisible(false)
  }
}
