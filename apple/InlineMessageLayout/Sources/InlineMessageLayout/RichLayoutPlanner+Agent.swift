import CoreGraphics
import Foundation

/// Parts of one agent block in its node's coordinates, placed left to right and mirrored for
/// right-to-left blocks when finished.
private struct CardParts {
  var parts: [RichLayout.Card.Part] = []
  /// Parts that keep their place in a right-to-left block, such as a command's text.
  var unmirrored: Set<Int> = []

  mutating func add(_ kind: RichLayout.Card.Part.Kind, _ frame: CGRect, tap: RichTap? = nil, mirrors: Bool = true) {
    if !mirrors { unmirrored.insert(parts.count) }
    parts.append(.init(kind: kind, frame: frame, tap: tap))
  }

  func finished(width: CGFloat, isRightToLeft: Bool, grid: PixelGrid) -> [RichLayout.Card.Part] {
    parts.enumerated().map { index, part in
      var part = part
      if isRightToLeft, !unmirrored.contains(index) {
        part.frame.origin.x = width - part.frame.maxX
      }
      part.frame = grid.round(part.frame)
      return part
    }
  }
}

extension RichBuilder {
  // MARK: - Measuring

  /// Text wrapped to `width`, its lines on its own leading edge.
  func wrapped(_ text: MessageText, width: CGFloat, isRightToLeft: Bool) -> TextLayout {
    let layout = typeset(text, width: max(1, width), isRightToLeft: isRightToLeft)
    return layout.aligned(toWidth: layout.size.width)
  }

  /// At most `lines` lines; the last ends in an ellipsis when the text goes on.
  func clamped(_ text: MessageText, width: CGFloat, lines limit: Int, isRightToLeft: Bool) -> TextLayout {
    let full = wrapped(text, width: width, isRightToLeft: isRightToLeft)
    guard limit > 0, full.lineCount > limit else { return full }
    let attributed = text.attributedString
    let string = attributed.string as NSString
    let last = full.lines[limit - 1].range
    let style = TextLayoutStyle(fallbackDirection: isRightToLeft ? .rightToLeft : fallbackDirection)
    func candidate(_ cut: Int) -> TextLayout {
      var end = cut
      while end > 0, let scalar = Unicode.Scalar(string.character(at: end - 1)),
            CharacterSet.whitespacesAndNewlines.contains(scalar)
      {
        end -= 1
      }
      let value = NSMutableAttributedString(attributedString: attributed.attributedSubstring(from: NSRange(location: 0, length: end)))
      let attributes = end > 0 ? attributed.attributes(at: end - 1, effectiveRange: nil) : [:]
      value.append(NSAttributedString(string: "\u{2026}", attributes: attributes))
      let layout = TextLayouter.layout(MessageText(value), style: style, maximumWidth: max(1, width), grid: grid)
      return layout.aligned(toWidth: layout.size.width)
    }
    var boundaries: [Int] = []
    var index = last.location
    while index < NSMaxRange(last) {
      index = NSMaxRange(string.rangeOfComposedCharacterSequence(at: index))
      boundaries.append(index)
    }
    var best = candidate(last.location)
    var low = 0
    var high = boundaries.count - 1
    while low <= high {
      let middle = (low + high) / 2
      let layout = candidate(boundaries[middle])
      if layout.lineCount <= limit {
        best = layout
        low = middle + 1
      } else {
        high = middle - 1
      }
    }
    return best
  }

  /// A glyph as tall as a line of text, within reason.
  func symbolSide(forLineHeight height: CGFloat) -> CGFloat {
    grid.round(min(max(height * 0.88, 14), 30))
  }

  func firstLineHeight(_ layout: TextLayout) -> CGFloat {
    layout.lines.first?.frame.height ?? layout.size.height
  }

  func chipSize(_ chip: RichChip) -> (TextLayout, CGSize) {
    let m = metrics
    let text = unbounded(chip.text)
    let symbol = chip.symbol == nil ? 0 : grid.round(text.size.height * 0.85) + m.chipSymbolGap
    return (text, CGSize(
      width: grid.ceil(m.chipHorizontalPadding * 2 + symbol + text.size.width),
      height: grid.ceil(text.size.height + m.chipVerticalPadding * 2)
    ))
  }

  /// Buttons in one row of equal widths when they fit, otherwise one per row, full width.
  /// Returns the parts' frames from `top` and the height they take.
  func buttonFrames(_ buttons: [RichButton], top: CGFloat, width: CGFloat) -> ([(RichButton, TextLayout, CGRect)], CGFloat) {
    guard !buttons.isEmpty else { return ([], 0) }
    let m = metrics
    let titles = buttons.map { singleLine($0.title, width: max(1, width - m.buttonHorizontalPadding * 2), isRightToLeft: false) }
    let height = grid.ceil(max(
      m.buttonMinimumHeight,
      (titles.map(\.size.height).max() ?? 0) + m.buttonVerticalPadding * 2
    ))
    let count = CGFloat(buttons.count)
    let equal = grid.floor((width - m.buttonSpacing * (count - 1)) / count)
    let widest = titles.map { $0.size.width + m.buttonHorizontalPadding * 2 }.max() ?? 0
    var result: [(RichButton, TextLayout, CGRect)] = []
    if widest <= equal {
      for (index, button) in buttons.enumerated() {
        let x = CGFloat(index) * (equal + m.buttonSpacing)
        // The last button takes what rounding left.
        let w = index == buttons.count - 1 ? width - x : equal
        result.append((button, titles[index], CGRect(x: x, y: top, width: w, height: height)))
      }
      return (result, height)
    }
    var y = top
    for (index, button) in buttons.enumerated() {
      if index > 0 { y += m.buttonSpacing }
      result.append((button, titles[index], CGRect(x: 0, y: y, width: width, height: height)))
      y += height
    }
    return (result, y - top)
  }

