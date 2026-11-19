import AppKit

/// Rich and plain message spacing as multiples of the message font size (em), so
/// the rhythm holds at every text size. Values come from tuning in the typography
/// lab and sit on 1/8 em steps; each is rounded to whole points only when used.
///
/// Gaps are whitespace beyond the normal line rhythm, the same in plain text (blank
/// lines, list lines) and rich text (gaps between blocks). A rich block laid out on
/// its own drops the line spacing after its last line, so gaps between two text
/// blocks add it back (`textGap`).
public extension ChatTypography {
  enum Space: Sendable {
    /// Between paragraphs, and the height of a blank line in plain text.
    case paragraph
    /// Between list items, rich or plain.
    case listItem
    /// Around lists, quotes, code and other blocks.
    case block
    case headingAbove
    case headingBelow
    /// Extra room where a heading opens a message, or a quote or code block opens
    /// or closes one: bubble side padding minus its top padding, so the block sits
    /// evenly inset.
    case bubbleEdge

    case listInset
    /// Marker column width; text starts after it.
    case listMarkerColumn
    /// Dots sit farther from their text than wider numbers and checkboxes do.
    case bulletToText
    case numberToText

    case quoteLeadingInset
    /// Room for the quote mark on the trailing side.
    case quoteTrailingInset
    case quoteVerticalInset

    /// Code block padding on every side, and between line numbers and code.
    case codePadding
    /// Between the language header and the first line of code.
    case codeHeaderToBody

    public var em: CGFloat {
      switch self {
      case .paragraph: 0.875
      case .listItem: 0.375
      case .block: 0.5
      case .headingAbove: 1.125
      case .headingBelow: 0.625
      case .bubbleEdge: 0.375
      case .listInset: 0.5
      case .listMarkerColumn: 1.25
      case .bulletToText: 1
      case .numberToText: 0.5
      case .quoteLeadingInset: 0.75
      case .quoteTrailingInset: 1.25
      case .quoteVerticalInset: 0.5
      case .codePadding: 0.75
      case .codeHeaderToBody: 0.125
      }
    }
  }

  /// Heading sizes step down by halves: +1/4, +1/8, +1/16 of the body size.
  static func headingScale(level: Int) -> CGFloat {
    switch level {
    case ...1: 1.25
    case 2: 1.125
    case 3: 1.0625
    default: 1
    }
  }

  static let headingWeight: NSFont.Weight = .semibold
  static let codeBlockScale: CGFloat = 0.9
  static let inlineCodeScale: CGFloat = 0.95
  static let bulletDiameterEm: CGFloat = 0.3

  /// `space` in whole points for text at `pointSize`.
  static func space(_ space: Space, at pointSize: CGFloat) -> CGFloat {
    (space.em * pointSize).rounded()
  }

  func space(_ space: Space) -> CGFloat {
    Self.space(space, at: pointSize)
  }

  /// A gap between two text blocks at `pointSize`, plus the line spacing the
  /// earlier block drops after its last line.
  func textGap(_ space: Space, at pointSize: CGFloat) -> CGFloat {
    Self.space(space, at: pointSize) + lineSpacing(forPointSize: pointSize)
  }

  /// Rounded to half points, for derived font sizes.
  static func halfPoint(_ value: CGFloat) -> CGFloat {
    (value * 2).rounded() / 2
  }

  static func codeBlockPointSize(at pointSize: CGFloat) -> CGFloat {
    halfPoint(pointSize * codeBlockScale)
  }

  static func inlineCodePointSize(at pointSize: CGFloat) -> CGFloat {
    halfPoint(pointSize * inlineCodeScale)
  }

  static func headingPointSize(level: Int, at pointSize: CGFloat) -> CGFloat {
    halfPoint(pointSize * headingScale(level: level))
  }

  static func bulletDiameter(at pointSize: CGFloat) -> CGFloat {
    max(3, halfPoint(pointSize * bulletDiameterEm))
  }
}
