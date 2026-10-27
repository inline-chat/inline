import CoreGraphics
import Foundation

/// Turns a message into exact row geometry. Pure and thread-safe; call it off the main thread.
public enum MessageLayoutPlanner {
  public static func layout(_ input: MessageLayoutInput, cache: TextLayoutCache? = nil) -> MessageLayout {
    let m = input.metrics
    let grid = input.grid
    let isEmoji: Bool
    let bodyText: MessageText
    var richBlocks: [RichBlock]?
    switch input.body {
    case let .text(text):
      isEmoji = false
      bodyText = text
    case let .emoji(text):
      isEmoji = true
      bodyText = text
    case let .rich(blocks):
      isEmoji = false
      bodyText = MessageText(NSAttributedString())
      richBlocks = blocks
    }
    let hasBubble = !isEmoji
    let insets = isEmoji ? m.emojiInsets : m.bubbleInsets

    // Lane: the horizontal band a bubble may occupy, measured from the row's leading edge.
    let avatarColumn = input.isOutgoing || input.avatar == .none ? 0 : m.avatarSize + m.avatarSpacing
    let laneMinX = m.rowLeadingInset + avatarColumn
    let laneWidth = max(0, input.rowWidth - m.rowLeadingInset - m.rowTrailingInset - avatarColumn)
    let maximumBodyWidth = grid.floor(laneWidth * m.maximumBubbleWidthFraction)

    // Blocks. Large emoji carry none. The first edge-to-edge block above the text sets the body
    // width, scaled down to fit the lane; a caption wraps to it.
    let blocks = isEmoji ? [] : input.blocks
    let edgeIndex = blocks.firstIndex { $0.isEdgeToEdge && $0.position == .aboveText }
    let edgeSize: CGSize? = edgeIndex.map { index in
      let block = blocks[index]
      let wanted = max(1, block.width.preferred)
      let width = grid.floor(min(maximumBodyWidth, wanted))
      return CGSize(width: width, height: grid.round(block.height * width / wanted))
    }
    let maximumContentWidth = max(1, (edgeSize?.width ?? maximumBodyWidth) - insets.horizontal)
    let above = blocks.indices.filter { blocks[$0].position == .aboveText }
    let below = blocks.indices.filter { blocks[$0].position == .belowText }
    let outside = blocks.indices.filter { blocks[$0].position == .belowBubble }
    // Blocks under the bubble follow its width; they never widen it.
    let blocksWidth = blocks.indices.filter { $0 != edgeIndex && blocks[$0].position != .belowBubble }
      .map { min(blocks[$0].width.demand, maximumContentWidth) }
      .max() ?? 0

    // Measure.
    func typeset(_ text: MessageText, width: CGFloat) -> TextLayout {
      let style = TextLayoutStyle(fallbackDirection: input.layoutDirection)
      if let cache {
        return cache.layout(text, style: style, maximumWidth: width, grid: grid)
      }
      return TextLayouter.layout(text, style: style, maximumWidth: width, grid: grid)
    }
    let text = bodyText.isEmpty ? TextLayout.empty : typeset(bodyText, width: maximumContentWidth)
    let rich = richBlocks.flatMap {
      RichLayoutPlanner.layout(
        $0,
        maximumWidth: maximumContentWidth,
        grid: grid,
        layoutDirection: input.layoutDirection,
        metrics: input.richMetrics,
        cache: cache
      )
    }
    // The body's measurements, whichever kind it is.
    // While a text body streams, only the lines up to the one holding the last revealed
    // character count: they set the body's width and height.
    let revealedLines: ArraySlice<TextLayout.Line>? = input.revealedLength.flatMap { revealed in
      guard rich == nil, !isEmoji, text.lineCount > 0, revealed < text.length else { return nil }
      let frontier = text.lines.firstIndex { NSMaxRange($0.range) > max(0, revealed) } ?? text.lineCount - 1
      return text.lines[...frontier]
    }
    let bodySize = rich?.size ?? revealedLines.map {
      CGSize(width: $0.map(\.width).max() ?? 0, height: $0.last?.frame.maxY ?? 0)
    } ?? text.size
    let hasBody = rich != nil || text.lineCount > 0
    let time = typeset(input.footer.time, width: .greatestFiniteMagnitude)
    let name = input.name.map { typeset($0, width: maximumBodyWidth) }

    let flow = ReactionFlow(
      reactions: input.reactions,
      maximumWidth: maximumContentWidth,
      spacing: m.reactionSpacing,
      rowSpacing: m.reactionRowSpacing
    )
    // Media with nothing under it carries the time over its bottom-trailing corner.
    let overlaysMedia = edgeIndex != nil && edgeIndex == above.last && !hasBody
      && below.isEmpty && flow.isEmpty

    let statusSize = input.footer.statusSize ?? .zero
    // Over large emoji and media the time sits in a pill, so its frame includes the pill's padding.
    let pill = isEmoji || overlaysMedia ? m.timeOverlayPadding : .zero
    let timeWidth = time.size.width + (input.footer.statusSize == nil ? 0 : m.timeStatusSpacing + statusSize.width)
      + pill.width * 2
    let timeHeight = max(time.size.height, statusSize.height) + pill.height * 2
    let acknowledgement = input.acknowledgementSize
    let footerWidth = timeWidth + (acknowledgement.map { $0.width + m.acknowledgementSpacing } ?? 0)
    let footerHeight = max(timeHeight, acknowledgement?.height ?? 0)

    // A fixed-width block with nothing under it, such as a file, takes the time beside its
    // bottom edge when there is room, instead of a row of its own.
    let besideBlock: Int? = {
      guard !isEmoji, !hasBody, below.isEmpty, flow.isEmpty,
            let last = above.last, last != edgeIndex,
            case let .fixed(width) = blocks[last].width,
            min(width, maximumContentWidth) + m.inlineTimeSpacing + footerWidth <= maximumContentWidth
      else { return nil }
      return last
    }()

    // The region under the above-text blocks: text, then below-text blocks, then reactions and
    // the footer. Offsets are from the region's top.
    var belowOffsets: [CGFloat] = []
    var regionHeight = bodySize.height
    for index in below {
      if regionHeight > 0 { regionHeight += m.blockSpacing }
      belowOffsets.append(regionHeight)
      regionHeight += blocks[index].height
    }
    // The time can follow the last line only when nothing sits under the text.
    struct TrailingLine {
      var width: CGFloat
      var baseline: CGFloat
      var direction: TextDirection
      var isOnlyLine: Bool
    }
    let lastLine: TrailingLine? = if !below.isEmpty {
      nil
    } else if let rich {
      rich.trailingLine.map { TrailingLine(width: $0.maxX, baseline: $0.baseline, direction: $0.direction, isOnlyLine: false) }
    } else if let revealedLines, let frontier = revealedLines.last {
      TrailingLine(width: frontier.width, baseline: frontier.baseline, direction: frontier.direction, isOnlyLine: revealedLines.count == 1)
    } else {
      text.lastLine.map {
        TrailingLine(width: $0.width, baseline: text.lastBaseline, direction: $0.direction, isOnlyLine: text.lineCount == 1)
      }
    }

    // Place the footer: beside the reactions, inline after the last line, or on its own row.
    let placement: MessageTimePlacement
    var contentWidth: CGFloat
    var contentHeight: CGFloat
    var footerTop: CGFloat
    var reactionsTop: CGFloat = 0
    var alignedText = text

    if isEmoji {
      placement = .overlay
      reactionsTop = flow.isEmpty ? 0 : text.size.height + m.emojiReactionsSpacing
      contentWidth = grid.ceil(max(text.size.width, flow.size.width, footerWidth))
      footerTop = max(0, text.size.height - footerHeight)
      contentHeight = flow.isEmpty ? text.size.height : reactionsTop + flow.size.height
      alignedText = text.aligned(toWidth: text.size.width)
    } else if overlaysMedia {
      placement = .overlay
      contentWidth = maximumContentWidth
      footerTop = 0
      contentHeight = 0
    } else if let besideBlock {
      placement = .inline
      contentWidth = grid.ceil(min(blocks[besideBlock].width.preferred, maximumContentWidth)
        + m.inlineTimeSpacing + footerWidth)
      footerTop = 0
      contentHeight = 0
    } else if !flow.isEmpty {
      let spacing = m.reactionsTopSpacing
      reactionsTop = regionHeight > 0 ? regionHeight + spacing : 0
      let lastRow = flow.rows[flow.rows.count - 1]
      if lastRow.width + m.reactionTimeSpacing + footerWidth <= maximumContentWidth {
        placement = .reactionsRow
        contentWidth = max(bodySize.width, flow.size.width, lastRow.width + m.reactionTimeSpacing + footerWidth)
        footerTop = reactionsTop + lastRow.midY - footerHeight / 2
        contentHeight = reactionsTop + flow.size.height
      } else {
        placement = .below
        contentWidth = max(bodySize.width, flow.size.width, footerWidth)
        footerTop = reactionsTop + flow.size.height + m.timeRowSpacing
        contentHeight = footerTop + footerHeight
      }
      contentWidth = grid.ceil(contentWidth)
      alignedText = text.aligned(toWidth: contentWidth)
    } else if let lastLine,
              lastLine.isOnlyLine || lastLine.direction == input.layoutDirection,
              lastLine.width + m.inlineTimeSpacing + footerWidth <= maximumContentWidth
    {
      // A last line written against the interface direction hugs the trailing edge, where the
      // time goes, unless it is the only line and can sit at the leading edge.
      placement = .inline
      contentWidth = grid.ceil(max(bodySize.width, lastLine.width + m.inlineTimeSpacing + footerWidth))
      // Share the last line's baseline. The time text is centered in its frame and the frame in
      // the footer row, so start the row that much higher.
      let timeTextTop = lastLine.baseline - (time.lines.first?.baseline ?? time.size.height)
      let centering = (timeHeight - time.size.height) / 2 + (footerHeight - timeHeight) / 2
      footerTop = grid.round(max(0, timeTextTop - centering))
      contentHeight = max(bodySize.height, footerTop + footerHeight)
      alignedText = text.lineCount == 1 ? text : text.aligned(toWidth: contentWidth)
    } else {
      placement = .below
      contentWidth = grid.ceil(max(bodySize.width, footerWidth))
      footerTop = regionHeight > 0 ? regionHeight + m.timeRowSpacing : 0
      contentHeight = footerTop + footerHeight
      alignedText = text.aligned(toWidth: contentWidth)
    }
    contentHeight = grid.ceil(contentHeight)

    // Blocks widen the content; edge-to-edge media fixes it.
    if !isEmoji {
      let widened = edgeSize == nil ? grid.ceil(max(contentWidth, blocksWidth)) : maximumContentWidth
      if widened != contentWidth {
        contentWidth = widened
        if !(placement == .inline && text.lineCount == 1) {
          alignedText = text.aligned(toWidth: contentWidth)
        }
      }
    }

    // Stack the above-text blocks from the body's top. Edge-to-edge media skips the padding.
    var blockTops: [Int: CGFloat] = [:]
    var stackBottom: CGFloat = 0
    var lastWasEdge = false
    for (position, index) in above.enumerated() {
      let isEdge = index == edgeIndex
      if position == 0 {
        stackBottom = isEdge ? 0 : insets.top
      } else {
        stackBottom += lastWasEdge ? insets.top : m.blockSpacing
      }
      blockTops[index] = stackBottom
      stackBottom += isEdge ? edgeSize?.height ?? 0 : blocks[index].height
      lastWasEdge = isEdge
    }
    let regionTop = above.isEmpty ? insets.top : stackBottom + (lastWasEdge ? insets.top : m.blockSpacing)

    // Bubble body, in logical coordinates (x from the row's leading edge).
    let bodyWidth = edgeSize?.width ?? contentWidth + insets.horizontal
    let minimumBodyHeight = hasBubble ? m.cornerRadius * 2 : 0
    let bodyHeight: CGFloat = if overlaysMedia {
      max(stackBottom, minimumBodyHeight)
    } else if besideBlock != nil {
      max(stackBottom + insets.bottom, minimumBodyHeight)
    } else {
      max(regionTop + contentHeight + insets.bottom, minimumBodyHeight)
    }
    let rowTop = input.isFirstInGroup ? m.groupTopSpacing : m.followUpTopSpacing

    // Bodies sit at the same x with or without a tail, so grouped bubbles line up; the tail
    // overhangs into the row inset or avatar gap.
    let bodyX = input.isOutgoing
      ? input.rowWidth - m.rowTrailingInset - m.bodyEdgeInset - bodyWidth
      : laneMinX + m.bodyEdgeInset

    var frames: [MessageLayoutNode: CGRect] = [:]
    var y = rowTop
    if let name {
      let nameHeight = max(m.nameMinimumHeight, name.size.height)
      let nameX = input.isOutgoing
        ? bodyX + bodyWidth - m.nameLeadingInset - name.size.width
        : bodyX + m.nameLeadingInset
      y = m.nameTopSpacing
      frames[.name] = CGRect(x: nameX, y: y, width: name.size.width, height: nameHeight)
      y += nameHeight + m.nameBottomSpacing
    }

    let body = CGRect(x: bodyX, y: y, width: bodyWidth, height: bodyHeight)
    let tail: BubbleTailSide = hasBubble ? input.tail : .none
    var bubbleFrame = body
    switch tail {
    case .none: break
    case .leading:
      bubbleFrame.origin.x -= m.tailWidth
      bubbleFrame.size.width += m.tailWidth
    case .trailing:
      bubbleFrame.size.width += m.tailWidth
    }
    frames[.bubble] = bubbleFrame

    let contentOrigin = CGPoint(x: body.minX + insets.leading, y: body.minY + regionTop)
    func width(of block: MessageLayoutInput.Block) -> CGFloat {
      switch block.width {
      case let .fixed(width): min(width, contentWidth)
      case .flexible: contentWidth
      }
    }
    for index in above {
      let block = blocks[index]
      let top = body.minY + (blockTops[index] ?? 0)
      frames[.block(block.id)] = index == edgeIndex
        ? CGRect(x: body.minX, y: top, width: body.width, height: edgeSize?.height ?? block.height)
        : CGRect(x: contentOrigin.x, y: top, width: width(of: block), height: block.height)
    }
    for (offset, index) in zip(belowOffsets, below) {
      let block = blocks[index]
      frames[.block(block.id)] = CGRect(
        x: contentOrigin.x,
        y: contentOrigin.y + offset,
        width: width(of: block),
        height: block.height
      )
    }
    // Under the bubble, aligned to its side.
    var outsideBottom = body.maxY
    for index in outside {
      let block = blocks[index]
      let width = switch block.width {
      case let .fixed(width): min(width, body.width)
      case .flexible: body.width
      }
      outsideBottom += m.belowBubbleSpacing
      frames[.block(block.id)] = CGRect(
        x: input.isOutgoing ? body.maxX - width : body.minX,
        y: outsideBottom,
        width: width,
        height: block.height
      )
      outsideBottom += block.height
    }
    if let rich {
      frames[.text] = CGRect(origin: contentOrigin, size: rich.size)
    } else if text.lineCount > 0 {
      let emojiOffset = isEmoji && input.isOutgoing ? contentWidth - alignedText.size.width : 0
      frames[.text] = CGRect(
        x: contentOrigin.x + emojiOffset,
        y: contentOrigin.y,
        width: revealedLines == nil ? alignedText.size.width : min(alignedText.size.width, contentWidth),
        height: revealedLines == nil ? alignedText.size.height : bodySize.height
      )
    }
    for (index, reaction) in input.reactions.enumerated() {
      let frame = flow.frames[index]
      frames[.reaction(reaction.id)] = frame.offsetBy(dx: contentOrigin.x, dy: contentOrigin.y + reactionsTop)
    }

    let footerMaxX = overlaysMedia ? body.maxX - m.mediaOverlayInset : contentOrigin.x + contentWidth
    let footerY = if overlaysMedia {
      body.minY + stackBottom - m.mediaOverlayInset - footerHeight
    } else if besideBlock != nil {
      body.minY + stackBottom - footerHeight
    } else {
      contentOrigin.y + footerTop
    }
    frames[.time] = CGRect(
      x: footerMaxX - timeWidth,
      y: footerY + (footerHeight - timeHeight) / 2,
      width: timeWidth,
      height: timeHeight
    )
    if let acknowledgement {
      frames[.acknowledgement] = CGRect(
        x: footerMaxX - timeWidth - m.acknowledgementSpacing - acknowledgement.width,
        y: footerY + (footerHeight - acknowledgement.height) / 2,
        width: acknowledgement.width,
        height: acknowledgement.height
      )
    }

    if input.avatar == .visible, !input.isOutgoing {
      frames[.avatar] = CGRect(
        x: m.rowLeadingInset,
        y: body.maxY - m.avatarSize,
        width: m.avatarSize,
        height: m.avatarSize
      )
    }

    // Snap to pixels, then mirror for right-to-left interfaces.
    let mirrored = input.layoutDirection == .rightToLeft
    func finalize(_ rect: CGRect) -> CGRect {
      var rect = grid.round(rect)
      if mirrored {
        rect.origin.x = input.rowWidth - rect.maxX
      }
      return rect
    }
    frames = frames.mapValues(finalize)

    let bubble = MessageLayout.Bubble(
      frame: frames[.bubble] ?? .zero,
      body: finalize(body),
      tail: tail,
      cornerRadius: m.cornerRadius,
      isVisible: hasBubble
    )
    if !hasBubble {
      frames[.bubble] = nil
    }

    return MessageLayout(
      size: CGSize(width: input.rowWidth, height: grid.ceil(max(bubble.frame.maxY, outsideBottom))),
      bubble: bubble,
      frames: frames,
      hiddenNodes: input.footer.visibility == .reserved ? [.time] : [],
      text: text.lineCount > 0 ? alignedText : nil,
      rich: rich,
      revealedLength: revealedLines == nil ? nil : input.revealedLength,
      name: name,
      time: time,
      timePlacement: placement,
      reactionOrder: input.reactions.map(\.id),
      blockOrder: blocks.map(\.id),
      edgeToEdgeBlocks: edgeIndex.map { [blocks[$0].id] } ?? []
    )
  }
}