  /// Adds buttons, or the line that replaced them, from `top`; returns the height used.
  private func appendActions(
    _ buttons: [RichButton],
    status: RichStatusLine?,
    to parts: inout CardParts,
    x: CGFloat,
    top: CGFloat,
    width: CGFloat,
    isRightToLeft: Bool
  ) -> CGFloat {
    if let status {
      return appendStatusLine(status, to: &parts, x: x, top: top, width: width, isRightToLeft: isRightToLeft)
    }
    let (placed, height) = buttonFrames(buttons, top: top, width: width)
    for (button, title, frame) in placed {
      parts.add(.button(title, style: button.style), frame.offsetBy(dx: x, dy: 0), tap: button.tap)
    }
    return height
  }

  private func appendStatusLine(
    _ line: RichStatusLine,
    to parts: inout CardParts,
    x: CGFloat,
    top: CGFloat,
    width: CGFloat,
    isRightToLeft: Bool
  ) -> CGFloat {
    let probe = unbounded(line.text)
    let side = line.symbol == nil ? 0 : symbolSide(forLineHeight: firstLineHeight(probe)) * 0.9
    let gap = side > 0 ? metrics.symbolGap * 0.75 : 0
    let text = wrapped(line.text, width: width - side - gap, isRightToLeft: isRightToLeft)
    let height = max(text.size.height, side)
    if line.tap != nil {
      parts.add(.row, CGRect(x: x - 6, y: top - 4, width: min(width + 12, side + gap + text.size.width + 12), height: height + 8), tap: line.tap)
    }
    if let symbol = line.symbol {
      let lineHeight = firstLineHeight(text)
      parts.add(.symbol(symbol), CGRect(x: x, y: top + (lineHeight - side) / 2, width: side, height: side))
    }
    parts.add(.text(text), CGRect(x: x + side + gap, y: top, width: text.size.width, height: text.size.height))
    return height
  }

  /// A header: glyph, title that wraps, and a chip at the trailing edge on the first line.
  /// Returns the height used.
  private func appendHeader(
    symbol: RichSymbol?,
    title: MessageText,
    chip: RichChip?,
    to parts: inout CardParts,
    x: CGFloat,
    top: CGFloat,
    width: CGFloat,
    isRightToLeft: Bool
  ) -> CGFloat {
    let probe = unbounded(title)
    let side = symbol == nil ? 0 : symbolSide(forLineHeight: firstLineHeight(probe))
    let gap = side > 0 ? metrics.symbolGap : 0
    let chipLayout = chip.map(chipSize)
    let chipRoom = chipLayout.map { $0.1.width + metrics.symbolGap } ?? 0
    let text = wrapped(title, width: width - side - gap - chipRoom, isRightToLeft: isRightToLeft)
    let lineHeight = firstLineHeight(text)
    if let symbol {
      parts.add(.symbol(symbol), CGRect(x: x, y: top + (lineHeight - side) / 2, width: side, height: side))
    }
    parts.add(.text(text), CGRect(x: x + side + gap, y: top, width: text.size.width, height: text.size.height))
    var height = max(text.size.height, side)
    if let chip, let (chipText, size) = chipLayout {
      let frame = CGRect(x: x + width - size.width, y: top + (lineHeight - size.height) / 2, width: size.width, height: size.height)
      parts.add(.chip(chipText, tone: chip.tone, symbol: chip.symbol), frame)
      height = max(height, frame.maxY - top)
    }
    return height
  }

  /// A "Show full plan" row: the label and a chevron, tappable as one.
  private func appendToggle(
    _ toggle: RichToggle,
    to parts: inout CardParts,
    x: CGFloat,
    top: CGFloat,
    width: CGFloat,
    isRightToLeft: Bool
  ) -> CGFloat {
    let text = singleLine(toggle.label, width: width - 20, isRightToLeft: isRightToLeft)
    let lineHeight = firstLineHeight(text)
    let side = grid.round(lineHeight * 0.6)
    let expands = if case let .toggle(_, isExpanded) = toggle.tap { isExpanded } else { true }
    parts.add(.row, CGRect(x: x - 6, y: top - 4, width: text.size.width + 4 + side + 12, height: lineHeight + 8), tap: toggle.tap)
    parts.add(.text(text), CGRect(x: x, y: top, width: text.size.width, height: text.size.height))
    parts.add(
      .symbol(.named(expands ? "chevron.down" : "chevron.up", tone: .accent)),
      CGRect(x: x + text.size.width + 4, y: top + (lineHeight - side) / 2, width: side, height: side)
    )
    return max(text.size.height, lineHeight)
  }

  // MARK: - Card placement

  /// Places a finished card at `top` spanning the width.
  private mutating func appendCard(
    _ style: RichLayout.Card.Style,
    parts: CardParts,
    path: RichPath,
    x: CGFloat,
    top: CGFloat,
    width: CGFloat,
    height: CGFloat,
    isMuted: Bool = false,
    isRightToLeft: Bool
  ) -> Bool {
    let card = RichLayout.Card(
      style: style,
      parts: parts.finished(width: width, isRightToLeft: isRightToLeft, grid: grid),
      isMuted: isMuted,
      isRightToLeft: isRightToLeft,
      hasChildren: false
    )
    let frame = CGRect(x: x, y: top, width: width, height: grid.ceil(height))
    guard append(path, frame, .card(card), anchor: .stretch) else { return false }
    claimsMaximumWidth = true
    y = frame.maxY
    return true
  }

  /// Reserves the node for a card whose children follow it; `finishCard` fills it in.
  private mutating func beginCard(path: RichPath, x: CGFloat, top: CGFloat, width: CGFloat) -> Int? {
    let placeholder = RichLayout.Card(style: .plain, parts: [], isMuted: false, isRightToLeft: false, hasChildren: true)
    guard append(path, CGRect(x: x, y: top, width: width, height: 0), .card(placeholder), anchor: .stretch) else { return nil }
    claimsMaximumWidth = true
    return nodes.count - 1
  }

