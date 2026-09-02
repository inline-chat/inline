import AppKit

final class RichBlockTextNodeView: RichBlockRenderableView {
  private let surface = RichBlockTextSurface(frame: .zero)

  override var orderedTextSurfaces: [RichBlockTextSurface] { [surface] }

  init() {
    super.init(reuseKind: .text)
    addSubview(surface)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func apply(node: RichBlockLayoutPlan.Node, context: RichBlockRenderContext) {
    guard case let .text(text) = node.kind else { return }
    surface.apply(
      text: context.text(for: text, maximumWidth: node.frame.width),
      linkColor: context.palette.link,
      onEntityClick: context.interactions.onTextEntityClick
    )
  }

  override func layout() {
    super.layout()
    surface.frame = bounds
  }
}
