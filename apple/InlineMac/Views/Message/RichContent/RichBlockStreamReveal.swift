import AppKit
import InlineMessageLayout

// Streaming rich bodies (agent and bot messages), as the iOS planner's `RichLayout.revealing`: while a message streams
// (`MessageStreamPacer`), its rich plan shows the nodes whose text has started, the node holding the reveal frontier
// ends at the line holding it, and quotes end under their revealed children. The row is planned at that, so it grows
// a line or a block at a time (`TimelineMessageListAppKit`, `// streaming`); `revealLimit` says at which count the
// plan goes stale. Beyond iOS (which shows code and tables whole once they start), a code block holding the frontier
// shows its text up to the end of that line, and a table the rows started so far.

extension RichBlockLayoutPlan {
  /// A root block the planner gives edge room below when it closes the message (`isFilled`: code, quotes).
  private static func closesWithEdgeRoom(_ node: Node) -> Bool {
    switch node.kind {
      case .code, .quote: true
      default: false
    }
  }

  /// Each node's characters in the message's body: text (not literals such as list markers), code, a table's cells.
  private static func source(of node: Node) -> Range<Int>? {
    switch node.kind {
      case let .text(text) where text.literal == nil && text.rangeLength > 0:
        return text.rangeOffset ..< text.rangeOffset + text.rangeLength
      case let .code(code) where code.rangeLength > 0:
        return code.rangeOffset ..< code.rangeOffset + code.rangeLength
      case let .table(table):
        let cells = table.cells.filter { $0.rangeLength > 0 }
        guard let first = cells.map(\.rangeOffset).min(), let end = cells.map({ $0.rangeOffset + $0.rangeLength }).max()
        else { return nil }
        return first ..< end
      default:
        return nil
    }
  }

