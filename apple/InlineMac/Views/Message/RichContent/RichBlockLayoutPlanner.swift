import AppKit
import InlineKit
import InlineProtocol
import TextProcessing

final class RichBlockLayoutPlanner {
  static let shared = RichBlockLayoutPlanner()
  // Mirrors the server validation ceiling. A larger/forged snapshot falls
  // back to the ordinary message projection before creating native surfaces.
  private static let maxTableCells = 256
  private static let maximumBlocks = 1_024
  private static let maximumContentByteCount = 512 * 1_024

  private final class PlanBox: NSObject {
    let plan: RichBlockLayoutPlan
    let content: InlineProtocol.BlockContent
    let contentCacheSignature: Int
    let attributedText: NSAttributedString
    let availableWidth: CGFloat
    let contentHorizontalInset: CGFloat
    let baseFontSize: CGFloat
    let inlineMathAttachmentsEnabled: Bool
    let disclosureOverrides: [BlockContentPath: Bool]

    init(
      plan: RichBlockLayoutPlan,
      content: InlineProtocol.BlockContent,
      contentCacheSignature: Int,
      attributedText: NSAttributedString,
      availableWidth: CGFloat,
      contentHorizontalInset: CGFloat,
      baseFontSize: CGFloat,
      inlineMathAttachmentsEnabled: Bool,
      disclosureOverrides: [BlockContentPath: Bool]
    ) {
      var geometry = plan
      geometry.mathSnapshot = nil
      self.plan = geometry
      self.content = content
      self.contentCacheSignature = contentCacheSignature
      self.attributedText = attributedText.copy() as? NSAttributedString ?? attributedText
      self.availableWidth = availableWidth
      self.contentHorizontalInset = contentHorizontalInset
      self.baseFontSize = baseFontSize
      self.inlineMathAttachmentsEnabled = inlineMathAttachmentsEnabled
      self.disclosureOverrides = disclosureOverrides
    }

    func matches(
      content: InlineProtocol.BlockContent,
      contentCacheSignature: Int,
      attributedText: NSAttributedString,
      availableWidth: CGFloat,
      contentHorizontalInset: CGFloat,
      baseFontSize: CGFloat,
      inlineMathAttachmentsEnabled: Bool,
      disclosureOverrides: [BlockContentPath: Bool]
    ) -> Bool {
      self.contentCacheSignature == contentCacheSignature
        && self.content == content
        && self.attributedText.string.utf8.elementsEqual(attributedText.string.utf8)
        && self.attributedText.isEqual(to: attributedText)
        && self.availableWidth == availableWidth
        && self.contentHorizontalInset == contentHorizontalInset
        && self.baseFontSize == baseFontSize
        && self.inlineMathAttachmentsEnabled == inlineMathAttachmentsEnabled
        && self.disclosureOverrides == disclosureOverrides
    }
  }

  private let cache = NSCache<NSString, PlanBox>()

  private init() {
    cache.countLimit = 256
    cache.totalCostLimit = 24 * 1_024 * 1_024
  }

  func plan(
    content: InlineProtocol.BlockContent,
    contentCacheSignature: Int,
    contentByteCount: Int,
    attributedText: NSAttributedString,
    availableWidth: CGFloat,
    contentHorizontalInset: CGFloat = 0,
    baseFontSize: CGFloat,
    primaryColor: NSColor = .labelColor,
    secondaryColor: NSColor = .secondaryLabelColor,
    inlineMathAttachmentsEnabled: Bool,
    disclosureOverrides: [BlockContentPath: Bool] = [:]
  ) -> RichBlockLayoutPlan? {
    guard availableWidth.isFinite, availableWidth >= 1,
          !content.blocks.isEmpty,
          contentByteCount >= 0,
          contentByteCount <= Self.maximumContentByteCount
    else { return nil }
    var remainingTableCells = Self.maxTableCells
    var remainingBlocks = Self.maximumBlocks
    guard Self.consumeStructuralBudget(
      content.blocks,
      remainingTableCells: &remainingTableCells,
      remainingBlocks: &remainingBlocks,
      depth: 0
    ) else {
      return nil
    }
    let math = Self.mathSnapshot(
      content: content,
      text: attributedText,
      fontSize: baseFontSize,
      primaryColor: primaryColor,
      secondaryColor: secondaryColor,
      includeInlineAttachments: inlineMathAttachmentsEnabled
    )
    let resolvedContentInset = min(max(0, contentHorizontalInset), max(0, (availableWidth - 1) / 2))
    let key = cacheKey(
      contentCacheSignature: contentCacheSignature,
      attributedText: attributedText,
      availableWidth: availableWidth,
      contentHorizontalInset: resolvedContentInset,
      baseFontSize: baseFontSize,
      inlineMathAttachmentsEnabled: inlineMathAttachmentsEnabled,
      disclosureOverrides: disclosureOverrides,
      mathSignature: math.signature
    )
    if let cached = cache.object(forKey: key),
       cached.matches(
         content: content,
         contentCacheSignature: contentCacheSignature,
         attributedText: attributedText,
         availableWidth: availableWidth,
         contentHorizontalInset: resolvedContentInset,
         baseFontSize: baseFontSize,
         inlineMathAttachmentsEnabled: inlineMathAttachmentsEnabled,
         disclosureOverrides: disclosureOverrides
       )
    {
      var prepared = cached.plan
      prepared.mathSnapshot = math
      return prepared
    }

    var builder = Builder(
      attributedText: attributedText,
      math: math,
      baseFontSize: baseFontSize,
      contentHorizontalInset: resolvedContentInset,
      disclosureOverrides: disclosureOverrides
    )
    guard builder.layout(
      blocks: content.blocks,
      parent: .init(),
      x: resolvedContentInset,
      width: max(1, availableWidth - resolvedContentInset * 2),
      depth: 0,
      fullBleedContainer: (x: 0, width: availableWidth)
    ) else {
      return nil
    }
    let resolvedWidth = builder.resolvedPlanWidth(maximumWidth: availableWidth)
    builder.normalizeFlexibleFrames(
      from: availableWidth,
      to: resolvedWidth
    )
    let plan = RichBlockLayoutPlan(
      size: CGSize(width: resolvedWidth, height: ceil(builder.height)),
      mathSignature: math.signature,
      mathSnapshot: math,
      contentHorizontalInset: resolvedContentInset,
      nodes: builder.nodes,
      trailingTextLine: builder.trailingTextLine
    )
    let box = PlanBox(
      plan: plan,
      content: content,
      contentCacheSignature: contentCacheSignature,
      attributedText: attributedText,
      availableWidth: availableWidth,
      contentHorizontalInset: resolvedContentInset,
      baseFontSize: baseFontSize,
      inlineMathAttachmentsEnabled: inlineMathAttachmentsEnabled,
      disclosureOverrides: disclosureOverrides
    )
    let estimatedCost = contentByteCount + attributedText.length * 8 + plan.nodes.count * 128
    cache.setObject(box, forKey: key, cost: estimatedCost)
    return plan
  }

