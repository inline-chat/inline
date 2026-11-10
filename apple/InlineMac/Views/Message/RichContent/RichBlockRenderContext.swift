import AppKit
import InlineKit
import TextProcessing

/// Presentation only: both modes consume the same raw code text and layout plan.
enum RichBlockCodePresentation: String, Codable, Hashable {
  case plain
  case syntaxHighlighted

  var title: String {
    switch self {
    case .plain: "Plain"
    case .syntaxHighlighted: "Syntax highlighted"
    }
  }
}

struct RichBlockPalette {
  let primary: NSColor
  let secondary: NSColor
  let tertiary: NSColor
  let link: NSColor
  let subtleFill: NSColor
  let codeFill: NSColor
  let separator: NSColor
  let placeholder: NSColor

  init(primary: NSColor, secondary: NSColor, tertiary: NSColor, link: NSColor) {
    self.primary = primary
    self.secondary = secondary
    self.tertiary = tertiary
    self.link = link
    subtleFill = primary.withAlphaComponent(0.045)
    codeFill = primary.withAlphaComponent(0.065)
    separator = primary.withAlphaComponent(0.14)
    placeholder = primary.withAlphaComponent(0.075)
  }
}

struct RichBlockInteractions {
  let onTextEntityClick: (MessageTextEntityHit, NSAttributedString) -> Bool
  let onDisclosureToggle: (BlockContentPath, Bool) -> Void
  let onImageClick: (BlockImageOccurrence) -> Void
}

/// The styled text each node got on the previous bind of one content view, so a
/// rebind restyles only nodes whose inputs changed. Main thread only.
final class RichBlockStyledTextCache {
  /// Inputs shared by every node of a bind. Any change clears the cache.
  struct Environment: Equatable {
    var baseFontSize: CGFloat
    var mathSignature: Int
    /// Without formulas the inline projection ignores the width, so it is left
    /// out of the keys and resizing does not restyle.
    var hasMath: Bool
    var primary: ResolvedColor
    var secondary: ResolvedColor
    var link: ResolvedColor

    /// Resolves the palette in `appearance`, so a light/dark switch restyles.
    init(baseFontSize: CGFloat, math: RichTextMath.Snapshot, palette: RichBlockPalette, appearance: NSAppearance) {
      self.baseFontSize = baseFontSize
      mathSignature = math.signature
      hasMath = !math.requests.isEmpty
      func resolve() -> (ResolvedColor, ResolvedColor, ResolvedColor) {
        (ResolvedColor(palette.primary), ResolvedColor(palette.secondary), ResolvedColor(palette.link))
      }
      var resolved: (ResolvedColor, ResolvedColor, ResolvedColor)?
      appearance.performAsCurrentDrawingAppearance {
        resolved = resolve()
      }
      (primary, secondary, link) = resolved ?? resolve()
    }
  }

  /// Theme colors are dynamic and recreated on access, so compare what they
  /// resolve to. Colors without RGB components compare as objects.
  struct ResolvedColor: Equatable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat
    let unresolved: NSColor?