  private mutating func finishCard(
    at index: Int,
    style: RichLayout.Card.Style,
    parts: CardParts,
    height: CGFloat,
    isRightToLeft: Bool
  ) {
    let width = nodes[index].frame.width
    nodes[index].node = .card(RichLayout.Card(
      style: style,
      parts: parts.finished(width: width, isRightToLeft: isRightToLeft, grid: grid),
      isMuted: false,
      isRightToLeft: isRightToLeft,
      hasChildren: true
    ))
    nodes[index].frame.size.height = grid.ceil(height)
    y = nodes[index].frame.maxY
    trailingTextIndex = nil
  }

  /// Cuts the nodes placed since `start` at `limit`: later nodes leave, text crossing it keeps
  /// the lines above it, and containers end at what is left. Returns the new bottom.
  private mutating func clip(from start: Int, at limit: CGFloat) -> CGFloat {
    var keptNodes: [RichLayout.Placed] = []
    var keptAnchors: [Anchor] = []
    var bottom: CGFloat = 0
    for index in start ..< nodes.count {
      var placed = nodes[index]
      guard placed.frame.minY < limit else { continue }
      if case let .text(text, role) = placed.node, placed.frame.maxY > limit {
        let room = limit - placed.frame.minY
        let count = max(1, text.lines.firstIndex { $0.frame.maxY > room } ?? text.lineCount)
        if count < text.lineCount {
          var cut = text
          cut.lines = Array(text.lines.prefix(count))
          cut.size.height = cut.lines.last?.frame.maxY ?? 0
          placed.node = .text(cut, role: role)
          placed.frame.size.height = cut.size.height
        }
      }
      keptNodes.append(placed)
      keptAnchors.append(anchors[index])
    }
    // Cards without children (steps, fields, reviews…) are leaves here: they keep their
    // height and count toward the bottom. Only containers shrink to what is left in them.
    for placed in keptNodes {
      switch placed.node {
      case .quote: continue
      case let .card(card) where card.hasChildren: continue
      default: bottom = max(bottom, placed.frame.maxY)
      }
    }
    // Quotes and cards around clipped children end under them.
    for index in keptNodes.indices {
      let isContainer = switch keptNodes[index].node {
      case .quote: true
      case let .card(card): card.hasChildren
      default: false
      }
      switch isContainer {
      case true:
        let maxY = min(keptNodes[index].frame.maxY, max(bottom, keptNodes[index].frame.minY + 1))
        keptNodes[index].frame.size.height = maxY - keptNodes[index].frame.minY
      case false: break
      }
    }
    nodes.replaceSubrange(start..., with: keptNodes)
    anchors.replaceSubrange(start..., with: keptAnchors)
    return bottom
  }

  // MARK: - Steps

  mutating func appendSteps(_ steps: RichSteps, path: RichPath, x: CGFloat, width: CGFloat) -> Bool {
    guard !steps.items.isEmpty, steps.items.count <= RichSteps.maximumItems else { return false }
    let m = metrics
    // A plan at the top of a message is a card; nested in other blocks it is a plain list.
    let isCard = path.components.count == 1
    let insetX = isCard ? m.stepsCardHorizontalInset : 0
    let insetY = isCard ? m.stepsCardVerticalInset : 0
    let inner = max(1, width - insetX * 2)
    let rtl = steps.isRightToLeft
    let side = symbolSide(forLineHeight: firstLineHeight(unbounded(steps.items[0].text)))
    let textX = side + m.symbolGap
    let textWidth = max(1, inner - textX)
    var parts = CardParts()
    var cy = insetY
    for (index, item) in steps.items.enumerated() {
      if index > 0 { cy += m.stepSpacing }
      let text = wrapped(item.text, width: textWidth, isRightToLeft: rtl)
      let lineHeight = firstLineHeight(text)
      parts.add(.symbol(.status(item.status ?? .pending)), CGRect(x: insetX, y: cy + (lineHeight - side) / 2, width: side, height: side))
      parts.add(.text(text), CGRect(x: insetX + textX, y: cy, width: text.size.width, height: text.size.height))
      cy += max(text.size.height, side)
      if let detail = item.detail, !detail.isEmpty {
        let layout = wrapped(detail, width: textWidth, isRightToLeft: rtl)
        cy += 1
        parts.add(.text(layout), CGRect(x: insetX + textX, y: cy, width: layout.size.width, height: layout.size.height))
        cy += layout.size.height
      }
    }
    return appendCard(isCard ? .taskList : .plain, parts: parts, path: path, x: x, top: y, width: width, height: cy + insetY, isRightToLeft: rtl)
  }

  // MARK: - Fields

  mutating func appendFields(_ fields: RichFields, path: RichPath, x: CGFloat, width: CGFloat) -> Bool {
    guard !fields.rows.isEmpty, fields.rows.count <= RichFields.maximumRows else { return false }
    let m = metrics
    let rtl = fields.isRightToLeft
    let labels = fields.rows.map { unbounded($0.label) }
    let column = min(grid.ceil(labels.map(\.size.width).max() ?? 0) + 1, max(60, grid.floor(width * 0.36)), 160)
    let valueX = column + m.fieldsLabelGap
    let valueWidth = max(1, width - valueX)
    var parts = CardParts()
    var cy: CGFloat = 0
    var used: CGFloat = 0
    for (index, row) in fields.rows.enumerated() {
      if index > 0 { cy += m.fieldsRowSpacing }
      let label = wrapped(row.label, width: column, isRightToLeft: rtl)
      let value = wrapped(row.value, width: valueWidth, isRightToLeft: rtl)
      parts.add(.text(label), CGRect(x: rtl ? column - label.size.width : 0, y: cy, width: label.size.width, height: label.size.height))
      parts.add(.text(value), CGRect(x: valueX, y: cy, width: value.size.width, height: value.size.height))
      used = max(used, valueX + value.size.width)
      cy += max(label.size.height, value.size.height)
    }
    // Fields hug their content: they never widen the bubble alone.
    let nodeWidth = min(width, grid.ceil(used))
    let card = RichLayout.Card(
      style: .plain,
      parts: parts.finished(width: nodeWidth, isRightToLeft: rtl, grid: grid),
      isMuted: false,
      isRightToLeft: rtl,
      hasChildren: false
    )
    let frame = CGRect(x: rtl ? x + width - nodeWidth : x, y: y, width: nodeWidth, height: grid.ceil(cy))
    guard append(path, frame, .card(card), anchor: rtl ? .trailing : .leading) else { return false }
    record(frame)
    y = frame.maxY
    return true
  }

