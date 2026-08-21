import AppKit

final class RichBlockSeparatorNodeView: RichBlockRenderableView {
  init() {
    super.init(reuseKind: .separator)
    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func apply(node: RichBlockLayoutPlan.Node, context: RichBlockRenderContext) {
    guard case .separator = node.kind else { return }
    layer?.backgroundColor = context.palette.separator.cgColor
  }
}
