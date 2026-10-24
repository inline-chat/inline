import CoreGraphics

/// Turns a message into exact row geometry. Pure and thread-safe; call it off the main thread.
public enum MessageLayoutPlanner {
  public static func layout(_ input: MessageLayoutInput, cache: TextLayoutCache? = nil) -> MessageLayout {
    let m = input.metrics
    let grid = input.grid
    let isEmoji: Bool
    let bodyText: MessageText
    switch input.body {
    case let .text(text):
      isEmoji = false
      bodyText = text
    case let .emoji(text):
      isEmoji = true
      bodyText = text
    }
    let hasBubble = !isEmoji
    let insets = isEmoji ? m.emojiInsets : m.bubbleInsets

    // Lane: the horizontal band a bubble may occupy, measured from the row's leading edge.
    let avatarColumn = input.isOutgoing || input.avatar == .none ? 0 : m.avatarSize + m.avatarSpacing
    let laneMinX = m.rowLeadingInset + avatarColumn
    let laneWidth = max(0, input.rowWidth - m.rowLeadingInset - m.rowTrailingInset - avatarColumn)
    // Bodies keep the tail column even without a tail, so grouped bubbles line up.
    let maximumBodyWidth = grid.floor(laneWidth * m.maximumBubbleWidthFraction) - m.tailWidth
    let maximumContentWidth = max(1, maximumBodyWidth - insets.horizontal)

    // Measure.
    func typeset(_ text: MessageText, width: CGFloat) -> TextLayout {
      let style = TextLayoutStyle(fallbackDirection: input.layoutDirection)
      if let cache {
        return cache.layout(text, style: style, maximumWidth: width, grid: grid)
      }
      return TextLayouter.layout(text, style: style, maximumWidth: width, grid: grid)
    }
    let text = bodyText.isEmpty ? TextLayout.empty : typeset(bodyText, width: maximumContentWidth)
    let time = typeset(input.footer.time, width: .greatestFiniteMagnitude)
    let name = input.name.map { typeset($0, width: maximumBodyWidth) }

    let statusSize = input.footer.statusSize ?? .zero
    let timeWidth = time.size.width + (input.footer.statusSize == nil ? 0 : m.timeStatusSpacing + statusSize.width)
    let timeHeight = max(time.size.height, statusSize.height)
    let acknowledgement = input.acknowledgementSize
    let footerWidth = timeWidth + (acknowledgement.map { $0.width + m.acknowledgementSpacing } ?? 0)
    let footerHeight = max(timeHeight, acknowledgement?.height ?? 0)

    let flow = ReactionFlow(
      reactions: input.reactions,
      maximumWidth: maximumContentWidth,
      spacing: m.reactionSpacing,
      rowSpacing: m.reactionRowSpacing
    )

    // Place the footer: beside the reactions, inline after the last line, or on its own row.
    let placement: MessageTimePlacement
    var contentWidth: CGFloat
    var contentHeight: CGFloat
    var footerTop: CGFloat
    var reactionsTop: CGFloat = 0
    var alignedText = text

    if !flow.isEmpty {
      let spacing = isEmoji ? m.emojiReactionsSpacing : m.reactionsTopSpacing
      reactionsTop = text.size.height > 0 ? text.size.height + spacing : 0
      let lastRow = flow.rows[flow.rows.count - 1]
      if lastRow.width + m.reactionTimeSpacing + footerWidth <= maximumContentWidth {
        placement = .reactionsRow
        contentWidth = max(text.size.width, flow.size.width, lastRow.width + m.reactionTimeSpacing + footerWidth)
        footerTop = reactionsTop + lastRow.midY - footerHeight / 2
        contentHeight = reactionsTop + flow.size.height
      } else {
        placement = .below
        contentWidth = max(text.size.width, flow.size.width, footerWidth)
        footerTop = reactionsTop + flow.size.height + m.timeRowSpacing
        contentHeight = footerTop + footerHeight
      }
      contentWidth = grid.ceil(contentWidth)
      alignedText = text.aligned(toWidth: contentWidth)
    } else if !isEmoji, let lastLine = text.lastLine,
              text.lineCount == 1 || lastLine.direction == .leftToRight,
              lastLine.width + m.inlineTimeSpacing + footerWidth <= maximumContentWidth
    {
      // A right-to-left last line hugs the trailing edge, where the time would go, unless it
      // is the only line and can sit at the leading edge.
      placement = .inline
      contentWidth = grid.ceil(max(text.size.width, lastLine.width + m.inlineTimeSpacing + footerWidth))
      // Share the last line's baseline. The time text is centered in its frame and the frame in
      // the footer row, so start the row that much higher.
      let timeTextTop = text.lastBaseline - (time.lines.first?.baseline ?? time.size.height)
      let centering = (timeHeight - time.size.height) / 2 + (footerHeight - timeHeight) / 2
      footerTop = grid.round(max(0, timeTextTop - centering))
      contentHeight = max(text.size.height, footerTop + footerHeight)
      alignedText = text.lineCount == 1 ? text : text.aligned(toWidth: contentWidth)
    } else {
      placement = .below
      contentWidth = grid.ceil(max(text.size.width, footerWidth))
      footerTop = text.size.height > 0 ? text.size.height + m.timeRowSpacing : 0
      contentHeight = footerTop + footerHeight
      alignedText = text.aligned(toWidth: contentWidth)
    }
    contentHeight = grid.ceil(contentHeight)

    // Bubble body, in logical coordinates (x from the row's leading edge).
    let bodyWidth = contentWidth + insets.horizontal
    let minimumBodyHeight = hasBubble ? m.cornerRadius * 2 : 0
    let bodyHeight = max(contentHeight + insets.vertical, minimumBodyHeight)
    let rowTop = input.isFirstInGroup ? m.groupTopSpacing : m.followUpTopSpacing

    var frames: [MessageLayoutNode: CGRect] = [:]
    var y = rowTop
    if let name {
      let nameX = input.isOutgoing
        ? input.rowWidth - m.rowTrailingInset - m.tailWidth - name.size.width - insets.trailing
        : laneMinX + m.tailWidth + insets.leading
      frames[.name] = CGRect(x: nameX, y: y, width: name.size.width, height: name.size.height)
      y += name.size.height + m.nameBottomSpacing
    }

    let bodyX = input.isOutgoing
      ? input.rowWidth - m.rowTrailingInset - m.tailWidth - bodyWidth
      : laneMinX + m.tailWidth
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

    let contentOrigin = CGPoint(x: body.minX + insets.leading, y: body.minY + insets.top)
    if text.lineCount > 0 {
      frames[.text] = CGRect(
        x: contentOrigin.x,
        y: contentOrigin.y,
        width: alignedText.size.width,
        height: alignedText.size.height
      )
    }
    for (index, reaction) in input.reactions.enumerated() {
      let frame = flow.frames[index]
      frames[.reaction(reaction.id)] = frame.offsetBy(dx: contentOrigin.x, dy: contentOrigin.y + reactionsTop)
    }

    let footerMaxX = contentOrigin.x + contentWidth
    let footerY = contentOrigin.y + footerTop
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
      size: CGSize(width: input.rowWidth, height: grid.ceil(bubble.frame.maxY)),
      bubble: bubble,
      frames: frames,
      hiddenNodes: input.footer.visibility == .reserved ? [.time] : [],
      text: text.lineCount > 0 ? alignedText : nil,
      time: time,
      timePlacement: placement,
      reactionOrder: input.reactions.map(\.id)
    )
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
