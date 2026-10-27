import CoreGraphics
import Foundation

/// Places rich content inside a width. Pure and thread-safe, like `MessageLayoutPlanner`.
///
/// Blocks stack vertically. Lists put markers in a column, quotes inset their children, code
/// and tables span the width and scroll sideways, images keep their aspect, and disclosures
/// show their children only when expanded. Returns nil for content past the limits; the host
/// then shows the plain text.
public enum RichLayoutPlanner {
  public static func layout(
    _ blocks: [RichBlock],
    maximumWidth: CGFloat,
    grid: PixelGrid,
    layoutDirection: TextDirection = .leftToRight,
    metrics: RichLayoutMetrics = .init(),
    cache: TextLayoutCache? = nil
  ) -> RichLayout? {
    guard !blocks.isEmpty, maximumWidth.isFinite, maximumWidth >= 1 else { return nil }
    var builder = Builder(metrics: metrics, grid: grid, fallbackDirection: layoutDirection, cache: cache)
    guard builder.layout(blocks, parent: RichPath(), x: 0, width: maximumWidth, depth: 0, isRightToLeft: false) else {
      return nil
    }
    return builder.finish(maximumWidth: maximumWidth)
  }
}

private struct Builder {
  /// How a node follows the content's final width when it is narrower than the maximum.
  enum Anchor {
    case leading
    /// Right-to-left content hugs the trailing edge.
    case trailing
    /// Quotes and separators span the content.
    case stretch
  }

  let metrics: RichLayoutMetrics
  let grid: PixelGrid
  let fallbackDirection: TextDirection
  let cache: TextLayoutCache?

  var nodes: [RichLayout.Placed] = []
  var anchors: [Anchor] = []
  var y: CGFloat = 0
  var measuredMaxX: CGFloat = 0
  var claimsMaximumWidth = false
  /// Index of a root paragraph that ends the content, for the inline time.
  var trailingTextIndex: Int?
  var tableCells = 0

  init(metrics: RichLayoutMetrics, grid: PixelGrid, fallbackDirection: TextDirection, cache: TextLayoutCache?) {
    self.metrics = metrics
    self.grid = grid
    self.fallbackDirection = fallbackDirection
    self.cache = cache
  }

  // MARK: - Measuring

  func typeset(_ text: MessageText, width: CGFloat, isRightToLeft: Bool) -> TextLayout {
    let style = TextLayoutStyle(fallbackDirection: isRightToLeft ? .rightToLeft : fallbackDirection)
    if let cache {
      return cache.layout(text, style: style, maximumWidth: width, grid: grid)
    }
    return TextLayouter.layout(text, style: style, maximumWidth: width, grid: grid)
  }

  func unbounded(_ text: MessageText) -> TextLayout {
    typeset(text, width: .greatestFiniteMagnitude, isRightToLeft: false)
  }

  mutating func append(_ path: RichPath, _ frame: CGRect, _ node: RichLayout.Node, anchor: Anchor) -> Bool {
    guard nodes.count < metrics.maximumNodes else { return false }
    nodes.append(.init(path: path, frame: frame, node: node))
    anchors.append(anchor)
    trailingTextIndex = nil
    return true
  }

  mutating func record(_ frame: CGRect) {
    measuredMaxX = max(measuredMaxX, frame.maxX)
  }

  // MARK: - Blocks

  mutating func layout(
    _ blocks: [RichBlock],
    parent: RichPath,
    x: CGFloat,
    width: CGFloat,
    depth: Int,
    isRightToLeft: Bool,
    insideListItem: Bool = false
  ) -> Bool {
    guard depth <= metrics.maximumDepth else { return false }
    for (index, block) in blocks.enumerated() {
      if index == 0 {
        if case .heading = block.textRole {
          y += parent.components.isEmpty ? 6 : 4
        }
      } else {
        if case .list = block, insideListItem {
          y += metrics.listItemSpacing
        } else {
          y += metrics.blockSpacing
        }
        if case let .heading(level) = block.textRole {
          y += level <= 2 ? metrics.majorHeadingSpacing : metrics.minorHeadingSpacing
        }
      }
      let path = parent.appending(index)
      guard layout(block, path: path, x: x, width: width, depth: depth, isRightToLeft: isRightToLeft) else {
        return false
      }
    }
    return true
  }