  private static func consumeStructuralBudget(
    _ blocks: [InlineProtocol.Block],
    remainingTableCells: inout Int,
    remainingBlocks: inout Int,
    depth: Int
  ) -> Bool {
    guard depth <= 16, blocks.count <= remainingBlocks else { return false }
    remainingBlocks -= blocks.count
    for block in blocks {
      guard let kind = block.kind else { continue }
      switch kind {
      case let .table(table):
        for row in table.rows {
          guard row.cells.count <= remainingTableCells else { return false }
          remainingTableCells -= row.cells.count
        }
      case let .list(list):
        for item in list.items {
          guard consumeStructuralBudget(
            item.children,
            remainingTableCells: &remainingTableCells,
            remainingBlocks: &remainingBlocks,
            depth: depth + 1
          ) else { return false }
        }
      case let .disclosure(disclosure):
        guard consumeStructuralBudget(
          disclosure.children,
          remainingTableCells: &remainingTableCells,
          remainingBlocks: &remainingBlocks,
          depth: depth + 1
        ) else { return false }
      case let .quote(quote):
        guard consumeStructuralBudget(
          quote.children,
          remainingTableCells: &remainingTableCells,
          remainingBlocks: &remainingBlocks,
          depth: depth + 1
        ) else { return false }
      default:
        break
      }
    }
    return true
  }

  private func cacheKey(
    contentCacheSignature: Int,
    attributedText: NSAttributedString,
    availableWidth: CGFloat,
    contentHorizontalInset: CGFloat,
    baseFontSize: CGFloat,
    inlineMathAttachmentsEnabled: Bool,
    disclosureOverrides: [BlockContentPath: Bool],
    mathSignature: Int
  ) -> NSString {
    let overrides = disclosureOverrides
      .map { "\(String(describing: $0.key.components)):\($0.value)" }
      .sorted()
      .joined(separator: ",")
    return NSString(
      string: "\(contentCacheSignature)_\(Data(attributedText.string.utf8).hashValue)_\(attributedText.hash)_\(Int(availableWidth.rounded()))_\(contentHorizontalInset)_\(baseFontSize)_\(inlineMathAttachmentsEnabled)_\(overrides)_\(mathSignature)"
    )
  }

  static func mathSnapshot(content: InlineProtocol.BlockContent, text: NSAttributedString,
                           fontSize: CGFloat, primaryColor: NSColor, secondaryColor: NSColor,
                           includeInlineAttachments: Bool) -> RichTextMath.Snapshot {
    RichTextMath.snapshot(
      content: content,
      text: text,
      fontSize: fontSize,
      includeInlineAttachments: includeInlineAttachments
    ) { range, role in
      let nativeRole: RichBlockTextRole
      switch role {
      case .paragraph: nativeRole = .paragraph
      case let .heading(level): nativeRole = .heading(level: level)
      case .footer: nativeRole = .footer
      case let .disclosure(progress): nativeRole = .disclosureSummary(
          progress: progress,
          expanded: false,
          activity: nil
        )
      case let .table(header):
        return styledTableText(text, offset: range.location, length: range.length, baseFontSize: fontSize,
                               isRTL: false, alignment: .left, isHeader: header)
      }
      guard let value = styledText(text, offset: range.location, length: range.length, role: nativeRole,
                                   baseFontSize: fontSize, isRTL: false)?.mutableCopy() as? NSMutableAttributedString
      else { return nil }
      if case .footer = role { value.addAttribute(.foregroundColor, value: secondaryColor,
                                                 range: NSRange(location: 0, length: value.length)) }
      if case .disclosure = role {
        value.addAttribute(.foregroundColor, value: secondaryColor,
                           range: NSRange(location: 0, length: value.length))
      }
      return value
    }
  }

