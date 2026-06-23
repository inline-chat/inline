import UIKit
import InlineKit
import TextProcessing
import InlineProtocol

/// Utility class for mention colors in iOS message bubbles
/// This matches the macOS implementation exactly
class MessageRichTextRenderer {
  static func palette(for outgoing: Bool) -> ProcessEntities.Configuration.Palette {
    .init(
      primaryColor: primaryColor(for: outgoing),
      linkColor: linkColor(for: outgoing),
      secondaryColor: secondaryColor(for: outgoing)
    )
  }

  static func cacheKey(for outgoing: Bool) -> String {
    "\(ThemeManager.shared.selected.id)-\(outgoing ? "outgoing" : "incoming")"
  }

  static func primaryColor(for outgoing: Bool) -> UIColor {
    if outgoing {
      UIColor.white
    } else {
      ThemeManager.shared.selected.primaryTextColor ?? .label
    }
  }

  /// Gets the appropriate mention color based on message direction
  /// - Parameter outgoing: Whether the message is outgoing
  /// - Returns: The color to use for mentions (white for outgoing, blue for incoming)
  static func mentionColor(for outgoing: Bool) -> UIColor {
    if outgoing {
      UIColor.white
    } else {
      ThemeManager.shared.selected.accent
    }
  }

  /// Gets the appropriate link color based on message direction
  /// - Parameter outgoing: Whether the message is outgoing
  /// - Returns: The color to use for links
  static func linkColor(for outgoing: Bool) -> UIColor {
    if outgoing {
      UIColor.white
    } else {
      ThemeManager.shared.selected.accent
    }
  }

  static func secondaryColor(for outgoing: Bool) -> UIColor {
    if outgoing {
      UIColor.white.withAlphaComponent(0.7)
    } else {
      ThemeManager.shared.selected.secondaryTextColor ?? .secondaryLabel
    }
  }

  static func applyRichBlockStyles(
    to attributedString: NSMutableAttributedString,
    richText: RichMessage,
    baseFont: UIFont
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
          value: UIFont.systemFont(ofSize: size, weight: .semibold),
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