  mutating func layout(
    _ block: RichBlock,
    path: RichPath,
    x: CGFloat,
    width: CGFloat,
    depth: Int,
    isRightToLeft: Bool
  ) -> Bool {
    switch block {
    case let .text(text, role):
      return appendText(text, role: role, path: path, x: x, width: width, isRightToLeft: isRightToLeft, depth: depth)
    case let .list(list):
      return layout(list: list, path: path, x: x, width: width, depth: depth + 1)
    case let .quote(children, quoteIsRightToLeft):
      return layout(quote: children, path: path, x: x, width: width, depth: depth + 1, isRightToLeft: quoteIsRightToLeft)
    case let .code(code):
      return appendCode(code, path: path, x: x, width: width)
    case let .table(table):
      return appendTable(table, path: path, x: x, width: width)
    case .separator:
      let frame = CGRect(x: x, y: y + metrics.separatorMargin, width: width, height: 1)
      guard append(path, frame, .separator, anchor: .stretch) else { return false }
      record(CGRect(x: x, y: frame.minY, width: min(width, 120), height: 1))
      y = frame.maxY + metrics.separatorMargin
      return true
    case let .image(image):
      let size = imageSize(image.size, width: width)
      let frame = CGRect(x: isRightToLeft ? x + width - size.width : x, y: y, width: size.width, height: size.height)
      guard append(path, frame, .image(id: image.id), anchor: isRightToLeft ? .trailing : .leading) else { return false }
      record(frame)
      y = frame.maxY
      return true
    case let .album(images):
      return appendAlbum(images, path: path, x: x, width: width)
    case let .disclosure(disclosure):
      return layout(disclosure: disclosure, path: path, x: x, width: width, depth: depth + 1)
    }
  }

  mutating func appendText(
    _ text: MessageText,
    role: RichTextRole,
    path: RichPath,
    x: CGFloat,
    width: CGFloat,
    isRightToLeft: Bool,
    depth: Int
  ) -> Bool {
    let layout = typeset(text, width: width, isRightToLeft: isRightToLeft)
    let trailing = layout.lines.first?.direction == .rightToLeft
    let aligned = layout.aligned(toWidth: layout.size.width)
    let frame = CGRect(
      x: trailing ? x + width - aligned.size.width : x,
      y: y,
      width: aligned.size.width,
      height: aligned.size.height
    )
    guard append(path, frame, .text(aligned, role: role), anchor: trailing ? .trailing : .leading) else { return false }
    record(frame)
    y = frame.maxY
    // A paragraph at the root that ends the content can carry the time on its last line.
    if depth == 0 {
      trailingTextIndex = nodes.count - 1
    }
    return true
  }

  mutating func layout(list: RichList, path: RichPath, x: CGFloat, width: CGFloat, depth: Int) -> Bool {
    guard depth <= metrics.maximumDepth, !list.items.isEmpty else { return false }
    let isRightToLeft = list.isRightToLeft
    let markers = list.items.map { unbounded($0.marker) }
    let widestMarker = markers.map(\.size.width).max() ?? 0
    let markerWidth = grid.ceil(max(metrics.unorderedMarkerWidth, widestMarker + metrics.listMarkerGap))
    let isNested = depth > 1
    let inset = metrics.listLeadingInset + (isNested ? metrics.nestedListIndent : 0)
    let listX = isRightToLeft ? x : x + inset
    let listWidth = max(1, width - inset)
    let childWidth = max(1, listWidth - markerWidth)
    for (index, item) in list.items.enumerated() {
      if index > 0 { y += metrics.listItemSpacing }
      let itemPath = path.appending(index)
      let marker = markers[index]
      let markerFrame = CGRect(
        x: isRightToLeft ? listX + childWidth + markerWidth - marker.size.width : listX,
        y: y,
        width: marker.size.width,
        height: marker.size.height
      )
      guard append(itemPath.appending(-1), markerFrame, .marker(marker), anchor: isRightToLeft ? .trailing : .leading) else {
        return false
      }
      record(markerFrame)
      let itemTop = y
      if item.children.isEmpty {
        y = markerFrame.maxY
        continue
      }
      guard layout(
        item.children,
        parent: itemPath,
        x: isRightToLeft ? listX : listX + markerWidth,
        width: childWidth,
        depth: depth,
        isRightToLeft: isRightToLeft,
        insideListItem: true
      ) else { return false }
      y = max(y, itemTop + marker.size.height)
    }
    return true
  }

