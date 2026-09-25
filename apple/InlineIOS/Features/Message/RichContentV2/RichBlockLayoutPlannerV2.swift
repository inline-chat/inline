import InlineIOSUI
import InlineKit
import InlineProtocol
import InlineSyntaxHighlighting
import TextProcessing
import UIKit

@MainActor
final class RichBlockLayoutPlannerV2 {
  static let shared = RichBlockLayoutPlannerV2()
  private static let maximumContentByteCount = 512 * 1_024

  private final class PlanBox: NSObject {
    let plan: RichBlockLayoutPlanV2
    let content: InlineProtocol.BlockContent
    let attributedText: NSAttributedString
    let literalTextHash: Int
    let width: CGFloat
    let disclosureOverrides: [BlockContentPath: Bool]

    init(
      plan: RichBlockLayoutPlanV2,
      content: InlineProtocol.BlockContent,
      attributedText: NSAttributedString,
      literalTextHash: Int,
      width: CGFloat,
      disclosureOverrides: [BlockContentPath: Bool]
    ) {
      var geometry = plan
      geometry.mathSnapshot = nil
      self.plan = geometry
      self.content = content
      self.attributedText = attributedText.copy() as? NSAttributedString ?? attributedText
      self.literalTextHash = literalTextHash
      self.width = width
      self.disclosureOverrides = disclosureOverrides
    }
  }

  private final class TextMeasurementBox: NSObject {
    let text: NSAttributedString
    let width: CGFloat
    let measurement: TextMeasurement

    init(text: NSAttributedString, width: CGFloat, measurement: TextMeasurement) {
      self.text = text.copy() as? NSAttributedString ?? text
      self.width = width
      self.measurement = measurement
    }
  }

  private let cache: NSCache<NSString, PlanBox> = {
    let cache = NSCache<NSString, PlanBox>()
    cache.countLimit = 256
    cache.totalCostLimit = 24 * 1_024 * 1_024
    return cache
  }()

  private static let textMeasurementCache: NSCache<NSString, TextMeasurementBox> = {
    let cache = NSCache<NSString, TextMeasurementBox>()
    cache.countLimit = 2_048
    cache.totalCostLimit = 16 * 1_024 * 1_024
    return cache
  }()

