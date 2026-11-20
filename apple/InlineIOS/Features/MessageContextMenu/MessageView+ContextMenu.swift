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
    // A fresh view starts code and tables at their beginning; show them where this row has them.
    if let richView, let copyRich = copy.richView {
      copyRich.restoreScrollOffsets(richView.scrollOffsets())
    }
    // The menu lifts the bubble; an avatar beside it would show at the edge of the tail.
    copy.avatarView?.isHidden = true
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

  /// The photo this message shows now, for the menu's Copy Photo and Save Photo.
  var contextMenuPhotoImage: UIImage? {
    blockViews.values.lazy.compactMap { ($0.contentView as? NewPhotoView)?.getCurrentImage() }.first
  }

  /// Opens the document this message shows, for a failed message's menu.
  func openContextMenuDocument() {
    blockViews.values.lazy.compactMap { $0.contentView as? DocumentView }.first?.openFile()
  }

  /// The body text for selection in the preview, framed relative to `extent`: a plain body or
  /// a rich one's paragraphs, lists, quotes, code, tables and card text. Streaming text isn't
  /// selectable yet.
  func contextMenuSelectableText(
    extent: CGRect,
    colors: MessageTextSelectionView.Colors
  ) -> MessageContextMenuController.SelectableText? {
    guard let content, let layout, layout.revealedLength == nil else { return nil }
    if let rich = layout.rich {
      guard let richView, !richView.isHidden, let frame = layout.frame(.text),
            !MessageStreamPacer.shared.isStreaming(content.message.id),
            rich.nodes.allSatisfy({ $0.revealedLength == nil })
      else { return nil }
      // The rich view sits at the text frame, in the bubble's coordinates.
      let origin = CGPoint(
        x: frame.minX - layout.bubble.frame.minX - extent.minX,
        y: frame.minY - layout.bubble.frame.minY - extent.minY
      )
      guard let text = MessageSelectableText.rich(rich, origin: origin, scrollOffsets: richView.scrollOffsets()) else {
        return nil
      }
      return MessageContextMenuController.SelectableText(text: text, colors: colors)
    }
    guard layout.text != nil, textView.layout.length > 0, !textView.isHidden else { return nil }
    let frame = textView.textFrame.offsetBy(dx: -extent.minX, dy: -extent.minY)
    return MessageContextMenuController.SelectableText(text: .plain(textView.layout, origin: frame.origin), colors: colors)
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