  // MARK: - Callout

  mutating func layout(callout: RichCallout, path: RichPath, x: CGFloat, width: CGFloat, depth: Int) -> Bool {
    let m = metrics
    let rtl = callout.isRightToLeft
    let top = y
    guard let index = beginCard(path: path, x: x, top: top, width: width) else { return false }
    let probe = callout.title.map { firstLineHeight(unbounded($0)) } ?? 20
    let side = symbolSide(forLineHeight: probe)
    let contentX = m.cardHorizontalInset + side + m.symbolGap
    let contentWidth = max(1, width - m.cardHorizontalInset - contentX)
    var parts = CardParts()
    var cy = m.cardVerticalInset
    var iconY = cy + (probe - side) / 2
    if let title = callout.title, !title.isEmpty {
      let text = wrapped(title, width: contentWidth, isRightToLeft: rtl)
      iconY = cy + (firstLineHeight(text) - side) / 2
      parts.add(.text(text), CGRect(x: contentX, y: cy, width: text.size.width, height: text.size.height))
      cy += text.size.height
      if !callout.children.isEmpty { cy += 4 }
    }
    if !callout.children.isEmpty {
      y = top + cy
      // Children of a right-to-left callout sit left of the mirrored icon.
      guard layout(
        callout.children,
        parent: path,
        x: x + (rtl ? m.cardHorizontalInset : contentX),
        width: contentWidth,
        depth: depth,
        isRightToLeft: rtl
      ) else { return false }
      cy = y - top
      if callout.title == nil, let first = nodes[(index + 1)...].first(where: { if case .text = $0.node { true } else { false } }),
         case let .text(text, _) = first.node
      {
        iconY = first.frame.minY - top + (firstLineHeight(text) - side) / 2
      }
    }
    parts.add(.symbol(.named(callout.symbol, tone: callout.tone)), CGRect(x: m.cardHorizontalInset, y: iconY, width: side, height: side))
    cy = max(cy + m.cardVerticalInset, side + m.cardVerticalInset * 2)
    finishCard(at: index, style: .callout(callout.tone), parts: parts, height: cy, isRightToLeft: rtl)
    return true
  }

  // MARK: - Meter

  mutating func appendMeter(_ meter: RichMeter, path: RichPath, x: CGFloat, width: CGFloat) -> Bool {
    let m = metrics
    let rtl = meter.isRightToLeft
    var parts = CardParts()
    let meta = meter.meta.flatMap { $0.isEmpty ? nil : singleLine($0, width: width * 0.5, isRightToLeft: rtl) }
    let metaWidth = meta.map { $0.size.width + 8 } ?? 0
    let label = wrapped(meter.label, width: width - metaWidth, isRightToLeft: rtl)
    let row = max(label.size.height, meta?.size.height ?? 0)
    parts.add(.text(label), CGRect(x: 0, y: 0, width: label.size.width, height: label.size.height))
    if let meta {
      parts.add(.text(meta), CGRect(x: width - meta.size.width, y: row - meta.size.height, width: meta.size.width, height: meta.size.height))
    }
    let fraction = meter.fraction.isFinite ? min(max(meter.fraction, 0), 1) : 0
    let bar = CGRect(x: 0, y: row + m.meterBarGap, width: width, height: m.meterBarHeight)
    parts.add(.bar(fraction: fraction, tone: meter.tone), bar)
    return appendCard(.plain, parts: parts, path: path, x: x, top: y, width: width, height: bar.maxY, isRightToLeft: rtl)
  }

  // MARK: - Diff

  mutating func appendDiff(_ diff: RichDiff, path: RichPath, x: CGFloat, width: CGFloat) -> Bool {
    let m = metrics
    let inset = m.diffHorizontalInset
    let pathLine = unbounded(diff.path)
    let lineHeight = firstLineHeight(pathLine)
    let header = grid.ceil(max(lineHeight, 16) + m.diffHeaderVerticalInset * 2)
    let side = grid.round(min(max(lineHeight * 0.8, 13), 24))
    let body = diff.body.flatMap { $0.isEmpty ? nil : unbounded($0) }
    let copy: CGFloat = body == nil ? 0 : 30
    let counts = diff.counts.flatMap { $0.isEmpty ? nil : unbounded($0) }
    let countsWidth = counts?.size.width ?? 0
    let countsX = width - inset - copy - countsWidth + (copy > 0 ? 4 : 0)
    let pathX = inset + side + 6
    let footer = diff.footer.flatMap { $0.isEmpty ? nil : unbounded($0) }
    let bodyOrigin = CGPoint(x: inset, y: header + m.diffBodyVerticalInset)
    var height = header
    var footerOrigin = CGPoint(x: inset, y: header)
    if let body {
      height = bodyOrigin.y + body.size.height
      footerOrigin.y = height + 2
      if let footer { height = footerOrigin.y + footer.size.height }
      height += m.diffBodyVerticalInset
    }
    let node = RichLayout.Diff(
      symbol: diff.symbol,
      symbolFrame: grid.round(CGRect(x: inset, y: (header - side) / 2, width: side, height: side)),
      path: diff.path,
      pathFrame: grid.round(CGRect(x: pathX, y: (header - lineHeight) / 2, width: max(1, countsX - 8 - pathX), height: lineHeight)),
      counts: counts,
      countsFrame: grid.round(CGRect(
        x: countsX,
        y: (header - (counts?.size.height ?? 0)) / 2,
        width: countsWidth,
        height: counts?.size.height ?? 0
      )),
      copyFrame: grid.round(CGRect(x: width - copy, y: 0, width: copy, height: header)),
      headerHeight: header,
      body: body,
      bodyOrigin: bodyOrigin,
      footer: body == nil ? nil : footer,
      footerOrigin: footerOrigin,
      contentWidth: grid.ceil(max(width, inset * 2 + max(body?.size.width ?? 0, footer?.size.width ?? 0)))
    )
    let frame = CGRect(x: x, y: y, width: width, height: grid.ceil(height))
    guard append(path, frame, .diff(node), anchor: .stretch) else { return false }
    claimsMaximumWidth = true
    y = frame.maxY
    return true
  }