  private static let tableWhitespaceExpression = try? NSRegularExpression(pattern: #"\s+"#)
  private static let tableFontScale: CGFloat = 0.9

  private init() {}

  func plan(
    content: InlineProtocol.BlockContent,
    contentCacheSignature: Int,
    contentByteCount: Int,
    attributedText: NSAttributedString,
    availableWidth: CGFloat,
    baseFontSize: CGFloat,
    primaryColor: UIColor = .label,
    secondaryColor: UIColor = .secondaryLabel,
    disclosureOverrides: [BlockContentPath: Bool]
  ) -> RichBlockLayoutPlanV2? {
    guard availableWidth.isFinite, availableWidth >= 1,
          !content.blocks.isEmpty,
          content.blocks.count <= 1_024,
          contentByteCount >= 0,
          contentByteCount <= Self.maximumContentByteCount
    else { return nil }

    let math = Self.mathSnapshot(content: content, text: attributedText, fontSize: baseFontSize,
                                 primaryColor: primaryColor, secondaryColor: secondaryColor)
    let overridesKey = disclosureOverrides
      .map { "\($0.key.components)=\($0.value)" }
      .sorted()
      .joined(separator: ",")
    let literalTextHash = Data(attributedText.string.utf8).hashValue
    let key =
      "\(contentCacheSignature)|\(literalTextHash)|\(attributedText.hash)|\(Int(availableWidth.rounded()))|\(baseFontSize)|\(overridesKey)|\(math.signature)" as NSString
    if let cached = cache.object(forKey: key),
       cached.content == content,
       cached.literalTextHash == literalTextHash,
       cached.attributedText.string.utf8.elementsEqual(attributedText.string.utf8),
       cached.attributedText.isEqual(to: attributedText),
       cached.width == availableWidth,
       cached.disclosureOverrides == disclosureOverrides
    {
      var prepared = cached.plan
      prepared.mathSnapshot = math
      return prepared
    }

    var builder = Builder(
      attributedText: attributedText,
      math: math,
      baseFontSize: baseFontSize,
      disclosureOverrides: disclosureOverrides
    )
    guard builder.layout(
      blocks: content.blocks,
      parent: .init(),
      x: 0,
      width: availableWidth,
      depth: 0,
      inheritedRTL: nil,
      isRoot: true
    ) else { return nil }

    let resolvedWidth = builder.claimsMaximumWidth
      ? availableWidth
      : min(availableWidth, max(1, ceil(builder.measuredMaxX)))
    builder.normalizeFlexibleFrames(from: availableWidth, to: resolvedWidth)
    let plan = RichBlockLayoutPlanV2(
      size: CGSize(width: resolvedWidth, height: ceil(builder.height)),
      mathSignature: math.signature,
      mathSnapshot: math,
      nodes: builder.nodes,
      trailingTextLine: builder.trailingTextLine
    )
    cache.setObject(
      PlanBox(
        plan: plan,
        content: content,
        attributedText: attributedText,
        literalTextHash: literalTextHash,
        width: availableWidth,
        disclosureOverrides: disclosureOverrides
      ),
      forKey: key,
      cost: contentByteCount + attributedText.length * 8 + plan.nodes.count * 128
    )
    return plan
  }

  static func mathSnapshot(content: InlineProtocol.BlockContent, text: NSAttributedString,
                           fontSize: CGFloat, primaryColor: UIColor, secondaryColor: UIColor) -> RichTextMath.Snapshot {
    RichTextMath.snapshot(content: content, text: text, fontSize: fontSize) { range, role in
      let nativeRole: RichBlockTextRoleV2
      switch role {
      case .paragraph: nativeRole = .paragraph
      case let .heading(level): nativeRole = .heading(level: level)
      case .footer: nativeRole = .footer
      case let .disclosure(progress): nativeRole = .disclosure(progress: progress, expanded: false)
      case let .table(header):
        return styledTableText(from: text, range: range, baseFontSize: fontSize,
                               isRTL: false, alignment: .leading, isHeader: header)
      }
      guard let value = styledText(from: text, range: range, role: nativeRole, baseFontSize: fontSize,
                                   isRTL: false)?.mutableCopy() as? NSMutableAttributedString else { return nil }
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
    from attributedText: NSAttributedString,
    range: NSRange,
    role: RichBlockTextRoleV2,
    baseFontSize: CGFloat,
    isRTL: Bool,
    math: RichTextMath.Snapshot? = nil,
    maximumWidth: CGFloat? = nil
  ) -> NSAttributedString? {
    guard range.location >= 0, range.length >= 0, range.location <= attributedText.length,
          range.length <= attributedText.length - range.location else {
      return nil
    }
    let result = NSMutableAttributedString(attributedString: attributedText.attributedSubstring(from: range))
    let font: UIFont = switch role {
      case .paragraph: .systemFont(ofSize: baseFontSize)
      case let .heading(level):
        .systemFont(
          ofSize: baseFontSize * (level <= 1 ? 1.1 : level == 2 ? 1.05 : 1),
          weight: .medium
        )
      case .footer: .systemFont(ofSize: max(12, baseFontSize * 0.82))
      case .disclosure: .systemFont(ofSize: baseFontSize, weight: .regular)
      case .listMarker: .systemFont(ofSize: baseFontSize)
    }
    let paragraph = NSMutableParagraphStyle()
    paragraph.baseWritingDirection = isRTL ? .rightToLeft : .leftToRight
    paragraph.alignment = isRTL ? .right : .natural
    paragraph.lineBreakMode = .byWordWrapping
    PlatformFontTraits.applyBaseFont(font, to: result)
    result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
    return math.map { RichTextMath.projectInline(result, sourceOffset: range.location, snapshot: $0, maximumWidth: maximumWidth) } ?? result
  }

  static func styledTableText(
    from attributedText: NSAttributedString,
    range: NSRange,
    baseFontSize: CGFloat,
    isRTL: Bool,
    alignment: RichBlockLayoutPlanV2.TableAlignment,
    isHeader: Bool,
    math: RichTextMath.Snapshot? = nil,
    maximumWidth: CGFloat? = nil
  ) -> NSAttributedString? {
    let tableFontSize = baseFontSize * tableFontScale
    guard let value = styledText(
      from: attributedText,
      range: range,
      role: .paragraph,
      baseFontSize: tableFontSize,
      isRTL: isRTL
    )?.mutableCopy() as? NSMutableAttributedString else { return nil }
    let fullRange = NSRange(location: 0, length: value.length)
    let paragraph = NSMutableParagraphStyle()
    paragraph.baseWritingDirection = isRTL ? .rightToLeft : .leftToRight
    paragraph.alignment = switch alignment {
      case .leading: isRTL ? .right : .left
      case .center: .center
      case .trailing: isRTL ? .left : .right
    }
    value.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)
    if isHeader {
      PlatformFontTraits.applyBaseFont(.systemFont(ofSize: tableFontSize, weight: .medium), to: value)
    }
    return math.map { RichTextMath.projectInline(value, sourceOffset: range.location, snapshot: $0, maximumWidth: maximumWidth) } ?? value
  }

  private struct TextMeasurement {
    let height: CGFloat
    let maxLineWidth: CGFloat
    let lastLineWidth: CGFloat
    let lastLineHeight: CGFloat
  }

  @MainActor private struct Builder {
    static let blockSpacing: CGFloat = 8
    static let codeHorizontalInset: CGFloat = 8
    static let codeLanguageBodyTopInset: CGFloat = 3
    static let codeOverlayBodyTopInset: CGFloat = 8
    static let codeBottomInset: CGFloat = 9
    static let codeGutterTextTrailingInset: CGFloat = 4
    static let codeGutterContentGap: CGFloat = 15
    static let quoteLeadingInset: CGFloat = 14
    static let quoteTrailingInset: CGFloat = 8
    static let quoteVerticalInset: CGFloat = 7
    static let listMarkerWidth: CGFloat = 17
    static let listIndent: CGFloat = 0
    static let albumHeight: CGFloat = 128
    static let albumSpacing: CGFloat = 6
    static let tableHorizontalPadding: CGFloat = 10
    static let tableVerticalPadding: CGFloat = 7

    let attributedText: NSAttributedString
    let math: RichTextMath.Snapshot
    let baseFontSize: CGFloat
    let disclosureOverrides: [BlockContentPath: Bool]
    var nodes: [RichBlockLayoutPlanV2.Node] = []
    var height: CGFloat = 0
    var measuredMaxX: CGFloat = 0
    var claimsMaximumWidth = false
    var trailingTextLine: RichBlockLayoutPlanV2.TrailingTextLine?
    var tableCellCount = 0
    var imageCount = 0
    var trailingTextEdges: [(nodeIndex: Int, containerMaxX: CGFloat)] = []

    // Wrap text once at the permitted width, then fit decorations to its actual extent.
    // This is geometry-only: changing the wrapping width here would reshape streamed text.
    mutating func normalizeFlexibleFrames(from maximumWidth: CGFloat, to resolvedWidth: CGFloat) {
      let widthReduction = max(0, maximumWidth - resolvedWidth)
      for index in nodes.indices where widthReduction > 0 {
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
      // RTL paragraphs retain their logical trailing edge even when a wider sibling
      // determines the bubble width. Only positions change; text never reflows here.
      for (index, containerMaxX) in trailingTextEdges {
        nodes[index].frame.origin.x = max(
          nodes[index].frame.minX,
          containerMaxX - widthReduction - nodes[index].frame.width
        )
      }
    }

    mutating func layout(
      blocks: [InlineProtocol.Block],
      parent: BlockContentPath,
      x: CGFloat,
      width: CGFloat,
      depth: Int,
      inheritedRTL: Bool?,
      isRoot: Bool
    ) -> Bool {
      guard depth <= 16, nodes.count + blocks.count <= 1_024 else { return false }
      for (index, block) in blocks.enumerated() {
        if index > 0 { height += Self.blockSpacing }
        if case let .heading(heading)? = block.kind, index > 0 {
          height += heading.level <= 2 ? 5 : 3
        }
        let path = BlockContentPath(parent.components + [.block(index)])
        guard layout(
          block: block,
          path: path,
          x: x,
          width: width,
          depth: depth,
          inheritedRTL: inheritedRTL,
          capturesTrailingLine: isRoot && index == blocks.count - 1
        ) else { return false }
      }
      return true
    }

    mutating func layout(
      block: InlineProtocol.Block,
      path: BlockContentPath,
      x: CGFloat,
      width: CGFloat,
      depth: Int,
      inheritedRTL: Bool?,
      capturesTrailingLine: Bool
    ) -> Bool {
      guard let kind = block.kind else { return false }
      switch kind {
        case let .math(text):
          return appendMath(text, path: path, x: x, width: width)
        case let .paragraph(text):
          return appendText(text, role: .paragraph, path: path, x: x, width: width, inheritedRTL: inheritedRTL)
        case let .heading(heading):
          guard heading.hasText else { return false }
          return appendText(
            heading.text,
            role: .heading(level: Int(heading.level)),
            path: path,
            x: x,
            width: width,
            inheritedRTL: inheritedRTL
          )
        case let .footer(text):
          return appendText(
            text,
            role: .footer,
            path: path,
            x: x,
            width: width,
            inheritedRTL: inheritedRTL,
            capturesTrailingLine: capturesTrailingLine
          )
        case let .code(code):
          return appendCode(code, path: path, x: x, width: width)
        case let .list(list):
          return appendList(list, path: path, x: x, width: width, depth: depth + 1, inheritedRTL: inheritedRTL)
        case .separator:
          let frame = CGRect(x: x, y: height + 4, width: width, height: 1)
          nodes.append(.init(path: path, frame: frame, kind: .separator))
          measuredMaxX = max(measuredMaxX, frame.minX + min(frame.width, 120))
          height = frame.maxY + 4
          return true
        case let .image(image):
          guard imageCount < 64 else { return false }
          imageCount += 1
          let size = imageSize(image, availableWidth: width)
          let frame = CGRect(x: x, y: height, width: size.width, height: size.height)
          let imageNode = RichBlockLayoutPlanV2.ImageNode(
            path: path,
            frame: frame,
            alt: imageAlt(image),
            state: imageState(image)
          )
          nodes.append(.init(path: path, frame: frame, kind: .image(imageNode)))
          measuredMaxX = max(measuredMaxX, frame.maxX)
          height = frame.maxY
          return true
        case let .album(album):
          return appendAlbum(album, path: path, x: x, width: width)
        case let .disclosure(disclosure):
          guard disclosure.hasSummary else { return false }
          let rtl = disclosure.hasIsRtl ? disclosure.isRtl : (inheritedRTL ?? false)
          let expanded = disclosureOverrides[path]
            ?? (disclosure.hasInitiallyOpen && disclosure.initiallyOpen)
          guard appendText(
            disclosure.summary,
            role: .disclosure(
              progress: disclosure.kind == .progress, expanded: expanded,
              activity: RichBlockActivityKindV2(disclosure.activityKind)
            ),
            path: path,
            x: x,
            width: width,
            inheritedRTL: rtl
          ) else { return false }
          guard expanded else { return true }
          height += Self.blockSpacing
          return layout(
            blocks: disclosure.children,
            parent: path,
            x: x,
            width: width,
            depth: depth + 1,
            inheritedRTL: rtl,
            isRoot: false
          )
        case let .quote(quote):
          return appendQuote(quote, path: path, x: x, width: width, depth: depth + 1, inheritedRTL: inheritedRTL)
        case let .table(table):
          return appendTable(table, path: path, x: x, width: width, inheritedRTL: inheritedRTL)
      }
    }

    mutating func appendMath(_ text: InlineProtocol.BlockText, path: BlockContentPath, x: CGFloat, width: CGFloat) -> Bool {
      guard text.offset >= 0, text.length > 0, text.offset <= Int64(attributedText.length),
            text.length <= Int64(attributedText.length) - text.offset else { return false }
      let range = NSRange(location: Int(text.offset), length: Int(text.length))
      if let image = math.image(for: range) {
        let imageSize = CGSize(width: image.width, height: image.height)
        let frame = CGRect(x: x, y: height, width: min(width, max(40, image.width)),
                           height: ceil(max(baseFontSize * 1.25, image.height)))
        nodes.append(.init(path: path, frame: frame, kind: .math(.init(range: range, imageSize: imageSize))))
        measuredMaxX = max(measuredMaxX, frame.maxX)
        height = frame.maxY
      } else {
        guard appendText(text, role: .paragraph, path: path, x: x, width: width, inheritedRTL: false)
        else { return false }
        let old = nodes.removeLast()
        nodes.append(.init(path: old.path, frame: old.frame, kind: .math(.init(range: range, imageSize: nil))))
      }
      trailingTextLine = nil
      return true
    }

    mutating func appendText(
      _ text: InlineProtocol.BlockText,
      role: RichBlockTextRoleV2,
      path: BlockContentPath,
      x: CGFloat,
      width: CGFloat,
      inheritedRTL: Bool?,
      capturesTrailingLine: Bool = false
    ) -> Bool {
      let range = NSRange(location: Int(text.offset), length: Int(text.length))
      let rtl = text.hasIsRtl ? text.isRtl : (inheritedRTL ?? false)
      let textWidth: CGFloat
      let disclosureChrome: CGFloat
      if case let .disclosure(_, _, activity) = role {
        textWidth = RichBlockDisclosureMetricsV2.titleViewportWidth(containerWidth: width, hasActivity: activity != nil)
        disclosureChrome = RichBlockDisclosureMetricsV2.accessoryWidth(hasActivity: activity != nil)
      } else {
        textWidth = width
        disclosureChrome = 0
      }
      guard let styled = Self.styled(
        attributedText,
        range: range,
        role: role,
        baseFontSize: baseFontSize,
        rtl: rtl,
        math: math,
        maximumWidth: max(1, textWidth)
      ) else { return false }
      let measurement = measureText(styled, width: max(1, textWidth))
      let nodeWidth = min(width, max(1, measurement.maxLineWidth + disclosureChrome))
      let frame = CGRect(x: x, y: height, width: nodeWidth, height: measurement.height)
      if rtl { trailingTextEdges.append((nodeIndex: nodes.count, containerMaxX: x + width)) }
      nodes.append(.init(
        path: path,
        frame: frame,
        kind: .text(.init(range: range, role: role, literal: nil, isRTL: rtl))
      ))
      measuredMaxX = max(measuredMaxX, frame.maxX)
      height = frame.maxY
      if capturesTrailingLine {
        trailingTextLine = .init(
          usedWidth: measurement.lastLineWidth,
          height: measurement.lastLineHeight,
          isRTL: rtl
        )
      }
      return true
    }

    mutating func appendCode(
      _ code: InlineProtocol.BlockCode,
      path: BlockContentPath,
      x: CGFloat,
      width: CGFloat
    ) -> Bool {
      guard code.hasText else { return false }
      let range = NSRange(location: Int(code.text.offset), length: Int(code.text.length))
      guard range.location >= 0, range.length >= 0, range.location <= attributedText.length,
          range.length <= attributedText.length - range.location else { return false }
      let plain = attributedText.attributedSubstring(from: range).string
      let lineCount = max(1, plain.components(separatedBy: .newlines).count)
      let language = code.hasLanguage && !code.language.isEmpty ? code.language : nil
      let codeFont = UIFont.monospacedSystemFont(ofSize: baseFontSize * 0.9, weight: .regular)
      let gutterFont = UIFont.monospacedDigitSystemFont(ofSize: baseFontSize * 0.9, weight: .regular)
      let gutterWidth: CGFloat = CodeSyntaxHighlighter.supports(language: language)
        ? ceil((String(lineCount) as NSString).size(withAttributes: [.font: gutterFont]).width)
        + Self.codeGutterTextTrailingInset
        : 0
      let gutterGap = gutterWidth > 0 ? Self.codeGutterContentGap : 0
      let viewportWidth = max(1, width - Self.codeHorizontalInset * 2 - gutterWidth - gutterGap)
      let longestLineWidth = plain.components(separatedBy: .newlines).reduce(CGFloat.zero) { result, line in
        max(result, ceil((line as NSString).size(withAttributes: [.font: codeFont]).width))
      }
      let contentWidth = max(viewportWidth, longestLineWidth)
      let bodyHeight = ceil(codeFont.lineHeight * CGFloat(lineCount))
      let bodyTopInset = language == nil ? Self.codeOverlayBodyTopInset : Self.codeLanguageBodyTopInset
      let frame = CGRect(
        x: x,
        y: height,
        width: width,
        height: ceil(bodyHeight + bodyTopInset + Self.codeBottomInset + (language == nil ? 0 : ChatTypography.codeHeaderHeight(baseFontSize: baseFontSize)))
      )
      nodes.append(.init(
        path: path,
        frame: frame,
        kind: .code(.init(
          range: range,
          language: language,
          gutterWidth: gutterWidth,
          lineCount: lineCount,
          contentWidth: contentWidth
        ))
      ))
      measuredMaxX = max(measuredMaxX, frame.maxX)
      claimsMaximumWidth = true
      height = frame.maxY
      return true
    }

    mutating func appendList(
      _ list: InlineProtocol.BlockList,
      path: BlockContentPath,
      x: CGFloat,
      width: CGFloat,
      depth: Int,
      inheritedRTL: Bool?
    ) -> Bool {
      guard !list.items.isEmpty, list.items.count <= 1_024,
            list.kind == .ordered || list.kind == .unordered
      else { return false }
      let rtl = list.hasIsRtl ? list.isRtl : (inheritedRTL ?? false)
      if rtl { claimsMaximumWidth = true }
      let start = list.kind == .ordered && list.hasStart ? list.start : 1
      guard (0 ... 999_999_999).contains(start) else { return false }
      let lastOrdinal = start + Int64(max(0, list.items.count - 1))
      let widestMarker = list.items.contains(where: \.hasChecked)
        ? "☑"
        : list.kind == .ordered ? "\(lastOrdinal)." : "•"
      let measuredMarkerWidth = ceil((widestMarker as NSString).size(withAttributes: [
        .font: UIFont.systemFont(ofSize: baseFontSize),
      ]).width) + 6
      let markerWidth = min(max(1, width * 0.4), max(Self.listMarkerWidth, measuredMarkerWidth))
      let listX = x + (rtl ? 0 : Self.listIndent)
      let listWidth = max(1, width - Self.listIndent)
      for (index, item) in list.items.enumerated() {
        if index > 0 { height += 4 }
        let itemPath = BlockContentPath(path.components + [.listItem(index)])
        let marker: String = if item.hasChecked {
          item.checked ? "☑" : "☐"
        } else if list.kind == .ordered {
          "\(start + Int64(index))."
        } else {
          "•"
        }
        let markerFrame = CGRect(
          x: rtl ? listX + listWidth - markerWidth : listX,
          y: height,
          width: markerWidth,
          height: ceil(baseFontSize * 1.3)
        )
        nodes.append(.init(
          path: itemPath,
          frame: markerFrame,
          kind: .text(.init(
            range: NSRange(location: 0, length: 0),
            role: .listMarker,
            literal: marker,
            isRTL: rtl
          ))
        ))
        measuredMaxX = max(measuredMaxX, markerFrame.maxX)
        let itemStart = height
        let childX = rtl ? listX : listX + markerWidth
        guard layout(
          blocks: item.children,
          parent: itemPath,
          x: childX,
          width: max(1, listWidth - markerWidth),
          depth: depth,
          inheritedRTL: rtl,
          isRoot: false
        ) else { return false }
        height = max(height, itemStart + markerFrame.height)
      }
      return true
    }

    mutating func appendQuote(
      _ quote: InlineProtocol.BlockQuote,
      path: BlockContentPath,
      x: CGFloat,
      width: CGFloat,
      depth: Int,
      inheritedRTL: Bool?
    ) -> Bool {
      guard !quote.children.isEmpty else { return false }
      let rtl = quote.hasIsRtl ? quote.isRtl : (inheritedRTL ?? false)
      let startY = height
      let decorationIndex = nodes.count
      nodes.append(.init(
        path: path,
        frame: CGRect(x: x, y: startY, width: width, height: 1),
        kind: .quote(.init(isRTL: rtl))
      ))
      height += Self.quoteVerticalInset
      let contentX = x + (rtl ? Self.quoteTrailingInset : Self.quoteLeadingInset)
      let precedingMaxX = measuredMaxX
      measuredMaxX = 0
      guard layout(
        blocks: quote.children,
        parent: path,
        x: contentX,
        width: max(1, width - Self.quoteLeadingInset - Self.quoteTrailingInset),
        depth: depth,
        inheritedRTL: rtl,
        isRoot: false
      ) else { return false }
      let endingInset = rtl ? Self.quoteLeadingInset : Self.quoteTrailingInset
      measuredMaxX = max(precedingMaxX, measuredMaxX + endingInset)
      height += Self.quoteVerticalInset
      nodes[decorationIndex].frame.size.height = max(1, height - startY)
      return true
    }

    mutating func appendAlbum(
      _ album: InlineProtocol.BlockAlbum,
      path: BlockContentPath,
      x: CGFloat,
      width: CGFloat
    ) -> Bool {
      guard !album.images.isEmpty,
            album.images.count <= 10,
            imageCount + album.images.count <= 64
      else { return false }
      imageCount += album.images.count
      var itemX: CGFloat = 0
      let items = album.images.enumerated().map { index, image in
        let itemWidth = min(220, max(96, Self.albumHeight * imageAspectRatio(image)))
        defer { itemX += itemWidth + Self.albumSpacing }
        let itemPath = BlockContentPath(path.components + [.albumImage(index)])
        return RichBlockLayoutPlanV2.ImageNode(
          path: itemPath,
          frame: CGRect(x: itemX, y: 0, width: itemWidth, height: Self.albumHeight),
          alt: imageAlt(image),
          state: imageState(image)
        )
      }
      let contentWidth = max(0, itemX - Self.albumSpacing)
      let frame = CGRect(x: x, y: height, width: width, height: Self.albumHeight)
      nodes.append(.init(path: path, frame: frame, kind: .album(.init(items: items, contentWidth: contentWidth))))
      measuredMaxX = max(measuredMaxX, frame.maxX)
      claimsMaximumWidth = true
      height = frame.maxY
      return true
    }

    mutating func appendTable(
      _ table: InlineProtocol.BlockTable,
      path: BlockContentPath,
      x: CGFloat,
      width: CGFloat,
      inheritedRTL: Bool?
    ) -> Bool {
      guard let firstRow = table.rows.first,
            !firstRow.cells.isEmpty,
            table.rows.count <= 256,
            firstRow.cells.count <= 64,
            table.rows.count * firstRow.cells.count <= 256,
            tableCellCount + table.rows.count * firstRow.cells.count <= 256,
            table.rows.allSatisfy({ $0.cells.count == firstRow.cells.count })
      else { return false }
      tableCellCount += table.rows.count * firstRow.cells.count
      let rtl = table.hasIsRtl ? table.isRtl : (inheritedRTL ?? false)
      let columns = firstRow.cells.count
      let alignments = (0 ..< columns).map { column in
        tableAlignment(
          column < table.alignments.count ? table.alignments[column] : .unspecified,
          rtl: rtl
        )
      }
      var minimumColumnWidths = Array(repeating: CGFloat(1), count: columns)
      var maximumColumnWidths = Array(repeating: CGFloat(1), count: columns)
      var styledRows: [[NSAttributedString]] = []
      for (rowIndex, row) in table.rows.enumerated() {
        var styledRow: [NSAttributedString] = []
        for (column, cell) in row.cells.enumerated() {
          let range = NSRange(location: Int(cell.offset), length: Int(cell.length))
          guard let styled = RichBlockLayoutPlannerV2.styledTableText(
            from: attributedText,
            range: range,
            baseFontSize: baseFontSize,
            isRTL: rtl,
            alignment: alignments[column],
            isHeader: rowIndex == 0,
            math: math
          ) else { return false }
          styledRow.append(styled)
          let minimumTextWidth = minimumUnbreakableTextWidth(styled)
          let maximumTextWidth = styled.boundingRect(
            with: CGSize(
              width: CGFloat.greatestFiniteMagnitude,
              height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
          ).width
          let minimumCellWidth = ceil(
            max(baseFontSize, minimumTextWidth) + Self.tableHorizontalPadding * 2
          )
          let maximumCellWidth = max(
            minimumCellWidth,
            min(max(1, width), ceil(maximumTextWidth) + Self.tableHorizontalPadding * 2)
          )
          minimumColumnWidths[column] = max(minimumColumnWidths[column], minimumCellWidth)
          maximumColumnWidths[column] = max(maximumColumnWidths[column], maximumCellWidth)
        }
        styledRows.append(styledRow)
      }
      let columnWidths = allocateTableColumnWidths(
        minimum: minimumColumnWidths,
        maximum: maximumColumnWidths,
        viewportWidth: width
      )
      let contentWidth = columnWidths.reduce(0, +)
      var cells: [RichBlockLayoutPlanV2.TableNode.Cell] = []
      var rowY: CGFloat = 0
      for (rowIndex, row) in table.rows.enumerated() {
        var rowHeight = max(32, baseFontSize + Self.tableVerticalPadding * 2)
        for (column, styled) in styledRows[rowIndex].enumerated() {
          rowHeight = max(
            rowHeight,
            measureText(
              styled,
              width: max(1, columnWidths[column] - Self.tableHorizontalPadding * 2)
            ).height
              + Self.tableVerticalPadding * 2
          )
        }
        var cellX: CGFloat = 0
        for (column, cell) in row.cells.enumerated() {
          cells.append(.init(
            range: NSRange(location: Int(cell.offset), length: Int(cell.length)),
            frame: CGRect(
              x: cellX,
              y: rowY,
              width: columnWidths[column],
              height: ceil(rowHeight)
            ),
            alignment: alignments[column],
            isHeader: rowIndex == 0
          ))
          cellX += columnWidths[column]
        }
        rowY += ceil(rowHeight)
      }
      let frame = CGRect(x: x, y: height, width: width, height: rowY)
      nodes.append(.init(
        path: path,
        frame: frame,
        kind: .table(.init(cells: cells, contentWidth: contentWidth, isRTL: rtl))
      ))
      measuredMaxX = max(measuredMaxX, frame.maxX)
      claimsMaximumWidth = true
      height = frame.maxY
      return true
    }

    func minimumUnbreakableTextWidth(_ text: NSAttributedString) -> CGFloat {
      guard text.length > 0,
            let expression = RichBlockLayoutPlannerV2.tableWhitespaceExpression
      else { return 0 }
      let tokens = NSMutableAttributedString(attributedString: text)
      expression.replaceMatches(
        in: tokens.mutableString,
        range: NSRange(location: 0, length: tokens.length),
        withTemplate: "\n"
      )
      return measureText(tokens, width: CGFloat.greatestFiniteMagnitude).maxLineWidth
    }

    func allocateTableColumnWidths(
      minimum: [CGFloat],
      maximum: [CGFloat],
      viewportWidth: CGFloat
    ) -> [CGFloat] {
      guard minimum.count == maximum.count, !minimum.isEmpty else { return [] }
      let resolvedMinimum = zip(minimum, maximum).map { min($0.0, $0.1) }
      let resolvedMaximum = zip(resolvedMinimum, maximum).map { max($0.0, $0.1) }
      let minimumTotal = resolvedMinimum.reduce(0, +)
      let maximumTotal = resolvedMaximum.reduce(0, +)
      if minimumTotal >= viewportWidth { return resolvedMinimum }

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
        let growth: CGFloat = if remainingWeight > 0 {
          weights[index] == remainingWeight
            ? distributable
            : floor(distributable * weights[index] / remainingWeight)
        } else {
          floor(distributable / CGFloat(remainingCount))
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

    func measureText(_ text: NSAttributedString, width: CGFloat) -> TextMeasurement {
      let containerWidth = max(1, width)
      let scale = max(UIScreen.main.scale, 1)
      let widthPixels = containerWidth < CGFloat(Int.max) / scale
        ? Int((containerWidth * scale).rounded())
        : Int.max
      let key = "\(Data(text.string.utf8).hashValue)|\(text.hash)|\(widthPixels)|\(baseFontSize)" as NSString
      // Projected text owns raster attachments. Do not retain it in a cache
      // whose cost only accounts for characters; the rich plan already caches
      // geometry and the shared renderer bounds image memory.
      let cacheable = !RichTextMath.containsRenderedMath(text)
      if cacheable, let cached = RichBlockLayoutPlannerV2.textMeasurementCache.object(forKey: key),
         cached.width == containerWidth,
         cached.text.string.utf8.elementsEqual(text.string.utf8),
         cached.text.isEqual(to: text)
      {
        return cached.measurement
      }
      let textMeasurement = MessageTextMeasurementV2.measure(
        text, maximumWidth: containerWidth, minimumLineHeight: baseFontSize * 1.25
      )
      let measurement = TextMeasurement(
        height: textMeasurement.size.height,
        maxLineWidth: textMeasurement.size.width,
        lastLineWidth: textMeasurement.lastLineWidth,
        lastLineHeight: textMeasurement.lastLineHeight
      )
      if cacheable {
        RichBlockLayoutPlannerV2.textMeasurementCache.setObject(
          TextMeasurementBox(text: text, width: containerWidth, measurement: measurement),
          forKey: key,
          cost: max(128, text.length * 8)
        )
      }
      return measurement
    }

    static func styled(
      _ attributedText: NSAttributedString,
      range: NSRange,
      role: RichBlockTextRoleV2,
      baseFontSize: CGFloat,
      rtl: Bool,
      math: RichTextMath.Snapshot? = nil,
      maximumWidth: CGFloat? = nil
    ) -> NSAttributedString? {
      RichBlockLayoutPlannerV2.styledText(
        from: attributedText,
        range: range,
        role: role,
        baseFontSize: baseFontSize,
        isRTL: rtl,
        math: math,
        maximumWidth: maximumWidth
      )
    }

    func imageSize(_ image: InlineProtocol.BlockImage, availableWidth: CGFloat) -> CGSize {
      let natural = imageDimensions(image) ?? CGSize(width: 240, height: 180)
      let maxSize = CGSize(width: min(availableWidth, 420), height: 420)
      let scale = min(1, min(maxSize.width / max(1, natural.width), maxSize.height / max(1, natural.height)))
      return CGSize(width: floor(natural.width * scale), height: floor(natural.height * scale))
    }

    func imageAspectRatio(_ image: InlineProtocol.BlockImage) -> CGFloat {
      guard let size = imageDimensions(image) else { return 4 / 3 }
      return min(5, max(0.2, size.width / max(1, size.height)))
    }

    func imageDimensions(_ image: InlineProtocol.BlockImage) -> CGSize? {
      let dimensions: (UInt32, UInt32)? = switch image.state {
        case let .pending(pending)?:
          pending.hasDimensions ? (pending.dimensions.width, pending.dimensions.height) : nil
        case let .ready(photo)?:
          photo.sizes.max { Int($0.w) * Int($0.h) < Int($1.w) * Int($1.h) }
            .map { (UInt32(max($0.w, 0)), UInt32(max($0.h, 0))) }
        case let .unavailable(unavailable)?:
          unavailable.hasDimensions ? (unavailable.dimensions.width, unavailable.dimensions.height) : nil
        case nil:
          nil
      }
      guard let dimensions, dimensions.0 > 0, dimensions.1 > 0 else { return nil }
      return CGSize(width: CGFloat(dimensions.0), height: CGFloat(dimensions.1))
    }

    func imageAlt(_ image: InlineProtocol.BlockImage) -> String? {
      let text = image.alt
      guard text.offset >= 0, text.length > 0,
            text.offset <= attributedText.length,
            text.length <= Int64(attributedText.length) - text.offset,
            let range = Range(NSRange(location: Int(text.offset), length: Int(text.length)), in: attributedText.string)
      else { return nil }
      let alt = String(attributedText.string[range]).trimmingCharacters(in: .whitespacesAndNewlines)
      return alt.isEmpty ? nil : alt
    }

    func imageState(_ image: InlineProtocol.BlockImage) -> RichBlockLayoutPlanV2.ImageNode.State {
      switch image.state {
        case .pending?:
          .pending
        case let .ready(photo)?:
          .ready(PhotoInfo(
            photo: Photo.from(proto: photo),
            sizes: photo.sizes.map { PhotoSize.from(proto: $0, photoId: photo.id) }
          ))
        case .unavailable?, nil:
          .unavailable
      }
    }

    func tableAlignment(
      _ alignment: InlineProtocol.BlockTable.Alignment,
      rtl: Bool
    ) -> RichBlockLayoutPlanV2.TableAlignment {
      switch alignment {
        case .center: .center
        case .left: .leading
        case .right: .trailing
        case .unspecified, .UNRECOGNIZED: rtl ? .trailing : .leading
      }
    }
  }
}