  mutating func layout(
    quote children: [RichBlock],
    path: RichPath,
    x: CGFloat,
    width: CGFloat,
    depth: Int,
    isRightToLeft: Bool
  ) -> Bool {
    guard !children.isEmpty else { return false }
    let top = y
    guard append(path, CGRect(x: x, y: top, width: width, height: 0), .quote(isRightToLeft: isRightToLeft), anchor: .stretch) else {
      return false
    }
    let decoration = nodes.count - 1
    y += metrics.quoteVerticalInset
    let leading = isRightToLeft ? metrics.quoteTrailingInset : metrics.quoteLeadingInset
    let trailing = isRightToLeft ? metrics.quoteLeadingInset : metrics.quoteTrailingInset
    let before = measuredMaxX
    measuredMaxX = 0
    guard layout(
      children,
      parent: path,
      x: x + leading,
      width: max(1, width - leading - trailing),
      depth: depth,
      isRightToLeft: isRightToLeft
    ) else { return false }
    measuredMaxX = max(before, measuredMaxX + trailing)
    y += metrics.quoteVerticalInset
    nodes[decoration].frame.size.height = max(1, y - top)
    trailingTextIndex = nil
    return true
  }

  mutating func appendCode(_ code: RichCode, path: RichPath, x: CGFloat, width: CGFloat) -> Bool {
    let text = unbounded(code.text)
    let lineNumbers = code.lineNumbers.map(unbounded)
    let label = code.languageLabel.map(unbounded)
    let gutter = lineNumbers.map { $0.size.width + metrics.codeGutterTrailingInset } ?? 0
    let gap = gutter > 0 ? metrics.codeGutterGap : 0
    let header = label == nil ? 0 : metrics.codeHeaderHeight
    let bodyTop = header + (label == nil ? metrics.codeBodyTopInset : metrics.codeHeaderBodyTopInset)
    let height = grid.ceil(bodyTop + max(text.size.height, lineNumbers?.size.height ?? 0) + metrics.codeBodyBottomInset)
    let frame = CGRect(x: x, y: y, width: width, height: height)
    let node = RichLayout.Code(
      text: text,
      textOrigin: CGPoint(x: metrics.codeHorizontalInset + gutter + gap, y: bodyTop),
      lineNumbers: lineNumbers,
      lineNumbersOrigin: CGPoint(x: metrics.codeHorizontalInset, y: bodyTop),
      languageLabel: label,
      languageLabelOrigin: CGPoint(x: metrics.codeHorizontalInset, y: grid.round((header - (label?.size.height ?? 0)) / 2)),
      language: code.language,
      contentWidth: grid.ceil(max(width, metrics.codeHorizontalInset * 2 + gutter + gap + text.size.width))
    )
    guard append(path, frame, .code(node), anchor: .stretch) else { return false }
    claimsMaximumWidth = true
    y = frame.maxY
    return true
  }

  mutating func appendTable(_ table: RichTable, path: RichPath, x: CGFloat, width: CGFloat) -> Bool {
    guard let columns = table.rows.first?.count, columns > 0,
          table.rows.allSatisfy({ $0.count == columns })
    else { return false }
    tableCells += columns * table.rows.count
    guard tableCells <= metrics.maximumTableCells else { return false }
    let padding = metrics.tableHorizontalPadding
    var minimum = Array(repeating: CGFloat(1), count: columns)
    var maximum = Array(repeating: CGFloat(1), count: columns)
    for row in table.rows {
      for (column, cell) in row.enumerated() {
        let natural = unbounded(cell).size.width
        let word = widestWord(cell)
        let low = ceil(word + padding * 2)
        let high = max(low, min(max(1, width), ceil(natural) + padding * 2))
        minimum[column] = max(minimum[column], low)
        maximum[column] = max(maximum[column], high)
      }
    }
    let widths = Self.allocateColumns(minimum: minimum, maximum: maximum, viewport: width)

    var cells: [RichLayout.Table.Cell] = []
    var rowY: CGFloat = 0
    let contentWidth = widths.reduce(0, +)
    for (rowIndex, row) in table.rows.enumerated() {
      let texts = row.enumerated().map { column, cell in
        typeset(cell, width: max(1, widths[column] - padding * 2), isRightToLeft: table.isRightToLeft)
      }
      let rowHeight = grid.ceil(max(
        metrics.tableMinimumRowHeight,
        (texts.map(\.size.height).max() ?? 0) + metrics.tableVerticalPadding * 2
      ))
      var cellX: CGFloat = 0
      for (column, text) in texts.enumerated() {
        let cellWidth = widths[column]
        // Right-to-left tables put the first column on the right.
        let x = table.isRightToLeft ? contentWidth - cellX - cellWidth : cellX
        let inner = cellWidth - padding * 2
        let alignment = column < table.alignments.count ? table.alignments[column] : .leading
        let offset: CGFloat = switch (alignment, table.isRightToLeft) {
        case (.center, _): (inner - text.size.width) / 2
        case (.trailing, false), (.leading, true): inner - text.size.width
        default: 0
        }
        let frame = CGRect(x: x, y: rowY, width: cellWidth, height: rowHeight)
        cells.append(.init(
          row: rowIndex,
          column: column,
          frame: frame,
          text: text.aligned(toWidth: text.size.width),
          textFrame: grid.round(CGRect(
            x: x + padding + max(0, offset),
            y: rowY + (rowHeight - text.size.height) / 2,
            width: text.size.width,
            height: text.size.height
          )),
          isHeader: rowIndex == 0
        ))
        cellX += cellWidth
      }
      rowY += rowHeight
    }
    let frame = CGRect(x: x, y: y, width: width, height: rowY)
    let node = RichLayout.Table(cells: cells, contentSize: CGSize(width: contentWidth, height: rowY), isRightToLeft: table.isRightToLeft)
    guard append(path, frame, .table(node), anchor: .stretch) else { return false }
    claimsMaximumWidth = true
    y = frame.maxY
    return true
  }

