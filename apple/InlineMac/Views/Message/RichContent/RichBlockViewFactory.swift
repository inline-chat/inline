import AppKit

@MainActor
enum RichBlockViewFactory {
  static func make(for node: RichBlockLayoutPlan.Node) -> RichBlockRenderableView {
    switch node.reuseKind {
    case .math:
      RichBlockMathNodeView()
    case .text:
      RichBlockTextNodeView()
    case .listMarker:
      RichBlockListMarkerNodeView()
    case .code:
      RichBlockCodeNodeView()
    case .disclosure:
      RichBlockDisclosureNodeView()
    case .separator:
      RichBlockSeparatorNodeView()
    case .image:
      RichBlockImageNodeView()
    case .album:
      RichBlockAlbumNodeView()
    case .quote:
      RichBlockQuoteNodeView()
    case .table:
      RichBlockTableNodeView()
    case .fields:
      RichBlockFieldsNodeView()
    case .steps:
      RichBlockStepsNodeView()
    case .callout:
      RichBlockCalloutNodeView()
    case .meter:
      RichBlockMeterNodeView()
    case .diff:
      RichBlockDiffNodeView()
    case .form:
      RichBlockFormNodeView()
    }
  }
}