  /// The plan with `count` characters of the body revealed, or nil when everything shows (or the nodes' sources are
  /// out of order, when the body shows whole).
  func revealing(_ count: Int, attributedText: NSAttributedString, baseFontSize: CGFloat) -> RichBlockLayoutPlan? {
    // The count at which each node shows: a sourced node at its first character; one without a source (a marker,
    // a separator, an image) with the sourced node after it, or once all text shows when none follows.
    var thresholds = [Int?](repeating: nil, count: nodes.count)
    var lastStart = Int.min
    for (index, node) in nodes.enumerated() {
      guard let range = Self.source(of: node) else { continue }
      guard range.lowerBound >= lastStart else { return nil }
      lastStart = range.lowerBound
      thresholds[index] = range.lowerBound + min(1, range.count)
    }
    guard let lastSourced = nodes.indices.last(where: { thresholds[$0] != nil }) else { return nil }
    var next: Int?
    for index in nodes.indices.reversed() {
      if let threshold = thresholds[index] { next = threshold } else { thresholds[index] = next }
    }
    var revealedEnd = 0
    for index in nodes.indices {
      if let range = Self.source(of: nodes[index]) {
        revealedEnd = max(revealedEnd, range.upperBound)
      } else if index > lastSourced {
        thresholds[index] = revealedEnd
      }
    }

    var kept: [Node] = []
    var bottoms: [CGFloat] = []
    var hidesAny = false
    /// Whether the last kept node shows down to its last line (the time can then sit as it will).
    var lastKeptEndsWhole = true
    var limit: Int?
    func stale(at value: Int) { limit = min(limit ?? value, value) }
    for (index, original) in nodes.enumerated() {
      var node = original
      let threshold = thresholds[index] ?? 0
      guard count >= threshold else {
        hidesAny = true
        stale(at: threshold)
        continue
      }
      var bottom = node.frame.maxY
      lastKeptEndsWhole = true
      if case let .text(text) = node.kind, let range = Self.source(of: node), count < range.upperBound,
         let frontier = frontier(of: text, frame: node.frame, local: count - range.lowerBound,
                                 attributedText: attributedText, baseFontSize: baseFontSize)
      {
        // The frontier node ends at the line holding the next character to reveal, as plain text does.
        bottom = frontier.bottom
        node.frame.size.height = max(1, bottom - node.frame.minY)
        hidesAny = true
        if let lineEnd = frontier.lineEnd {
          stale(at: range.lowerBound + lineEnd)
          lastKeptEndsWhole = false
        }
      } else if case var .code(code) = node.kind, let range = Self.source(of: node), count < range.upperBound,
                let cut = codeFrontier(of: code, frame: node.frame, local: count - range.lowerBound,
                                       attributedText: attributedText, baseFontSize: baseFontSize)
      {
        // A whole line at a time: the node's text ends with the line holding the next character to reveal.
        code.rangeLength = cut.length
        node.kind = .code(code)
        node.frame.size.height = cut.height
        bottom = node.frame.maxY
        hidesAny = true
        stale(at: range.lowerBound + cut.nextLineStart)
        // The time stays where the whole plan puts it (not below the cut), so the row doesn't shrink when the last
        // line shows.
      } else if case var .table(table) = node.kind, count < (Self.source(of: node)?.upperBound ?? 0),
                let cut = tableFrontier(of: table, frame: node.frame, count: count)
      {
        // A row at a time: the rows whose first cell has started.
        table.cells = cut.cells
        node.kind = .table(table)
        node.frame.size.height = cut.height
        bottom = node.frame.maxY
        hidesAny = true
        if let next = cut.nextRowStart { stale(at: next) }
        // The time stays where the whole plan puts it, as for code.
      }
      kept.append(node)
      bottoms.append(bottom)
    }
    guard hidesAny else { return nil }

    // Quotes end under their revealed children; inner quotes first, so outer ones see them.
    for index in kept.indices.reversed() {
      guard case .quote = kept[index].kind else { continue }
      let prefix = kept[index].path.components
      var inner = kept[index].frame.minY
      for child in kept.indices where child != index && kept[child].path.components.starts(with: prefix) {
        inner = max(inner, bottoms[child])
      }
      let inset = RichBlockQuoteMetrics(baseFontSize: baseFontSize).verticalInset
      let height = min(kept[index].frame.height, max(1, inner + inset - kept[index].frame.minY))
      kept[index].frame.size.height = ceil(height)
      bottoms[index] = kept[index].frame.maxY
    }

    var result = self
    result.nodes = kept
    // The room below the content, as the planner leaves it when the last block shown is the last block: the whole
    // plan's room when it is (it may be cut short), otherwise the edge room a filled block (code, quote) closing the
    // message gets, or none. Taking the whole plan's room for an earlier block shrank the row by that room when a
    // later block (a table after code) arrived still hidden.
    let rootPath = { (node: Node) in Array(node.path.components.prefix(1)) }
    let trailing: CGFloat
    if let last = kept.last, let wholeLast = nodes.last, rootPath(last) == rootPath(wholeLast) {
      trailing = max(0, size.height - (nodes.map(\.frame.maxY).max() ?? size.height))
    } else if let last = kept.last, let root = kept.first(where: { $0.path.components == rootPath(last) }),
              Self.closesWithEdgeRoom(root)
    {
      trailing = ChatTypography.space(.bubbleEdge, at: baseFontSize)
    } else {
      trailing = 0
    }
    result.size.height = min(size.height, ceil(max(1, bottoms.max() ?? 0) + trailing))
    result.revealLimit = limit
    // The time sits inline after the last line only when the revealed part ends on the plan's own last line (as it
    // will once everything shows); below the revealed text otherwise. The row then never shrinks as streaming starts.
    if kept.last?.path != nodes.last?.path || !lastKeptEndsWhole { result.trailingTextLine = nil }
    return result
  }