  /// The widest run between whitespace: a column can't be narrower without breaking a word.
  func widestWord(_ text: MessageText) -> CGFloat {
    let string = text.attributedString.string as NSString
    var widest: CGFloat = 0
    var location = 0
    while location < string.length {
      let space = string.rangeOfCharacter(from: .whitespacesAndNewlines, options: [], range: NSRange(location: location, length: string.length - location))
      let end = space.location == NSNotFound ? string.length : space.location
      if end > location {
        let word = MessageText(text.attributedString.attributedSubstring(from: NSRange(location: location, length: end - location)))
        widest = max(widest, unbounded(word).size.width)
      }
      location = space.location == NSNotFound ? string.length : space.location + max(1, space.length)
    }
    return widest
  }

  /// Column widths between each column's minimum and maximum, sharing spare width by how much
  /// each column wants.
  static func allocateColumns(minimum: [CGFloat], maximum: [CGFloat], viewport: CGFloat) -> [CGFloat] {
    let low = zip(minimum, maximum).map { min($0, $1) }
    let high = zip(low, maximum).map { max($0, $1) }
    let lowTotal = low.reduce(0, +)
    let highTotal = high.reduce(0, +)
    if lowTotal >= viewport { return low }
    var widths: [CGFloat]
    var spare: CGFloat
    var weights: [CGFloat]
    if highTotal <= viewport {
      widths = high
      spare = viewport - highTotal
      weights = high
    } else {
      widths = low
      spare = viewport - lowTotal
      weights = zip(low, high).map { max(0, $1 - $0) }
    }
    var remaining = weights.reduce(0, +)
    for index in widths.indices {
      let growth: CGFloat = if remaining > 0 {
        weights[index] == remaining ? spare : floor(spare * weights[index] / remaining)
      } else {
        floor(spare / CGFloat(widths.count - index))
      }
      widths[index] += max(0, growth)
      spare -= max(0, growth)
      remaining -= weights[index]
    }
    if spare > 0, let last = widths.indices.last { widths[last] += spare }
    return widths
  }

  func imageSize(_ natural: CGSize?, width: CGFloat) -> CGSize {
    let limit = CGSize(width: min(width, metrics.maximumImageSide), height: metrics.maximumImageSide)
    let natural = natural.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? CGSize(width: 240, height: 180)
    let scale = min(1, limit.width / natural.width, limit.height / natural.height)
    return CGSize(width: max(1, grid.floor(natural.width * scale)), height: max(1, grid.floor(natural.height * scale)))
  }