  static func styledText(
    _ attributedText: NSAttributedString,
    offset: Int,
    length: Int,
    role: RichBlockTextRole,
    baseFontSize: CGFloat,
    isRTL: Bool,
    math: RichTextMath.Snapshot? = nil,
    maximumWidth: CGFloat? = nil
  ) -> NSAttributedString? {
    guard offset >= 0, length >= 0, offset <= attributedText.length,
          length <= attributedText.length - offset
    else { return nil }

    let value = NSMutableAttributedString(
      attributedString: attributedText.attributedSubstring(from: NSRange(location: offset, length: length))
    )
    let fullRange = NSRange(location: 0, length: value.length)
    switch role {
    case .paragraph:
      break
    case let .heading(level):
      let clamped = min(max(level, 1), 6)
      let scale = [1.22, 1.14, 1.07, 1.02, 1.0, 1.0][clamped - 1]
      PlatformFontTraits.applyBaseFont(
        ChatTypography.current.font(
          sized: baseFontSize * scale,
          weight: clamped == 1 ? .semibold : .medium
        ),
        to: value
      )
    case .footer:
      PlatformFontTraits.applyBaseFont(ChatTypography.current.font(sized: baseFontSize * 0.82), to: value)
      value.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: fullRange)
    case .disclosureSummary:
      PlatformFontTraits.applyBaseFont(ChatTypography.current.font(sized: baseFontSize, weight: .regular), to: value)
    case .listMarker:
      break
    }
    let paragraph = NSMutableParagraphStyle()
    paragraph.baseWritingDirection = isRTL ? .rightToLeft : .leftToRight
    paragraph.alignment = isRTL ? .right : .left
    value.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)
    return math.map { RichTextMath.projectInline(value, sourceOffset: offset, snapshot: $0, maximumWidth: maximumWidth) } ?? value
  }

  static func styledTableText(
    _ attributedText: NSAttributedString,
    offset: Int,
    length: Int,
    baseFontSize: CGFloat,
    isRTL: Bool,
    alignment: RichBlockLayoutPlan.TableAlignment,
    isHeader: Bool,
    math: RichTextMath.Snapshot? = nil,
    maximumWidth: CGFloat? = nil
  ) -> NSAttributedString? {
    guard let value = styledText(
      attributedText,
      offset: offset,
      length: length,
      role: .paragraph,
      baseFontSize: baseFontSize,
      isRTL: isRTL
    )?.mutableCopy() as? NSMutableAttributedString else { return nil }
    let range = NSRange(location: 0, length: value.length)
    let paragraph = NSMutableParagraphStyle()
    paragraph.baseWritingDirection = isRTL ? .rightToLeft : .leftToRight
    paragraph.alignment = switch alignment {
    case .left: .left
    case .center: .center
    case .right: .right
    }
    value.addAttribute(.paragraphStyle, value: paragraph, range: range)
    if isHeader {
      PlatformFontTraits.applyBaseFont(ChatTypography.current.font(sized: baseFontSize, weight: .semibold), to: value)
    }
    return math.map { RichTextMath.projectInline(value, sourceOffset: offset, snapshot: $0, maximumWidth: maximumWidth) } ?? value
  }

  private struct Builder {
    private struct TextMeasurement {
      var height: CGFloat
      var maxLineUsedWidth: CGFloat
      var lastLineUsedWidth: CGFloat
      var lastLineHeight: CGFloat
    }

    private static let blockSpacing: CGFloat = 8
    private static let albumHeight: CGFloat = 126
    private static let albumItemSpacing: CGFloat = 6
    private static let tableHorizontalPadding: CGFloat = 10
    private static let tableVerticalPadding: CGFloat = 7
    private static let whitespaceExpression = try? NSRegularExpression(pattern: #"\s+"#)

    let attributedText: NSAttributedString
    let math: RichTextMath.Snapshot
    let baseFontSize: CGFloat
    let contentHorizontalInset: CGFloat
    let disclosureOverrides: [BlockContentPath: Bool]
    var nodes: [RichBlockLayoutPlan.Node] = []
    var height: CGFloat = 0
    var trailingTextLine: RichBlockLayoutPlan.TrailingTextLine?
    private var measuredMaxX: CGFloat = 0
    private var claimsMaximumWidth = false

    func resolvedPlanWidth(maximumWidth: CGFloat) -> CGFloat {
      guard !claimsMaximumWidth else { return maximumWidth }
      let measuredWidth = measuredMaxX + contentHorizontalInset
      return min(maximumWidth, max(1, ceil(measuredWidth)))
    }

    mutating func normalizeFlexibleFrames(from maximumWidth: CGFloat, to resolvedWidth: CGFloat) {
      guard resolvedWidth < maximumWidth else { return }
      for index in nodes.indices {
        switch nodes[index].kind {
        case .separator, .quote:
          let trailingMargin = max(0, maximumWidth - nodes[index].frame.maxX)
          nodes[index].frame.size.width = max(
            1,
            resolvedWidth - trailingMargin - nodes[index].frame.minX
          )
        default:
          break
        }
      }
    }

    private mutating func recordMeasuredFrame(_ frame: CGRect) {
      measuredMaxX = max(measuredMaxX, frame.maxX)
    }

    private mutating func claimMaximumWidth() {
      claimsMaximumWidth = true
    }

    mutating func layout(
      blocks: [InlineProtocol.Block],
      parent: BlockContentPath,
      x: CGFloat,
      width: CGFloat,
      depth: Int,
      inheritedDirection: Bool? = nil,
      fullBleedContainer: (x: CGFloat, width: CGFloat)? = nil
    ) -> Bool {
      guard depth <= 16, nodes.count + blocks.count <= RichBlockLayoutPlanner.maximumBlocks else { return false }
      for (index, block) in blocks.enumerated() {
        if index == 0, case .heading? = block.kind {
          height += parent.components.isEmpty ? 6 : 4
        } else if index > 0 {
          let startsNestedList: Bool = if case .list? = block.kind,
                                         case .listItem? = parent.components.last
          {
            true
          } else {
            false
          }
          height += startsNestedList ? RichBlockListMetrics.itemSpacing : Self.blockSpacing
          if case let .heading(heading)? = block.kind {
            height += heading.level <= 2 ? 7 : 5
          }
        }
        let path = BlockContentPath(parent.components + [.block(index)])
        let isTerminalRoot = parent.components.isEmpty && index == blocks.count - 1
        guard layout(
          block: block,
          path: path,
          x: x,
          width: width,
          depth: depth,
          inheritedDirection: inheritedDirection,
          fullBleedContainer: fullBleedContainer,
          isTerminalRoot: isTerminalRoot
        ) else { return false }
      }
      return true
    }

    private mutating func layout(
      block: InlineProtocol.Block,
      path: BlockContentPath,
      x: CGFloat,
      width: CGFloat,
      depth: Int,
      inheritedDirection: Bool? = nil,
      fullBleedContainer: (x: CGFloat, width: CGFloat)? = nil,
      isTerminalRoot: Bool = false
    ) -> Bool {
      guard let kind = block.kind else { return false }
      switch kind {
      case let .math(text):
        return appendMath(text, path: path, x: x, width: width)
      case let .paragraph(text):
        return appendText(
          text,
          role: .paragraph,
          path: path,
          x: x,
          width: width,
          inheritedDirection: inheritedDirection
        )
      case let .heading(heading):
        guard heading.hasText else { return false }
        return appendText(
          heading.text,
          role: .heading(level: Int(heading.level)),
          path: path,
          x: x,
          width: width,
          inheritedDirection: inheritedDirection
        )
      case let .code(code):
        guard code.hasText else { return false }
        return appendCode(code, path: path, x: x, width: width)
      case let .list(list):
        return layout(
          list: list,
          path: path,
          x: x,
          width: width,
          depth: depth + 1,
          inheritedDirection: inheritedDirection
        )
      case .separator:
        let frame = CGRect(x: x, y: height + 4, width: width, height: 1)
        nodes.append(.init(path: path, frame: frame, kind: .separator))
        recordMeasuredFrame(
          CGRect(x: x, y: frame.minY, width: min(width, 120), height: frame.height)
        )
        height = frame.maxY + 4
        return true
      case let .image(image):
        let size = imageSize(image, availableWidth: width)
        let frame = CGRect(x: x, y: height, width: size.width, height: size.height)
        let imageNode = RichBlockLayoutPlan.ImageNode(path: path, frame: frame, state: imageState(image))
        nodes.append(.init(path: path, frame: frame, kind: .image(imageNode)))
        recordMeasuredFrame(frame)
        height = frame.maxY
        return true
      case let .album(album):
        let container = fullBleedContainer ?? (x: x, width: width)
        claimMaximumWidth()
        return appendAlbum(album, path: path, x: container.x, width: container.width)
      case let .disclosure(disclosure):
        guard disclosure.hasSummary else { return false }
        let direction = disclosure.hasIsRtl ? disclosure.isRtl : inheritedDirection
        let expanded = disclosureOverrides[path] ?? (disclosure.hasInitiallyOpen && disclosure.initiallyOpen)
        guard appendText(
          disclosure.summary,
          role: .disclosureSummary(
            progress: disclosure.kind == .progress,
            expanded: expanded,
            activity: RichBlockActivityKind(disclosure.activityKind)
          ),
          path: path,
          x: x,
          width: width,
          inheritedDirection: direction
        ) else { return false }
        guard expanded else { return true }
        height += Self.blockSpacing
        return layout(
          blocks: disclosure.children,
          parent: path,
          x: x,
          width: width,
          depth: depth + 1,
          inheritedDirection: direction,
          fullBleedContainer: fullBleedContainer
        )
      case let .footer(text):
        return appendText(
          text,
          role: .footer,
          path: path,
          x: x,
          width: width,
          inheritedDirection: inheritedDirection,
          capturesTrailingLine: isTerminalRoot
        )
      case let .quote(quote):
        return layout(
          quote: quote,
          path: path,
          x: x,
          width: width,
          depth: depth + 1,
          inheritedDirection: inheritedDirection
        )
      case let .table(table):
        let container = fullBleedContainer ?? (x: x, width: width)
        let edgeInset = contentHorizontalInset > 0 ? min(4, contentHorizontalInset) : 0
        claimMaximumWidth()
        return appendTable(
          table,
          path: path,
          x: container.x + edgeInset,
          width: max(1, container.width - edgeInset * 2),
          inheritedDirection: inheritedDirection
        )
      }
    }

    private mutating func layout(
      list: InlineProtocol.BlockList,
      path: BlockContentPath,
      x: CGFloat,
      width: CGFloat,
      depth: Int,
      inheritedDirection: Bool?
    ) -> Bool {
      guard !list.items.isEmpty, list.items.count <= 1_024,
            list.kind == .ordered || list.kind == .unordered
      else { return false }
      let firstOrdinal = list.kind == .ordered && list.hasStart ? list.start : 1
      guard (0 ... 999_999_999).contains(firstOrdinal) else { return false }
      let lastOrdinal = firstOrdinal + Int64(max(0, list.items.count - 1))
      let markerWidth = RichBlockListMetrics.markerWidth(
        ordered: list.kind == .ordered,
        lastOrdinal: lastOrdinal,
        baseFontSize: baseFontSize
      )
      let isRTL = list.hasIsRtl ? list.isRtl : (inheritedDirection ?? false)
      let isNested = path.components.contains { component in
        if case .listItem = component { return true }
        return false
      }
      let logicalInset = RichBlockListMetrics.leadingInset
        + (isNested ? RichBlockListMetrics.nestedIndent : 0)
      let listX = isRTL ? x : x + logicalInset
      let listWidth = max(1, width - logicalInset)
      let childWidth = max(1, listWidth - markerWidth)
      for (itemIndex, item) in list.items.enumerated() {
        if itemIndex > 0 { height += RichBlockListMetrics.itemSpacing }
        let itemPath = BlockContentPath(path.components + [.listItem(itemIndex)])
        let marker = if item.hasChecked {
          item.checked ? "☑" : "☐"
        } else if list.kind == .ordered {
          "\(firstOrdinal + Int64(itemIndex))."
        } else {
          "•"
        }
        let markerHeight = RichBlockListMetrics.markerHeight(baseFontSize: baseFontSize)
        let markerFrame = CGRect(
          x: isRTL ? listX + childWidth : listX,
          y: height,
          width: markerWidth,
          height: markerHeight
        )
        nodes.append(.init(
          path: itemPath,
          frame: markerFrame,
          kind: .text(.init(
            rangeOffset: 0,
            rangeLength: 0,
            role: .listMarker,
            literal: marker,
            isRTL: isRTL
          ))
        ))
        recordMeasuredFrame(markerFrame)
        let itemStart = height
        guard layout(
          blocks: item.children,
          parent: itemPath,
          x: isRTL ? listX : listX + markerWidth,
          width: childWidth,
          depth: depth,
          inheritedDirection: isRTL,
          fullBleedContainer: nil
        ) else { return false }
        height = max(height, itemStart + markerHeight)
      }
      return true
    }

    private mutating func appendCode(
      _ code: InlineProtocol.BlockCode,
      path: BlockContentPath,
      x: CGFloat,
      width: CGFloat
    ) -> Bool {
      guard let attributed = codeText(code.text) else { return false }
      let lineCount = max(1, attributed.string.components(separatedBy: .newlines).count)
      let language = code.hasLanguage && !code.language.isEmpty ? code.language : nil
      let hasLanguage = language != nil
      let gutterWidth = language == nil ? 0 : RichBlockCodeMetrics.gutterWidth(lineCount: lineCount)
      let bodyWidth = RichBlockCodeMetrics.bodyWidth(
        containerWidth: width,
        gutterWidth: gutterWidth
      )
      let bodyHeight = textHeight(attributed, width: bodyWidth)
      let frame = CGRect(
        x: x,
        y: height,
        width: width,
        height: RichBlockCodeMetrics.totalHeight(bodyHeight: bodyHeight, hasLanguage: hasLanguage)
      )
      nodes.append(.init(
        path: path,
        frame: frame,
        kind: .code(.init(
          rangeOffset: Int(code.text.offset),
          rangeLength: Int(code.text.length),
          language: language,
          gutterWidth: gutterWidth,
          lineCount: lineCount
        ))
      ))
      claimMaximumWidth()
      height = frame.maxY
      return true
    }

    private mutating func layout(
      quote: InlineProtocol.BlockQuote,
      path: BlockContentPath,
      x: CGFloat,
      width: CGFloat,
      depth: Int,
      inheritedDirection: Bool?
    ) -> Bool {
      guard !quote.children.isEmpty else { return false }
      let isRTL = quote.hasIsRtl ? quote.isRtl : (inheritedDirection ?? false)
      let startY = height
      let decorationIndex = nodes.count
      nodes.append(.init(
        path: path,
        frame: CGRect(x: x, y: startY, width: width, height: 0),
        kind: .quote(.init(isRTL: isRTL))
      ))
      height += RichBlockQuoteMetrics.verticalInset
      let contentX = x + (isRTL ? RichBlockQuoteMetrics.trailingInset : RichBlockQuoteMetrics.leadingInset)
      let precedingMaxX = measuredMaxX
      measuredMaxX = 0
      guard layout(
        blocks: quote.children,
        parent: path,
        x: contentX,
        width: max(1, width - RichBlockQuoteMetrics.leadingInset - RichBlockQuoteMetrics.trailingInset),
        depth: depth,
        inheritedDirection: isRTL,
        fullBleedContainer: nil
      ) else { return false }
      let quotedContentMaxX = measuredMaxX
      let endingInset = isRTL
        ? RichBlockQuoteMetrics.leadingInset
        : RichBlockQuoteMetrics.trailingInset
      measuredMaxX = max(precedingMaxX, quotedContentMaxX + endingInset)
      height += RichBlockQuoteMetrics.verticalInset
      nodes[decorationIndex].frame.size.height = max(1, height - startY)
      return true
    }

    private mutating func appendTable(
      _ table: InlineProtocol.BlockTable,
      path: BlockContentPath,
      x: CGFloat,
      width: CGFloat,
      inheritedDirection: Bool?
    ) -> Bool {
      guard let firstRow = table.rows.first, !firstRow.cells.isEmpty else { return false }
      let columnCount = firstRow.cells.count
      guard table.rows.allSatisfy({ $0.cells.count == columnCount }) else { return false }
      guard table.rows.count <= RichBlockLayoutPlanner.maxTableCells / columnCount else { return false }
      let isRTL = table.hasIsRtl ? table.isRtl : (inheritedDirection ?? false)
      let alignments = (0 ..< columnCount).map { index in
        tableAlignment(
          index < table.alignments.count ? table.alignments[index] : .unspecified,
          isRTL: isRTL
        )
      }
      var minimumColumnWidths = Array(repeating: CGFloat(1), count: columnCount)
      var maximumColumnWidths = Array(repeating: CGFloat(1), count: columnCount)
      for (rowIndex, row) in table.rows.enumerated() {
        for (column, cell) in row.cells.enumerated() {
          guard let text = RichBlockLayoutPlanner.styledTableText(
            attributedText,
            offset: Int(cell.offset),
            length: Int(cell.length),
            baseFontSize: baseFontSize,
            isRTL: isRTL,
            alignment: alignments[column],
            isHeader: rowIndex == 0,
            math: math
          ) else { return false }
          let minimumTextWidth = minimumUnbreakableTextWidth(text)
          let maximumTextWidth = text.boundingRect(
            with: CGSize(
              width: CGFloat.greatestFiniteMagnitude,
              height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
          ).width
          let minimumCellWidth = ceil(
            max(baseFontSize, minimumTextWidth) + Self.tableHorizontalPadding * 2
          )
          let maximumCellWidth = max(
            minimumCellWidth,
            min(
              max(1, width),
              ceil(maximumTextWidth) + Self.tableHorizontalPadding * 2
            )
          )
          minimumColumnWidths[column] = max(minimumColumnWidths[column], minimumCellWidth)
          maximumColumnWidths[column] = max(maximumColumnWidths[column], maximumCellWidth)
        }
      }
      let columnWidths = allocateTableColumnWidths(
        minimum: minimumColumnWidths,
        maximum: maximumColumnWidths,
        viewportWidth: width
      )
      let contentWidth = columnWidths.reduce(0, +)

      var cells: [RichBlockLayoutPlan.TableNode.Cell] = []
      var rowY: CGFloat = 0
      for (rowIndex, row) in table.rows.enumerated() {
        let isHeader = rowIndex == 0
        var rowHeight = max(32, baseFontSize + Self.tableVerticalPadding * 2)
        for (column, cell) in row.cells.enumerated() {
          guard let text = RichBlockLayoutPlanner.styledTableText(
            attributedText,
            offset: Int(cell.offset),
            length: Int(cell.length),
            baseFontSize: baseFontSize,
            isRTL: isRTL,
            alignment: alignments[column],
            isHeader: isHeader,
            math: math
          ) else { return false }
          rowHeight = max(
            rowHeight,
            textHeight(text, width: max(1, columnWidths[column] - Self.tableHorizontalPadding * 2))
              + Self.tableVerticalPadding * 2
          )
        }
        var cellX: CGFloat = 0
        for (column, cell) in row.cells.enumerated() {
          cells.append(.init(
            rangeOffset: Int(cell.offset),
            rangeLength: Int(cell.length),
            frame: CGRect(x: cellX, y: rowY, width: columnWidths[column], height: ceil(rowHeight)),
            alignment: alignments[column],
            isHeader: isHeader
          ))
          cellX += columnWidths[column]
        }
        rowY += ceil(rowHeight)
      }
      let frame = CGRect(x: x, y: height, width: width, height: rowY)
      nodes.append(.init(
        path: path,
        frame: frame,
        kind: .table(.init(cells: cells, contentWidth: contentWidth, isRTL: isRTL))
      ))
      height = frame.maxY
      return true
    }

    private func minimumUnbreakableTextWidth(_ text: NSAttributedString) -> CGFloat {
      guard text.length > 0, let whitespaceExpression = Self.whitespaceExpression else { return 0 }
      let tokenLines = NSMutableAttributedString(attributedString: text)
      whitespaceExpression.replaceMatches(
        in: tokenLines.mutableString,
        range: NSRange(location: 0, length: tokenLines.length),
        withTemplate: "\n"
      )
      return measureText(
        tokenLines,
        width: CGFloat.greatestFiniteMagnitude
      ).maxLineUsedWidth
    }

    private func allocateTableColumnWidths(
      minimum: [CGFloat],
      maximum: [CGFloat],
      viewportWidth: CGFloat
    ) -> [CGFloat] {
      guard minimum.count == maximum.count, !minimum.isEmpty else { return [] }
      let resolvedMinimum = zip(minimum, maximum).map { min($0.0, $0.1) }
      let resolvedMaximum = zip(resolvedMinimum, maximum).map { max($0.0, $0.1) }
      let minimumTotal = resolvedMinimum.reduce(0, +)
      let maximumTotal = resolvedMaximum.reduce(0, +)

      if minimumTotal >= viewportWidth {
        return resolvedMinimum
      }

      var widths: [CGFloat]
      var distributable: CGFloat
      var weights: [CGFloat]
      if maximumTotal <= viewportWidth {
        widths = resolvedMaximum
        distributable = viewportWidth - maximumTotal
        weights = resolvedMaximum
      } else {
        widths = resolvedMinimum
        distributable = viewportWidth - minimumTotal
        weights = zip(resolvedMinimum, resolvedMaximum).map { max(0, $0.1 - $0.0) }
      }

      var remainingWeight = weights.reduce(0, +)
      for index in widths.indices {
        let remainingCount = widths.count - index
        let growth: CGFloat
        if remainingWeight > 0 {
          growth = weights[index] == remainingWeight
            ? distributable
            : floor(distributable * weights[index] / remainingWeight)
        } else {
          growth = floor(distributable / CGFloat(remainingCount))
        }
        widths[index] += max(0, growth)
        distributable -= max(0, growth)
        remainingWeight -= weights[index]
      }
      if distributable > 0, let last = widths.indices.last {
        widths[last] += distributable
      }
      return widths
    }

    private func tableAlignment(
      _ alignment: InlineProtocol.BlockTable.Alignment,
      isRTL: Bool
    ) -> RichBlockLayoutPlan.TableAlignment {
      switch alignment {
      case .left:
        .left
      case .center:
        .center
      case .right:
        .right
      case .unspecified, .UNRECOGNIZED:
        isRTL ? .right : .left
      }
    }

    private func codeText(_ text: InlineProtocol.BlockText) -> NSAttributedString? {
      let range = NSRange(location: Int(text.offset), length: Int(text.length))
      guard range.location >= 0,
            range.length >= 0,
            range.location <= attributedText.length,
            range.length <= attributedText.length - range.location
      else { return nil }
      let paragraph = NSMutableParagraphStyle()
      paragraph.baseWritingDirection = .leftToRight
      paragraph.alignment = .left
      return NSAttributedString(
        string: (attributedText.string as NSString).substring(with: range),
        attributes: [
          .font: RichBlockCodeMetrics.bodyFont,
          .foregroundColor: NSColor.labelColor,
          .paragraphStyle: paragraph,
        ]
      )
    }

    private mutating func appendMath(_ text: InlineProtocol.BlockText, path: BlockContentPath, x: CGFloat, width: CGFloat) -> Bool {
      guard text.offset >= 0, text.length > 0, text.offset <= Int64(attributedText.length),
            text.length <= Int64(attributedText.length) - text.offset else { return false }
      let range = NSRange(location: Int(text.offset), length: Int(text.length))
      if let image = math.image(for: range) {
        let imageSize = CGSize(width: image.width, height: image.height)
        let frame = CGRect(x: x, y: height, width: min(width, max(40, image.width)),
                           height: ceil(max(baseFontSize * 1.25, image.height)))
        nodes.append(.init(path: path, frame: frame, kind: .math(.init(range: range, imageSize: imageSize))))
        recordMeasuredFrame(frame)
        height = frame.maxY
      } else {
        guard appendText(text, role: .paragraph, path: path, x: x, width: width, inheritedDirection: false)
        else { return false }
        nodes[nodes.count - 1].kind = .math(.init(range: range, imageSize: nil))
      }
      trailingTextLine = nil
      return true
    }

    private mutating func appendText(
      _ text: InlineProtocol.BlockText,
      role: RichBlockTextRole,
      path: BlockContentPath,
      x: CGFloat,
      width: CGFloat,
      inset: CGFloat = 0,
      inheritedDirection: Bool? = nil,
      capturesTrailingLine: Bool = false
    ) -> Bool {
      let isRTL = text.hasIsRtl ? text.isRtl : (inheritedDirection ?? false)
      let disclosureActivity: RichBlockActivityKind? = if case let .disclosureSummary(_, _, activity) = role {
        activity
      } else {
        nil
      }
      let renderedTextWidth: CGFloat = if case .disclosureSummary = role {
        RichBlockDisclosureMetrics.titleViewportWidth(
          containerWidth: width,
          hasActivityIcon: disclosureActivity != nil
        )
      } else {
        width
      }
      guard let attributed = RichBlockLayoutPlanner.styledText(
        attributedText,
        offset: Int(text.offset),
        length: Int(text.length),
        role: role,
        baseFontSize: baseFontSize,
        isRTL: isRTL,
        math: math,
        maximumWidth: max(1, renderedTextWidth - inset * 2)
      ) else { return false }
      let measuredWidth = max(1, renderedTextWidth - inset * 2)
      let singleLine = if case .disclosureSummary = role {
        true
      } else {
        false
      }
      let measurement = measureText(attributed, width: measuredWidth, singleLine: singleLine)
      let measuredHeight = measurement.height
      let accessoryWidth: CGFloat = if case .disclosureSummary = role {
        RichBlockDisclosureMetrics.preferredChevronSide
          + RichBlockDisclosureMetrics.titleChevronGap
          + (disclosureActivity == nil
            ? 0
            : RichBlockDisclosureMetrics.activityIconSide
              + RichBlockDisclosureMetrics.activityTitleGap)
      } else {
        0
      }
      let compactWidth = min(
        width,
        max(1, measurement.maxLineUsedWidth + inset * 2 + accessoryWidth)
      )
      let frame = CGRect(
        x: x,
        y: height,
        width: compactWidth,
        height: max(measuredHeight + inset * 2, baseFontSize + inset * 2)
      )
      nodes.append(.init(
        path: path,
        frame: frame,
        kind: .text(.init(
          rangeOffset: Int(text.offset),
          rangeLength: Int(text.length),
          role: role,
          literal: nil,
          isRTL: isRTL
        ))
      ))
      recordMeasuredFrame(frame)
      height = frame.maxY
      if capturesTrailingLine {
        trailingTextLine = .init(
          usedWidth: measurement.lastLineUsedWidth + contentHorizontalInset * 2,
          height: measurement.lastLineHeight,
          isRTL: isRTL
        )
      }
      return true
    }

    private mutating func appendAlbum(
      _ album: InlineProtocol.BlockAlbum,
      path: BlockContentPath,
      x: CGFloat,
      width: CGFloat
    ) -> Bool {
      guard !album.images.isEmpty, album.images.count <= 10 else { return false }
      var itemX: CGFloat = 0
      let items = album.images.enumerated().map { index, image in
        let itemPath = BlockContentPath(path.components + [.albumImage(index)])
        let ratio = imageAspectRatio(image)
        let itemWidth = min(max(96, Self.albumHeight * ratio), 220)
        defer { itemX += itemWidth + Self.albumItemSpacing }
        return RichBlockLayoutPlan.ImageNode(
          path: itemPath,
          frame: CGRect(x: itemX, y: 0, width: itemWidth, height: Self.albumHeight),
          state: imageState(image)
        )
      }
      let frame = CGRect(x: x, y: height, width: width, height: Self.albumHeight)
      nodes.append(.init(path: path, frame: frame, kind: .album(.init(items: items))))
      height = frame.maxY
      return true
    }

    private func textHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
      measureText(text, width: width).height
    }

    private func measureText(
      _ text: NSAttributedString,
      width: CGFloat,
      singleLine: Bool = false
    ) -> TextMeasurement {
      let bounds = text.boundingRect(
        with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
      )
      let storage = NSTextStorage(attributedString: text)
      let layoutManager = NSLayoutManager()
      let container = NSTextContainer(
        containerSize: CGSize(width: max(1, width), height: .greatestFiniteMagnitude)
      )
      container.lineFragmentPadding = 0
      container.maximumNumberOfLines = singleLine ? 1 : 0
      container.lineBreakMode = singleLine ? .byTruncatingTail : .byWordWrapping
      layoutManager.addTextContainer(container)
      storage.addLayoutManager(layoutManager)
      layoutManager.ensureLayout(for: container)
      var lastUsedRect = CGRect.zero
      var maxLineUsedWidth: CGFloat = 0
      let glyphRange = layoutManager.glyphRange(for: container)
      layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, _ in
        lastUsedRect = usedRect
        maxLineUsedWidth = max(maxLineUsedWidth, usedRect.width)
      }
      return TextMeasurement(
        height: max(ceil(singleLine ? layoutManager.usedRect(for: container).height : bounds.height), ceil(baseFontSize * 1.25)),
        maxLineUsedWidth: ceil(maxLineUsedWidth),
        lastLineUsedWidth: ceil(lastUsedRect.width),
        lastLineHeight: ceil(lastUsedRect.height)
      )
    }

    private func imageSize(_ image: InlineProtocol.BlockImage, availableWidth: CGFloat) -> CGSize {
      let maximumSize = CGSize(width: min(availableWidth, 420), height: 420)
      let naturalSize = imageDimensions(image) ?? CGSize(width: 240, height: 180)
      guard naturalSize.width > 0, naturalSize.height > 0 else {
        return CGSize(width: min(maximumSize.width, 240), height: min(maximumSize.height, 180))
      }
      let scale = min(
        1,
        min(
          maximumSize.width / naturalSize.width,
          maximumSize.height / naturalSize.height
        )
      )
      return CGSize(
        width: max(1, floor(naturalSize.width * scale)),
        height: max(1, floor(naturalSize.height * scale))
      )
    }

    private func imageAspectRatio(_ image: InlineProtocol.BlockImage) -> CGFloat {
      guard let dimensions = imageDimensions(image) else { return 4 / 3 }
      return min(max(dimensions.width / dimensions.height, 0.2), 5)
    }

    private func imageDimensions(_ image: InlineProtocol.BlockImage) -> CGSize? {
      let dimensions: (UInt32, UInt32)? = switch image.state {
      case let .pending(pending)?:
        pending.hasDimensions ? (pending.dimensions.width, pending.dimensions.height) : nil
      case let .ready(photo)?:
        photo.sizes.max { lhs, rhs in Int(lhs.w) * Int(lhs.h) < Int(rhs.w) * Int(rhs.h) }
          .map { (UInt32(max($0.w, 0)), UInt32(max($0.h, 0))) }
      case let .unavailable(unavailable)?:
        unavailable.hasDimensions ? (unavailable.dimensions.width, unavailable.dimensions.height) : nil
      case nil:
        nil
      }
      guard let dimensions, dimensions.0 > 0, dimensions.1 > 0 else { return nil }
      return CGSize(width: CGFloat(dimensions.0), height: CGFloat(dimensions.1))
    }

    private func imageState(_ image: InlineProtocol.BlockImage) -> RichBlockLayoutPlan.ImageNode.State {
      switch image.state {
      case .pending?:
        return .pending
      case let .ready(photo)?:
        let storedPhoto = Photo.from(proto: photo)
        let localID = storedPhoto.id ?? storedPhoto.photoId
        let sizes = photo.sizes.map { PhotoSize.from(proto: $0, photoId: localID) }
        return .ready(PhotoInfo(photo: storedPhoto, sizes: sizes))
      case .unavailable?, nil:
        return .unavailable
      }
    }
  }
}
