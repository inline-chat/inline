import AppKit

final class RichBlockTextNodeView: RichBlockRenderableView {
  private let surface = RichBlockTextSurface(frame: .zero)

  override var orderedTextSurfaces: [RichBlockTextSurface] { [surface] }

  /// streaming: characters of this node's text drawn while its message streams; nil draws all.
  func setRevealedLength(_ length: Int?) {
    surface.setRevealedLength(length)
  }

  init() {
    super.init(reuseKind: .text)
    // Paragraphs, headings, list items and quotes draw in a layer when they can (`RichBlockLayerText`).
    surface.prefersLayerText = true
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

  override func prepareForReuse() {
    super.prepareForReuse()
    surface.prepareForReuse()
  }
}