    init(_ color: NSColor) {
      if let resolved = color.usingColorSpace(.deviceRGB) {
        red = resolved.redComponent
        green = resolved.greenComponent
        blue = resolved.blueComponent
        alpha = resolved.alphaComponent
        unresolved = nil
      } else {
        red = 0
        green = 0
        blue = 0
        alpha = 0
        unresolved = color
      }
    }
  }

  struct Key: Hashable {
    enum Style: Hashable {
      case text(role: RichBlockTextRole, literal: String?)
      case tableCell(alignment: RichBlockLayoutPlan.TableAlignment, isHeader: Bool)
    }

    var offset: Int
    var length: Int
    var style: Style
    var isRTL: Bool
    var maximumWidth: CGFloat?
  }

  private struct Entry {
    /// The source characters and attributes it was styled from; nil for literals.
    var slice: NSAttributedString?
    var output: NSAttributedString
    var sourceGeneration: UInt64
    var pass: UInt64
  }

  private var environment: Environment?
  private var source: NSAttributedString?
  private var sourceGeneration: UInt64 = 0
  private var pass: UInt64 = 0
  private var entries: [Key: Entry] = [:]

  /// Starts a bind. Drops styles the previous bind did not use.
  func begin(source: NSAttributedString, environment: Environment) {
    if self.environment != environment {
      entries.removeAll(keepingCapacity: true)
      self.environment = environment
    } else if !entries.isEmpty {
      let lastPass = pass
      entries = entries.filter { $0.value.pass == lastPass }
    }
    if self.source !== source {
      self.source = source
      sourceGeneration &+= 1
    }
    pass &+= 1
  }

  func removeAll() {
    entries.removeAll()
    environment = nil
    source = nil
  }

  func width(_ maximumWidth: CGFloat?) -> CGFloat? {
    environment?.hasMath == false ? nil : maximumWidth
  }

  /// Returns the previous output when the slice is unchanged, else `make`'s
  /// result for the freshly cut slice (nil for literals). The range is valid.
  func styled(
    _ key: Key,
    in source: NSAttributedString,
    cutsSlice: Bool,
    make: (NSAttributedString?) -> NSAttributedString
  ) -> NSAttributedString {
    guard source === self.source else { return make(nil) }
    let slice: NSAttributedString?
    if var entry = entries[key] {
      // Same source object: nothing to compare. A new source (a streamed edit)
      // compares this node's slice only.
      if entry.sourceGeneration == sourceGeneration || entry.slice == nil {
        entry.pass = pass
        entries[key] = entry
        return entry.output
      }
      let current = cutsSlice ? sliceOf(source, key) : nil
      if let current, let previous = entry.slice, current.isEqual(to: previous) {
        entry.sourceGeneration = sourceGeneration
        entry.pass = pass
        entries[key] = entry
        return entry.output
      }
      slice = current
    } else {
      slice = cutsSlice ? sliceOf(source, key) : nil
    }
    let output = make(slice)
    entries[key] = Entry(slice: slice, output: output, sourceGeneration: sourceGeneration, pass: pass)
    return output
  }

  private func sliceOf(_ source: NSAttributedString, _ key: Key) -> NSAttributedString {
    source.attributedSubstring(from: NSRange(location: key.offset, length: key.length))
  }
}

struct RichBlockRenderContext {
  let math: RichTextMath.Snapshot
  let attributedText: NSAttributedString
  let baseFontSize: CGFloat
  let palette: RichBlockPalette
  let relatedMessage: Message
  let interactions: RichBlockInteractions
  let isContentVisible: Bool
  let codePresentation: RichBlockCodePresentation
  let renderStyle: MessageRenderStyle
  let contentHorizontalInset: CGFloat
  /// Reuses unchanged node styles across binds; nil styles every call.
  var styleCache: RichBlockStyledTextCache? = nil

  func text(for node: RichBlockLayoutPlan.TextNode, maximumWidth: CGFloat? = nil) -> NSAttributedString {
    let isLiteral = node.literal != nil
    guard let styleCache, isLiteral || isValidRange(offset: node.rangeOffset, length: node.rangeLength) else {
      return makeText(for: node, slice: nil, maximumWidth: maximumWidth)
    }
    let key = RichBlockStyledTextCache.Key(
      offset: node.rangeOffset,
      length: node.rangeLength,
      style: .text(role: node.role, literal: node.literal),
      isRTL: node.isRTL,
      maximumWidth: styleCache.width(maximumWidth)
    )
    return styleCache.styled(key, in: attributedText, cutsSlice: !isLiteral) { slice in
      makeText(for: node, slice: slice, maximumWidth: maximumWidth)
    }
  }

  private func makeText(
    for node: RichBlockLayoutPlan.TextNode,
    slice: NSAttributedString?,
    maximumWidth: CGFloat?
  ) -> NSAttributedString {
    let value: NSMutableAttributedString
    if let literal = node.literal {
      value = NSMutableAttributedString(
        string: literal,
        attributes: [
          .font: ChatTypography.current.font(sized: baseFontSize),
          .foregroundColor: palette.primary,
          .paragraphStyle: paragraphStyle(isRTL: node.isRTL),
        ]
      )
    } else if let slice {
      value = NSMutableAttributedString(attributedString: RichBlockLayoutPlanner.styledSlice(
        slice,
        sourceOffset: node.rangeOffset,
        role: node.role,
        baseFontSize: baseFontSize,
        isRTL: node.isRTL,
        math: math,
        maximumWidth: maximumWidth
      ))
    } else {
      value = NSMutableAttributedString(
        attributedString: RichBlockLayoutPlanner.styledText(
          attributedText,
          offset: node.rangeOffset,
          length: node.rangeLength,
          role: node.role,
          baseFontSize: baseFontSize,
          isRTL: node.isRTL,
          math: math,
          maximumWidth: maximumWidth
        ) ?? NSAttributedString()
      )
    }

    if case .disclosureSummary = node.role {
      // The whole row toggles the disclosure.
      LinkDetector.shared.removeLinks(from: value)
    }
    let fullRange = NSRange(location: 0, length: value.length)
    switch node.role {
    case .footer, .disclosureSummary:
      value.addAttribute(.foregroundColor, value: palette.secondary, range: fullRange)
    default:
      break
    }
    value.enumerateAttribute(.link, in: fullRange) { link, range, _ in
      guard link != nil else { return }
      value.addAttributes([
        .foregroundColor: palette.link,
        .cursor: NSCursor.pointingHand,
      ], range: range)
    }
    return value
  }