  mutating func appendAlbum(_ images: [RichImage], path: RichPath, x: CGFloat, width: CGFloat) -> Bool {
    guard !images.isEmpty, images.count <= 10 else { return false }
    var itemX: CGFloat = 0
    var items: [RichLayout.AlbumItem] = []
    for image in images {
      let ratio = image.size.flatMap { $0.width > 0 && $0.height > 0 ? $0.width / $0.height : nil } ?? 4 / 3
      let itemWidth = grid.round(min(max(96, metrics.albumHeight * min(max(ratio, 0.2), 5)), 220))
      items.append(.init(id: image.id, frame: CGRect(x: itemX, y: 0, width: itemWidth, height: metrics.albumHeight)))
      itemX += itemWidth + metrics.albumItemSpacing
    }
    let frame = CGRect(x: x, y: y, width: width, height: metrics.albumHeight)
    guard append(path, frame, .album(items), anchor: .stretch) else { return false }
    claimsMaximumWidth = true
    y = frame.maxY
    return true
  }

  mutating func layout(disclosure: RichDisclosure, path: RichPath, x: CGFloat, width: CGFloat, depth: Int) -> Bool {
    let m = metrics
    let summary = typeset(disclosure.summary, width: .greatestFiniteMagnitude, isRightToLeft: disclosure.isRightToLeft)
    let activity = disclosure.hasActivityIcon ? m.disclosureActivitySide + m.disclosureActivityGap : 0
    let viewport = max(1, width - m.disclosureChevronSide - m.disclosureChevronGap - activity)
    let titleWidth = min(summary.lines.first?.width ?? 0, viewport)
    let height = max(summary.lines.first?.frame.height ?? 0, m.disclosureChevronSide)
    let nodeWidth = grid.ceil(activity + titleWidth + m.disclosureChevronGap + m.disclosureChevronSide)
    let rtl = disclosure.isRightToLeft
    // Activity icon, title, chevron in reading order; mirrored for right-to-left.
    func place(_ minX: CGFloat, _ itemWidth: CGFloat, _ itemHeight: CGFloat) -> CGRect {
      CGRect(x: rtl ? nodeWidth - minX - itemWidth : minX, y: (height - itemHeight) / 2, width: itemWidth, height: itemHeight)
    }
    let node = RichLayout.Disclosure(
      summary: summary,
      titleFrame: grid.round(place(activity, titleWidth, summary.lines.first?.frame.height ?? height)),
      chevronFrame: grid.round(place(activity + titleWidth + m.disclosureChevronGap, m.disclosureChevronSide, m.disclosureChevronSide)),
      activityFrame: disclosure.hasActivityIcon ? grid.round(place(0, m.disclosureActivitySide, m.disclosureActivitySide)) : nil,
      isExpanded: disclosure.isExpanded,
      isInProgress: disclosure.isInProgress
    )
    let frame = CGRect(x: rtl ? x + width - nodeWidth : x, y: y, width: nodeWidth, height: grid.ceil(height))
    guard append(path, frame, .disclosure(node), anchor: rtl ? .trailing : .leading) else { return false }
    record(frame)
    y = frame.maxY
    guard disclosure.isExpanded, !disclosure.children.isEmpty else { return true }
    y += m.blockSpacing
    return layout(disclosure.children, parent: path, x: x, width: width, depth: depth, isRightToLeft: rtl)
  }

  // MARK: - Finishing

  /// Shrinks to the widest content unless a block spans the width, moves trailing-anchored
  /// nodes with the edge, and snaps everything to pixels.
  mutating func finish(maximumWidth: CGFloat) -> RichLayout {
    let width = claimsMaximumWidth ? maximumWidth : min(maximumWidth, max(1, grid.ceil(measuredMaxX)))
    let shift = maximumWidth - width
    if shift > 0 {
      for index in nodes.indices {
        switch anchors[index] {
        case .leading: break
        case .trailing: nodes[index].frame.origin.x -= shift
        case .stretch: nodes[index].frame.size.width = max(1, nodes[index].frame.width - shift)
        }
      }
    }
    for index in nodes.indices {
      nodes[index].frame = grid.round(nodes[index].frame)
    }
    var trailingLine: RichLayout.TrailingLine?
    if let index = trailingTextIndex, index == nodes.count - 1,
       case let .text(text, _) = nodes[index].node, let line = text.lastLine
    {
      let frame = nodes[index].frame
      trailingLine = .init(maxX: frame.minX + line.frame.maxX, baseline: frame.minY + line.baseline, direction: line.direction)
    }
    return RichLayout(size: CGSize(width: width, height: grid.ceil(y)), nodes: nodes, trailingLine: trailingLine)
  }
}

private extension RichBlock {
  var textRole: RichTextRole? {
    if case let .text(_, role) = self { return role }
    return nil
  }
}