  // MARK: - Plan proposal

  mutating func layout(plan: RichPlanProposal, path: RichPath, x: CGFloat, width: CGFloat, depth: Int) -> Bool {
    let m = metrics
    let rtl = plan.isRightToLeft
    let top = y
    guard let index = beginCard(path: path, x: x, top: top, width: width) else { return false }
    let inner = max(1, width - m.cardHorizontalInset * 2)
    var parts = CardParts()
    var cy = m.cardVerticalInset
    cy += appendHeader(
      symbol: .named(plan.symbol, tone: .accent),
      title: plan.title,
      chip: plan.state,
      to: &parts,
      x: m.cardHorizontalInset,
      top: cy,
      width: inner,
      isRightToLeft: rtl
    )
    if !plan.children.isEmpty {
      cy += m.cardSectionSpacing
      let bodyTop = top + cy
      y = bodyTop
      let start = nodes.count
      guard layout(plan.children, parent: path, x: x + m.cardHorizontalInset, width: inner, depth: depth, isRightToLeft: rtl) else {
        return false
      }
      let overflows = y - bodyTop > plan.collapsedHeight + 1
      if overflows, !plan.isExpanded {
        y = clip(from: start, at: bodyTop + plan.collapsedHeight)
      }
      cy = y - top
      if overflows, let toggle = plan.toggle {
        cy += m.cardSectionSpacing
        cy += appendToggle(toggle, to: &parts, x: m.cardHorizontalInset, top: cy, width: inner, isRightToLeft: rtl)
      }
    }
    if !plan.buttons.isEmpty || plan.decision != nil {
      cy += m.cardSectionSpacing
      cy += appendActions(plan.buttons, status: plan.decision, to: &parts, x: m.cardHorizontalInset, top: cy, width: inner, isRightToLeft: rtl)
    }
    finishCard(at: index, style: .plan, parts: parts, height: cy + m.cardVerticalInset, isRightToLeft: rtl)
    return true
  }

  // MARK: - Approval

  mutating func layout(approval: RichApproval, path: RichPath, x: CGFloat, width: CGFloat, depth: Int) -> Bool {
    let m = metrics
    let rtl = approval.isRightToLeft
    let top = y
    guard let index = beginCard(path: path, x: x, top: top, width: width) else { return false }
    let inner = max(1, width - m.cardHorizontalInset * 2)
    var parts = CardParts()
    var cy = m.cardVerticalInset
    cy += appendHeader(
      symbol: .named(approval.symbol, tone: .warning),
      title: approval.title,
      chip: approval.state,
      to: &parts,
      x: m.cardHorizontalInset,
      top: cy,
      width: inner,
      isRightToLeft: rtl
    )
    if let command = approval.command, !command.isEmpty {
      cy += m.cardSectionSpacing
      let text = wrapped(command, width: inner - m.commandHorizontalInset * 2, isRightToLeft: false)
      let box = CGRect(x: m.cardHorizontalInset, y: cy, width: inner, height: text.size.height + m.commandVerticalInset * 2)
      parts.add(.box, box)
      // Commands read left to right in any card.
      parts.add(
        .text(text),
        CGRect(x: box.minX + m.commandHorizontalInset, y: box.minY + m.commandVerticalInset, width: text.size.width, height: text.size.height),
        mirrors: false
      )
      cy = box.maxY
    }
    for (offset, detail) in approval.details.enumerated() where !detail.isEmpty {
      cy += offset == 0 ? m.cardSectionSpacing * 0.7 : m.cardLineSpacing
      let text = wrapped(detail, width: inner, isRightToLeft: rtl)
      parts.add(.text(text), CGRect(x: m.cardHorizontalInset, y: cy, width: text.size.width, height: text.size.height))
      cy += text.size.height
    }
    if !approval.children.isEmpty {
      if let toggle = approval.toggle {
        cy += m.cardSectionSpacing
        cy += appendToggle(toggle, to: &parts, x: m.cardHorizontalInset, top: cy, width: inner, isRightToLeft: rtl)
      }
      if approval.isExpanded || approval.toggle == nil {
        cy += m.cardSectionSpacing
        y = top + cy
        guard layout(approval.children, parent: path, x: x + m.cardHorizontalInset, width: inner, depth: depth, isRightToLeft: rtl) else {
          return false
        }
        cy = y - top
      }
    }
    if !approval.buttons.isEmpty || approval.decision != nil {
      cy += m.cardSectionSpacing
      cy += appendActions(approval.buttons, status: approval.decision, to: &parts, x: m.cardHorizontalInset, top: cy, width: inner, isRightToLeft: rtl)
    }
    finishCard(at: index, style: .approval, parts: parts, height: cy + m.cardVerticalInset, isRightToLeft: rtl)
    return true
  }

  // MARK: - Review