  /// A streaming code block's text up to the end of the line (by line breaks; a wrapped line shows whole) holding the
  /// next character to reveal, where the next line starts, and the block's height for that text, measured as the
  /// planner measures code. Nil when that line is the last.
  private func codeFrontier(
    of code: CodeNode, frame: CGRect, local: Int, attributedText: NSAttributedString, baseFontSize: CGFloat
  ) -> (length: Int, nextLineStart: Int, height: CGFloat)? {
    let source = attributedText.string as NSString
    guard code.rangeOffset >= 0, code.rangeLength > 0, code.rangeOffset + code.rangeLength <= source.length
    else { return nil }
    let body = source.substring(with: NSRange(location: code.rangeOffset, length: code.rangeLength)) as NSString
    let line = body.lineRange(for: NSRange(location: min(max(0, local), body.length - 1), length: 0))
    let nextLineStart = NSMaxRange(line)
    guard nextLineStart < body.length else { return nil }
    // Without the line's own break, so no empty line shows under it.
    var length = nextLineStart
    while length > line.location, let scalar = UnicodeScalar(body.character(at: length - 1)),
          CharacterSet.newlines.contains(scalar)
    {
      length -= 1
    }
    let paragraph = NSMutableParagraphStyle()
    paragraph.baseWritingDirection = .leftToRight
    paragraph.alignment = .left
    let shown = NSAttributedString(
      string: body.substring(to: length),
      attributes: [.font: RichBlockCodeMetrics.bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    )
    let hasLanguage = code.language != nil
    let bodyWidth = RichBlockCodeMetrics.bodyWidth(
      containerWidth: frame.width, gutterWidth: code.gutterWidth, hasLanguage: hasLanguage
    )
    let measured = RichBlockLayoutPlanner.Builder.layoutText(
      shown, width: max(1, bodyWidth), singleLine: false, boundingHeight: true
    )
    let bodyHeight = max(measured.height, ceil(baseFontSize * 1.25))
    let height = min(frame.height, RichBlockCodeMetrics.totalHeight(bodyHeight: bodyHeight, hasLanguage: hasLanguage))
    return (length, nextLineStart, height)
  }

  /// A streaming table's rows above the first row whose first character isn't revealed yet (rows without text show
  /// with the rows above them), the table's height down to the last of them (keeping the planner's room below the
  /// cells), and the count at which that row starts. Nil when every row has started.
  private func tableFrontier(
    of table: TableNode, frame: CGRect, count: Int
  ) -> (cells: [TableNode.Cell], height: CGFloat, nextRowStart: Int?)? {
    for top in Set(table.cells.map(\.frame.minY)).sorted() {
      guard let first = table.cells.filter({ $0.frame.minY == top && $0.rangeLength > 0 }).map(\.rangeOffset).min(),
            count < first + 1
      else { continue }
      let cells = table.cells.filter { $0.frame.minY < top }
      guard !cells.isEmpty else { return nil }
      let cellsBottom = table.cells.map(\.frame.maxY).max() ?? frame.height
      let room = max(0, frame.height - cellsBottom)
      let height = min(frame.height, ceil((cells.map(\.frame.maxY).max() ?? 0) + room))
      return (cells, max(1, height), first + 1)
    }
    return nil
  }

  /// The frontier of a text node drawn in a layer: the bottom of the line holding the next character to reveal (in
  /// the plan's coordinates) and, unless it is the last line, the count within the node where it ends. Nil for text
  /// drawn by TextKit, which shows whole.
  private func frontier(
    of text: TextNode, frame: CGRect, local: Int, attributedText: NSAttributedString, baseFontSize: CGFloat
  ) -> (bottom: CGFloat, lineEnd: Int?)? {
    guard let styled = RichBlockLayoutPlanner.styledText(
      attributedText, offset: text.rangeOffset, length: text.rangeLength, role: text.role,
      baseFontSize: baseFontSize, isRTL: text.isRTL, math: mathSnapshot, maximumWidth: frame.width
    ), RichBlockLayerText.draws(styled, singleLine: false) else { return nil }
    // The node is its widest line wide (plus any inset), and a layout is reused for any width down to its widest line:
    // this is the layout the planner measured and the layer draws.
    let layout = CoreTextMessageText.layout(styled, isRtl: RichBlockLayerText.isRtl(styled), width: frame.width)
    guard layout.lineCount > 0 else { return nil }
    let measured = max(ceil(layout.size.height), ceil(baseFontSize * 1.25))
    let inset = max(0, (frame.height - measured) / 2)
    let line = layout.lines.firstIndex { NSMaxRange($0.range) > max(0, local) } ?? layout.lineCount - 1
    // On the node's last line the node keeps its planned bottom (its own rounding and minimum height), so the row
    // doesn't step by a point when the frontier enters the node or the stream ends.
    guard line < layout.lineCount - 1 else { return (frame.maxY, nil) }
    // Never shorter than a one-line node (the planner's minimum line height): a paragraph that wraps to a second line
    // would otherwise drop by a point as its first line ends.
    let bottom = min(
      frame.maxY,
      max(frame.minY + ceil(baseFontSize * 1.25), frame.minY + inset + ceil(layout.lines[line].frame.maxY))
    )
    return (bottom, NSMaxRange(layout.lines[line].range))
  }
}
