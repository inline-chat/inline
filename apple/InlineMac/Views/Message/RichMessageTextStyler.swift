import AppKit
import InlineKit
import InlineProtocol

enum RichMessageTextStyler {
  static func applyBlockStyles(
    to attributedString: NSMutableAttributedString,
    richText: RichMessage,
    baseFont: NSFont
  ) {
    var cursor = 0
    for block in richText.blocks {
      let text = fallbackText(for: block, index: 0, depth: 0)
      guard !text.isEmpty else { continue }

      let searchRange = NSRange(location: cursor, length: max(0, attributedString.length - cursor))
      let range = (attributedString.string as NSString).range(of: text, options: [], range: searchRange)
      guard range.location != NSNotFound else { continue }

      applyParagraphDirection(block.direction, to: attributedString, range: range)
      if case let .heading(heading)? = block.block {
        let size = headingFontSize(baseFont.pointSize, level: heading.level == 0 ? 1 : heading.level)
        attributedString.addAttribute(
          .font,
          value: NSFont.systemFont(ofSize: size, weight: .semibold),
          range: range
        )
      }

      cursor = range.location + range.length
    }
  }

  private static func applyParagraphDirection(
    _ direction: RichDirection,
    to attributedString: NSMutableAttributedString,
    range: NSRange
  ) {
    guard direction == .directionLtr || direction == .directionRtl else { return }

    let style = NSMutableParagraphStyle()
    style.baseWritingDirection = direction == .directionRtl ? .rightToLeft : .leftToRight
    style.alignment = direction == .directionRtl ? .right : .left
    attributedString.addAttribute(.paragraphStyle, value: style, range: range)
  }

  private static func headingFontSize(_ base: CGFloat, level: Int32) -> CGFloat {
    switch level {
    case 1: base + 7
    case 2: base + 5
    case 3: base + 3
    default: base + 1
    }
  }

  private static func fallbackText(for block: RichBlock, index: Int, depth: Int) -> String {
    block.renderedFallbackText(index: index, depth: depth)
  }
}