  mutating func appendReview(_ review: RichReview, path: RichPath, x: CGFloat, width: CGFloat) -> Bool {
    // Same cap as the server.
    guard review.findings.count <= RichReview.maximumFindings else { return false }
    let m = metrics
    let rtl = review.isRightToLeft
    let inner = max(1, width - m.cardHorizontalInset * 2)
    let left = m.cardHorizontalInset
    var parts = CardParts()
    var cy = m.cardVerticalInset
    let headerSymbol = RichSymbol.named(review.symbol, tone: .accent)
    let side = symbolSide(forLineHeight: firstLineHeight(unbounded(review.title)))
    cy += appendHeader(symbol: headerSymbol, title: review.title, chip: review.verdict, to: &parts, x: left, top: cy, width: inner, isRightToLeft: rtl)
    if let count = review.count, !count.isEmpty {
      cy += m.cardLineSpacing
      let text = wrapped(count, width: inner - side - m.symbolGap, isRightToLeft: rtl)
      parts.add(.text(text), CGRect(x: left + side + m.symbolGap, y: cy, width: text.size.width, height: text.size.height))
      cy += text.size.height
    }
    if let summary = review.summary, !summary.isEmpty {
      cy += m.cardSectionSpacing * 0.8
      let text = wrapped(summary, width: inner, isRightToLeft: rtl)
      parts.add(.text(text), CGRect(x: left, y: cy, width: text.size.width, height: text.size.height))
      cy += text.size.height
    }
    // Priority chips share a column so the titles line up.
    let chips = review.findings.map { $0.priority.map(chipSize) }
    let column = chips.compactMap { $0?.1.width }.max().map { $0 + m.symbolGap } ?? 0
    if !review.findings.isEmpty { cy += m.cardSectionSpacing * 0.6 }
    for (index, finding) in review.findings.enumerated() {
      let rowTop = cy
      parts.add(.separator, CGRect(x: left, y: cy, width: inner, height: 1 / grid.scale))
      cy += m.reviewRowSpacing
      let probe = firstLineHeight(unbounded(finding.title))
      let markSide = grid.round(probe * 0.75)
      let hasChevron = finding.body?.isEmpty == false && finding.toggle != nil
      let trailing = (finding.outcome == nil ? 0 : markSide + 6) + (hasChevron ? markSide * 0.8 + 6 : 0)
      let titleX = left + column
      let titleWidth = max(1, inner - column - trailing)
      let rowIndex = parts.parts.count
      let title = wrapped(finding.title, width: titleWidth, isRightToLeft: rtl)
      let lineHeight = firstLineHeight(title)
      if let chip = finding.priority, let (text, size) = chips[index] {
        parts.add(.chip(text, tone: chip.tone, symbol: chip.symbol), CGRect(x: left, y: cy + (lineHeight - size.height) / 2, width: size.width, height: size.height))
      }
      parts.add(.text(title), CGRect(x: titleX, y: cy, width: title.size.width, height: title.size.height))
      var markX = left + inner
      if hasChevron {
        let chevron = markSide * 0.8
        markX -= chevron
        let symbol = finding.isExpanded ? "chevron.up" : "chevron.down"
        parts.add(.symbol(.named(symbol, tone: .neutral)), CGRect(x: markX, y: cy + (lineHeight - chevron) / 2, width: chevron, height: chevron))
        markX -= 6
      }
      if let outcome = finding.outcome {
        markX -= markSide
        parts.add(.symbol(outcome), CGRect(x: markX, y: cy + (lineHeight - markSide) / 2, width: markSide, height: markSide))
      }
      cy += title.size.height
      if let location = finding.location, !location.isEmpty {
        cy += 2
        let text = singleLine(location, width: titleWidth, isRightToLeft: false)
        parts.add(.text(text), CGRect(x: titleX, y: cy, width: text.size.width, height: text.size.height))
        cy += text.size.height
      }
      if finding.isExpanded, let body = finding.body, !body.isEmpty {
        cy += 4
        let text = wrapped(body, width: inner - column, isRightToLeft: rtl)
        parts.add(.text(text), CGRect(x: titleX, y: cy, width: text.size.width, height: text.size.height))
        cy += text.size.height
      }
      if let button = finding.button {
        cy += 6
        let title = singleLine(button.title, width: inner - column - m.buttonHorizontalPadding * 2, isRightToLeft: false)
        let size = CGSize(
          width: grid.ceil(title.size.width + m.buttonHorizontalPadding * 2),
          height: grid.ceil(max(m.buttonMinimumHeight - 6, title.size.height + m.buttonVerticalPadding * 1.5))
        )
        parts.add(.button(title, style: button.style), CGRect(x: titleX, y: cy, width: size.width, height: size.height), tap: button.tap)
        cy += size.height
      }
      cy += m.reviewRowSpacing
      if let toggle = finding.toggle, finding.body?.isEmpty == false {
        // Behind the row's texts, so a tap anywhere on the row opens it.
        parts.parts.insert(
          .init(kind: .row, frame: CGRect(x: left - 6, y: rowTop, width: inner + 12, height: cy - rowTop), tap: toggle),
          at: rowIndex
        )
        parts.unmirrored = Set(parts.unmirrored.map { $0 >= rowIndex ? $0 + 1 : $0 })
      }
    }
    if !review.findings.isEmpty { cy -= m.reviewRowSpacing * 0.4 }
    return appendCard(.review, parts: parts, path: path, x: x, top: y, width: width, height: cy + m.cardVerticalInset, isRightToLeft: rtl)
  }

  // MARK: - Task suggestion

