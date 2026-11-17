import CoreGraphics
import Foundation

/// A paragraph's geometry, set on its text under `attributeKey`: what a platform paragraph style
/// (`NSParagraphStyle`) says about indents and spacing, in a form this package can read. Where
/// a paragraph has it, it replaces `TextLayoutStyle`'s spacing for that paragraph.
public struct TextParagraphMetrics: Hashable, Sendable {
  public var firstLineHeadIndent: CGFloat
  public var headIndent: CGFloat
  /// Negative: distance in from the trailing edge. Positive: the line's end from the leading
  /// edge. Zero: no indent.
  public var tailIndent: CGFloat
  public var lineSpacing: CGFloat
  public var spacingBefore: CGFloat
  public var spacingAfter: CGFloat

  public init(
    firstLineHeadIndent: CGFloat = 0,
    headIndent: CGFloat = 0,
    tailIndent: CGFloat = 0,
    lineSpacing: CGFloat = 0,
    spacingBefore: CGFloat = 0,
    spacingAfter: CGFloat = 0
  ) {
    self.firstLineHeadIndent = firstLineHeadIndent
    self.headIndent = headIndent
    self.tailIndent = tailIndent
    self.lineSpacing = lineSpacing
    self.spacingBefore = spacingBefore
    self.spacingAfter = spacingAfter
  }

  public static let attributeKey = NSAttributedString.Key("InlineMessageLayout.paragraphMetrics")

  static func at(_ index: Int, in text: NSAttributedString) -> TextParagraphMetrics? {
    guard index < text.length else { return nil }
    return text.attribute(attributeKey, at: index, effectiveRange: nil) as? TextParagraphMetrics
  }
}
