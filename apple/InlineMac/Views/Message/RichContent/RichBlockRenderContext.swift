import AppKit
import InlineKit

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
}

struct RichBlockRenderContext {
  let attributedText: NSAttributedString
  let baseFontSize: CGFloat
  let palette: RichBlockPalette
  let relatedMessage: Message
  let interactions: RichBlockInteractions
  let isContentVisible: Bool
  let codePresentation: RichBlockCodePresentation
  let renderStyle: MessageRenderStyle
  let contentHorizontalInset: CGFloat

  func text(for node: RichBlockLayoutPlan.TextNode) -> NSAttributedString {
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
    } else {
      value = NSMutableAttributedString(
        attributedString: RichBlockLayoutPlanner.styledText(
          attributedText,
          offset: node.rangeOffset,
          length: node.rangeLength,
          role: node.role,
          baseFontSize: baseFontSize,
          isRTL: node.isRTL
        ) ?? NSAttributedString()
      )
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
    let value = NSMutableAttributedString(
      attributedString: RichBlockLayoutPlanner.styledTableText(
        attributedText,
        offset: cell.rangeOffset,
        length: cell.rangeLength,
        baseFontSize: baseFontSize,
        isRTL: isRTL,
        alignment: cell.alignment,
        isHeader: cell.isHeader
      ) ?? NSAttributedString()
    )
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

  private func paragraphStyle(isRTL: Bool) -> NSParagraphStyle {
    let paragraph = NSMutableParagraphStyle()
    paragraph.baseWritingDirection = isRTL ? .rightToLeft : .leftToRight
    paragraph.alignment = isRTL ? .right : .left
    return paragraph
  }
}