  mutating func appendTaskSuggestion(_ task: RichTaskSuggestion, path: RichPath, x: CGFloat, width: CGFloat) -> Bool {
    let m = metrics
    let rtl = task.isRightToLeft
    let inner = max(1, width - m.cardHorizontalInset * 2)
    var parts = CardParts()
    var cy = m.cardVerticalInset
    cy += appendHeader(
      symbol: .named(task.symbol, tone: .accent),
      title: task.title,
      chip: task.state,
      to: &parts,
      x: m.cardHorizontalInset,
      top: cy,
      width: inner,
      isRightToLeft: rtl
    )
    if let brief = task.brief, !brief.isEmpty {
      cy += m.cardLineSpacing * 2
      let text = clamped(brief, width: inner, lines: m.briefLineLimit, isRightToLeft: rtl)
      parts.add(.text(text), CGRect(x: m.cardHorizontalInset, y: cy, width: text.size.width, height: text.size.height))
      cy += text.size.height
    }
    if !task.buttons.isEmpty || task.status != nil {
      cy += m.cardSectionSpacing
      cy += appendActions(task.buttons, status: task.status, to: &parts, x: m.cardHorizontalInset, top: cy, width: inner, isRightToLeft: rtl)
    }
    return appendCard(
      .taskSuggestion,
      parts: parts,
      path: path,
      x: x,
      top: y,
      width: width,
      height: cy + m.cardVerticalInset,
      isMuted: task.isMuted,
      isRightToLeft: rtl
    )
  }

  // MARK: - Next step

  mutating func appendNextStep(_ step: RichNextStep, path: RichPath, x: CGFloat, width: CGFloat) -> Bool {
    let m = metrics
    let rtl = step.isRightToLeft
    let inner = max(1, width - m.cardHorizontalInset * 2)
    let left = m.cardHorizontalInset
    var parts = CardParts()
    var cy = m.cardVerticalInset
    if let waiting = step.waiting {
      let (text, size) = chipSize(waiting)
      parts.add(.chip(text, tone: waiting.tone, symbol: waiting.symbol), CGRect(x: left, y: cy, width: size.width, height: size.height))
      cy += size.height + m.cardLineSpacing * 2
    }
    let recap = wrapped(step.recap, width: inner, isRightToLeft: rtl)
    parts.add(.text(recap), CGRect(x: left, y: cy, width: recap.size.width, height: recap.size.height))
    cy += recap.size.height
    if let question = step.question, !question.isEmpty {
      cy += m.cardSectionSpacing * 0.7
      let text = wrapped(question, width: inner, isRightToLeft: rtl)
      parts.add(.text(text), CGRect(x: left, y: cy, width: text.size.width, height: text.size.height))
      cy += text.size.height
    }
    if !step.buttons.isEmpty {
      cy += m.cardSectionSpacing
      cy += appendActions(step.buttons, status: nil, to: &parts, x: left, top: cy, width: inner, isRightToLeft: rtl)
    }
    return appendCard(.nextStep, parts: parts, path: path, x: x, top: y, width: width, height: cy + m.cardVerticalInset, isRightToLeft: rtl)
  }

  // MARK: - Prompt suggestions

  mutating func appendPromptSuggestions(_ prompts: RichPromptSuggestions, path: RichPath, x: CGFloat, width: CGFloat) -> Bool {
    guard !prompts.prompts.isEmpty, prompts.prompts.count <= RichPromptSuggestions.maximumPrompts else { return false }
    let m = metrics
    let rtl = prompts.isRightToLeft
    var parts = CardParts()
    var cx: CGFloat = 0
    var cy: CGFloat = 0
    var rowHeight: CGFloat = 0
    var used: CGFloat = 0
    for prompt in prompts.prompts {
      let title = singleLine(prompt.title, width: max(1, width - m.suggestionHorizontalPadding * 2), isRightToLeft: rtl)
      let size = CGSize(
        width: grid.ceil(title.size.width + m.suggestionHorizontalPadding * 2),
        height: grid.ceil(title.size.height + m.suggestionVerticalPadding * 2)
      )
      if cx > 0, cx + size.width > width {
        cx = 0
        cy += rowHeight + m.chipSpacing
        rowHeight = 0
      }
      parts.add(.button(title, style: .suggestion), CGRect(x: cx, y: cy, width: size.width, height: size.height), tap: prompt.tap)
      cx += size.width + m.chipSpacing
      used = max(used, cx - m.chipSpacing)
      rowHeight = max(rowHeight, size.height)
    }
    let nodeWidth = min(width, grid.ceil(used))
    let card = RichLayout.Card(
      style: .plain,
      parts: parts.finished(width: nodeWidth, isRightToLeft: rtl, grid: grid),
      isMuted: false,
      isRightToLeft: rtl,
      hasChildren: false
    )
    let frame = CGRect(x: rtl ? x + width - nodeWidth : x, y: y, width: nodeWidth, height: grid.ceil(cy + rowHeight))
    guard append(path, frame, .card(card), anchor: rtl ? .trailing : .leading) else { return false }
    record(frame)
    y = frame.maxY
    return true
  }

  // MARK: - Form

