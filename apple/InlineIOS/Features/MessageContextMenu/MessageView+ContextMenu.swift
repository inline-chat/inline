import InlineMessageLayout
import UIKit

extension MessageView {
  /// The bubble with its tail, rounded out to whole pixels, in `bubbleContentView` coordinates.
  var contextMenuBubbleExtent: CGRect {
    let extent = bubbleContentView.bounds.union(bubbleView.visiblePath().bounds)
    let scale = window?.screen.scale ?? traitCollection.displayScale
    let grid = max(scale, 1)
    return CGRect(
      x: floor(extent.minX * grid) / grid,
      y: floor(extent.minY * grid) / grid,
      width: (ceil(extent.maxX * grid) - floor(extent.minX * grid)) / grid,
      height: (ceil(extent.maxY * grid) - floor(extent.minY * grid)) / grid
    )
  }

  /// A live copy of this bubble clipped to `extent`, for the context menu's preview. Only for
  /// content that draws in its first frame (text, forwards, replies); media and streaming
  /// messages return nil and use a bitmap.
  func makeContextMenuPreview(extent: CGRect) -> UIView? {
    guard let content, let layout,
          !MessageStreamPacer.shared.isStreaming(content.message.id),
          content.blocks.allSatisfy({ $0.kind == .forward || $0.kind == .reply }),
          content.rich?.photos.isEmpty ?? true
    else { return nil }
    let copy = MessageView()
    copy.spaceId = spaceId
    copy.isUserInteractionEnabled = false
    copy.apply(content, layout: layout, motion: .immediate)
    copy.untransformedFrame = CGRect(
      x: -(layout.bubble.frame.minX + extent.minX),
      y: -(layout.bubble.frame.minY + extent.minY),
      width: layout.size.width,
      height: layout.size.height
    )
    let lighting = bubbleView.currentLightingVector
    copy.bubbleView.updateLightingVector(startY: lighting.startY, endY: lighting.endY)
    let container = UIView(frame: CGRect(origin: .zero, size: extent.size))
    container.clipsToBounds = true
    container.addSubview(copy)
    return container
  }

  /// The body text for selection in the preview, framed relative to `extent`. Rich bodies and
  /// streaming text aren't selectable yet.
  func contextMenuSelectableText(
    extent: CGRect,
    colors: MessageTextSelectionView.Colors
  ) -> MessageContextMenuController.SelectableText? {
    guard let layout, layout.rich == nil, layout.revealedLength == nil, layout.text != nil,
          textView.layout.length > 0, !textView.isHidden
    else { return nil }
    return MessageContextMenuController.SelectableText(
      layout: textView.layout,
      frame: textView.textFrame.offsetBy(dx: -extent.minX, dy: -extent.minY),
      colors: colors
    )
  }
}

extension MessageTextSelectionView.Colors {
  /// Tinted selection on incoming bubbles, white on outgoing ones, which are filled with the tint.
  static func forBubble(outgoing: Bool, tint: UIColor) -> MessageTextSelectionView.Colors {
    MessageTextSelectionView.Colors(
      highlight: outgoing ? UIColor.white.withAlphaComponent(0.35) : tint.withAlphaComponent(0.25),
      handle: outgoing ? .white : tint
    )
  }
}