extension MessageLayoutInput.Block.Width {
  /// The width the block asks for.
  var preferred: CGFloat {
    switch self {
    case let .fixed(width): width
    case let .flexible(preferred, _): preferred
    }
  }

  /// The content width the block needs: its preferred width, at least its minimum.
  var demand: CGFloat {
    switch self {
    case let .fixed(width): width
    case let .flexible(preferred, minimum): max(preferred, minimum)
    }
  }
}

/// Left-to-right flow of reaction pills, wrapping at `maximumWidth`.
struct ReactionFlow {
  struct Row {
    var minY: CGFloat
    var width: CGFloat
    var height: CGFloat
    var midY: CGFloat { minY + height / 2 }
  }

  private(set) var frames: [CGRect] = []
  private(set) var rows: [Row] = []
  private(set) var size: CGSize = .zero

  var isEmpty: Bool { frames.isEmpty }

  init(reactions: [MessageLayoutInput.Reaction], maximumWidth: CGFloat, spacing: CGFloat, rowSpacing: CGFloat) {
    guard !reactions.isEmpty else { return }
    var x: CGFloat = 0
    var row = Row(minY: 0, width: 0, height: 0)
    var rowStart = 0
    for reaction in reactions {
      let pill = CGSize(width: min(reaction.size.width, maximumWidth), height: reaction.size.height)
      if x > 0, x + spacing + pill.width > maximumWidth {
        finish(row, from: rowStart)
        row = Row(minY: row.minY + row.height + rowSpacing, width: 0, height: 0)
        rowStart = frames.count
        x = 0
      }
      if x > 0 { x += spacing }
      frames.append(CGRect(x: x, y: row.minY, width: pill.width, height: pill.height))
      x += pill.width
      row.width = x
      row.height = max(row.height, pill.height)
    }
    finish(row, from: rowStart)
    size = CGSize(width: rows.map(\.width).max() ?? 0, height: row.minY + row.height)
  }

  /// Centers shorter pills vertically in their row.
  private mutating func finish(_ row: Row, from start: Int) {
    for index in start ..< frames.count {
      frames[index].origin.y = row.minY + (row.height - frames[index].height) / 2
    }
    rows.append(row)
  }
}