  mutating func appendForm(_ form: RichForm, path: RichPath, x: CGFloat, width: CGFloat) -> Bool {
    guard !form.fields.isEmpty, form.fields.count <= RichForm.maximumFields else { return false }
    let m = metrics
    let rtl = form.isRightToLeft
    let inner = max(1, width - m.cardHorizontalInset * 2)
    let left = m.cardHorizontalInset
    var parts = CardParts()
    var cy = m.cardVerticalInset
    if let title = form.title, !title.isEmpty {
      cy += appendHeader(
        symbol: .named("list.bullet.clipboard", tone: .accent),
        title: title,
        chip: nil,
        to: &parts,
        x: left,
        top: cy,
        width: inner,
        isRightToLeft: rtl
      )
      cy += m.cardSectionSpacing
    }
    for (index, field) in form.fields.enumerated() {
      if index > 0 { cy += m.cardSectionSpacing * 1.4 }
      if let header = field.header {
        let (text, size) = chipSize(header)
        parts.add(.chip(text, tone: header.tone, symbol: header.symbol), CGRect(x: left, y: cy, width: min(size.width, inner), height: size.height))
        cy += size.height + m.cardLineSpacing * 2
      }
      let label = wrapped(field.label, width: inner, isRightToLeft: rtl)
      parts.add(.text(label), CGRect(x: left, y: cy, width: label.size.width, height: label.size.height))
      cy += label.size.height
      if let detail = field.detail, !detail.isEmpty {
        cy += 2
        let text = wrapped(detail, width: inner, isRightToLeft: rtl)
        parts.add(.text(text), CGRect(x: left, y: cy, width: text.size.width, height: text.size.height))
        cy += text.size.height
      }
      if !field.options.isEmpty { cy += m.cardLineSpacing }
      for option in field.options {
        cy += appendFormOption(option, isMultiple: field.isMultiple, to: &parts, x: left, top: cy, width: inner, isRightToLeft: rtl)
      }
      if let answer = field.answer {
        cy += m.cardLineSpacing * 2
        cy += appendFormAnswer(answer, to: &parts, x: left, top: cy, width: inner, isRightToLeft: rtl)
      }
      if let preview = field.preview, !preview.isEmpty {
        cy += m.cardLineSpacing * 2
        // Previews are mockups and code: left to right, kept as written.
        let text = clamped(preview, width: inner - m.commandHorizontalInset * 2, lines: m.previewLineLimit, isRightToLeft: false)
        let box = CGRect(x: left, y: cy, width: inner, height: text.size.height + m.commandVerticalInset * 2)
        parts.add(.box, box)
        parts.add(
          .text(text),
          CGRect(x: box.minX + m.commandHorizontalInset, y: box.minY + m.commandVerticalInset, width: text.size.width, height: text.size.height),
          mirrors: false
        )
        cy = box.maxY
      }
    }
    if let note = form.note, !note.isEmpty {
      cy += m.cardSectionSpacing
      let text = wrapped(note, width: inner, isRightToLeft: rtl)
      parts.add(.text(text), CGRect(x: left, y: cy, width: text.size.width, height: text.size.height))
      cy += text.size.height
    }
    if !form.buttons.isEmpty || form.status != nil {
      cy += m.cardSectionSpacing
      cy += appendActions(form.buttons, status: form.status, to: &parts, x: left, top: cy, width: inner, isRightToLeft: rtl)
    }
    return appendCard(.approval, parts: parts, path: path, x: x, top: y, width: width, height: cy + m.cardVerticalInset, isRightToLeft: rtl)
  }

  /// One choice: a radio or checkbox mark, the label with an optional tag on its first line,
  /// and a secondary line. The whole row takes the tap. Returns the height used.
  private func appendFormOption(
    _ option: RichForm.Option,
    isMultiple: Bool,
    to parts: inout CardParts,
    x: CGFloat,
    top: CGFloat,
    width: CGFloat,
    isRightToLeft: Bool
  ) -> CGFloat {
    let m = metrics
    let padding: CGFloat = 5
    let side = grid.round(firstLineHeight(unbounded(option.label)) * 0.82)
    let gap = m.symbolGap
    let tag = option.tag.map(chipSize)
    let tagRoom = tag.map { $0.1.width + m.symbolGap } ?? 0
    let label = wrapped(option.label, width: width - side - gap - tagRoom, isRightToLeft: isRightToLeft)
    let lineHeight = firstLineHeight(label)
    let detail = option.detail.flatMap { $0.isEmpty ? nil : wrapped($0, width: width - side - gap, isRightToLeft: isRightToLeft) }
    let height = max(label.size.height, side) + (detail.map { $0.size.height + 1 } ?? 0)
    if option.tap != nil {
      parts.add(.row, CGRect(x: x - 6, y: top, width: width + 12, height: height + padding * 2), tap: option.tap)
    }
    let y = top + padding
    let mark = switch (isMultiple, option.isSelected) {
    case (true, true): "checkmark.square.fill"
    case (true, false): "square"
    case (false, true): "largecircle.fill.circle"
    case (false, false): "circle"
    }
    parts.add(
      .symbol(.named(mark, tone: option.isSelected ? .accent : .neutral)),
      CGRect(x: x, y: y + (lineHeight - side) / 2, width: side, height: side)
    )
    parts.add(.text(label), CGRect(x: x + side + gap, y: y, width: label.size.width, height: label.size.height))
    if let chip = option.tag, let (text, size) = tag {
      parts.add(
        .chip(text, tone: chip.tone, symbol: chip.symbol),
        CGRect(x: x + width - size.width, y: y + (lineHeight - size.height) / 2, width: size.width, height: size.height)
      )
    }
    if let detail {
      let detailTop = y + max(label.size.height, side) + 1
      parts.add(.text(detail), CGRect(x: x + side + gap, y: detailTop, width: detail.size.width, height: detail.size.height))
    }
    return height + padding * 2
  }

  /// A typed answer in a filled box with a trailing glyph; the box opens its editor. Returns
  /// the height used.
  private func appendFormAnswer(
    _ answer: RichForm.Answer,
    to parts: inout CardParts,
    x: CGFloat,
    top: CGFloat,
    width: CGFloat,
    isRightToLeft: Bool
  ) -> CGFloat {
    let m = metrics
    let probe = firstLineHeight(unbounded(answer.text))
    let side = grid.round(probe * 0.7)
    let text = clamped(
      answer.text,
      width: width - m.commandHorizontalInset * 2 - side - m.symbolGap,
      lines: m.answerLineLimit,
      isRightToLeft: isRightToLeft
    )
    let box = CGRect(x: x, y: top, width: width, height: text.size.height + m.commandVerticalInset * 2)
    if answer.tap != nil {
      parts.add(.row, box, tap: answer.tap)
    }
    parts.add(.box, box)
    parts.add(.text(text), CGRect(x: box.minX + m.commandHorizontalInset, y: box.minY + m.commandVerticalInset, width: text.size.width, height: text.size.height))
    parts.add(
      .symbol(.named(answer.symbol, tone: .neutral)),
      CGRect(x: box.maxX - m.commandHorizontalInset - side, y: box.minY + m.commandVerticalInset + (probe - side) / 2, width: side, height: side)
    )
    return box.height
  }
}