  func tableText(
    for cell: RichBlockLayoutPlan.TableNode.Cell,
    isRTL: Bool
  ) -> NSAttributedString {
    guard let styleCache, isValidRange(offset: cell.rangeOffset, length: cell.rangeLength) else {
      return makeTableText(for: cell, isRTL: isRTL, slice: nil)
    }
    let key = RichBlockStyledTextCache.Key(
      offset: cell.rangeOffset,
      length: cell.rangeLength,
      style: .tableCell(alignment: cell.alignment, isHeader: cell.isHeader),
      isRTL: isRTL,
      maximumWidth: nil
    )
    return styleCache.styled(key, in: attributedText, cutsSlice: true) { slice in
      makeTableText(for: cell, isRTL: isRTL, slice: slice)
    }
  }

  private func makeTableText(
    for cell: RichBlockLayoutPlan.TableNode.Cell,
    isRTL: Bool,
    slice: NSAttributedString?
  ) -> NSAttributedString {
    let value: NSMutableAttributedString
    if let slice {
      value = NSMutableAttributedString(attributedString: RichBlockLayoutPlanner.styledTableSlice(
        slice,
        sourceOffset: cell.rangeOffset,
        baseFontSize: baseFontSize,
        isRTL: isRTL,
        alignment: cell.alignment,
        isHeader: cell.isHeader,
        math: math
      ))
    } else {
      value = NSMutableAttributedString(
        attributedString: RichBlockLayoutPlanner.styledTableText(
          attributedText,
          offset: cell.rangeOffset,
          length: cell.rangeLength,
          baseFontSize: baseFontSize,
          isRTL: isRTL,
          alignment: cell.alignment,
          isHeader: cell.isHeader,
          math: math
        ) ?? NSAttributedString()
      )
    }
    let range = NSRange(location: 0, length: value.length)
    value.addAttribute(.foregroundColor, value: palette.primary, range: range)
    value.enumerateAttribute(.link, in: range) { link, linkRange, _ in
      guard link != nil else { return }
      value.addAttributes([
        .foregroundColor: palette.link,
        .cursor: NSCursor.pointingHand,
      ], range: linkRange)
    }
    return value
  }

  func codeText(for node: RichBlockLayoutPlan.CodeNode) -> NSAttributedString {
    guard node.rangeOffset >= 0,
          node.rangeLength >= 0,
          node.rangeOffset <= attributedText.length,
          node.rangeLength <= attributedText.length - node.rangeOffset
    else { return NSAttributedString() }
    let paragraph = NSMutableParagraphStyle()
    paragraph.baseWritingDirection = .leftToRight
    paragraph.alignment = .left
    return NSAttributedString(
      string: (attributedText.string as NSString).substring(
        with: NSRange(location: node.rangeOffset, length: node.rangeLength)
      ),
      attributes: [
        .font: RichBlockCodeMetrics.bodyFont,
        .foregroundColor: palette.primary,
        .paragraphStyle: paragraph,
      ]
    )
  }

  private func isValidRange(offset: Int, length: Int) -> Bool {
    offset >= 0 && length >= 0 && offset <= attributedText.length && length <= attributedText.length - offset
  }

  private func paragraphStyle(isRTL: Bool) -> NSParagraphStyle {
    let paragraph = NSMutableParagraphStyle()
    paragraph.baseWritingDirection = isRTL ? .rightToLeft : .leftToRight
    paragraph.alignment = isRTL ? .right : .left
    return paragraph
  }
}
