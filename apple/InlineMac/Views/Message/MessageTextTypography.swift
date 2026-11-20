import AppKit
import InlineKit
import InlineProtocol
import TextProcessing

/// Builds message text with the chat typography. Sizing (`MessageSizeCalculator`)
/// and rendering (`MessageView`, `MinimalMessageView`) both go through here, so a
/// row is always measured with exactly the fonts and line spacing it draws with.
enum MessageTextTypography {
  /// Point size for a message: the chat size, or a larger one for emoji-only text.
  static func fontSize(
    emojiInfo: (count: Int, isAllEmojis: Bool),
    typography: ChatTypography = .current
  ) -> CGFloat {
    switch emojiInfo {
    case let (count, true) where count == 1:
      typography.singleEmojiPointSize
    case let (count, true) where count <= 3:
      typography.threeEmojisPointSize
    case (_, true):
      typography.manyEmojisPointSize
    default:
      typography.pointSize
    }
  }

  /// Line spacing for text drawn at `fontSize`. Emoji-only sizes keep their
  /// natural lines; code blocks keep their own spacing.
  static func lineSpacing(fontSize: CGFloat, typography: ChatTypography = .current) -> CGFloat {
    guard fontSize == typography.pointSize else { return 0 }
    return typography.lineSpacing(forPointSize: fontSize)
  }

  static func attributedText(
    text: String,
    entities: MessageEntities?,
    fontSize: CGFloat,
    palette: ProcessEntities.Configuration.Palette,
    codeBlockBackgroundColor: NSColor? = nil,
    inlineCodeBackgroundColor: NSColor? = nil,
    typography: ChatTypography = .current
  ) -> NSMutableAttributedString {
    let value = ProcessEntities.toAttributedString(
      text: text,
      entities: entities,
      configuration: .init(
        font: typography.font(sized: fontSize),
        boldWeight: .semibold,
        monospaceBaseFont: typography.monospaceBaseFont(sized: fontSize),
        palette: palette,
        codeBlockBackgroundColor: codeBlockBackgroundColor,
        inlineCodeBackgroundColor: inlineCodeBackgroundColor
      )
    )
    applyCodeFont(to: value, fontSize: fontSize, typography: typography)
    applyLineSpacing(to: value, fontSize: fontSize, typography: typography)
    applyParagraphSpacing(to: value, fontSize: fontSize, typography: typography)
    return value
  }

  /// Entity processing sizes code from its own rule (1 pt smaller, SF Mono); use
  /// the chat scale's code sizes and the chosen code family, at each run's weight.
  static func applyCodeFont(
    to value: NSMutableAttributedString,
    fontSize: CGFloat,
    typography: ChatTypography = .current
  ) {
    guard value.length > 0 else { return }
    let fullRange = NSRange(location: 0, length: value.length)
    let inlineSize = ChatTypography.inlineCodePointSize(at: fontSize)
    let blockSize = ChatTypography.codeBlockPointSize(at: fontSize)
    var updates: [(NSRange, NSFont)] = []
    value.enumerateAttribute(.font, in: fullRange) { font, range, _ in
      guard let font = font as? NSFont else { return }
      let size: CGFloat
      if value.attribute(.preCode, at: range.location, effectiveRange: nil) != nil {
        size = blockSize
      } else if value.attribute(.inlineCode, at: range.location, effectiveRange: nil) != nil {
        size = inlineSize
      } else {
        return
      }
      let isBold = font.fontDescriptor.symbolicTraits.contains(.bold)
      updates.append((range, typography.codeFont(sized: size, weight: isBold ? .semibold : .regular)))
    }
    for (range, font) in updates {
      value.addAttribute(.font, value: font, range: range)
    }
  }

  /// Blank lines become a paragraph gap and consecutive list lines ("- ", "• ",
  /// "1. ") get the list-item gap, matching rich text. Text is never changed, so
  /// selection and copy see exactly what was sent. Code and emoji-only text keep
  /// their own lines.
  static func applyParagraphSpacing(
    to value: NSMutableAttributedString,
    fontSize: CGFloat,
    typography: ChatTypography = .current
  ) {
    guard fontSize == typography.pointSize, value.length > 0 else { return }
    let blankHeight = ChatTypography.space(.paragraph, at: fontSize)
    let itemGap = ChatTypography.space(.listItem, at: fontSize)
    let string = value.string as NSString
    var location = 0
    var previousIsListLine = false
    var updates: [(NSRange, NSParagraphStyle)] = []
    while location < string.length {
      let range = string.paragraphRange(for: NSRange(location: location, length: 0))
      location = NSMaxRange(range)
      let isCode = value.attribute(.preCode, at: range.location, effectiveRange: nil) != nil
      let content = string.substring(with: range).trimmingCharacters(in: .newlines)
      let isListLine = !isCode && isPlainListLine(content)
      defer { previousIsListLine = isListLine }
      guard !isCode else { continue }

      let existing = value.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
      if content.isEmpty {
        let style = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.minimumLineHeight = blankHeight
        style.maximumLineHeight = blankHeight
        style.lineSpacing = 0
        updates.append((range, style))
      } else if isListLine, previousIsListLine {
        let style = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.paragraphSpacingBefore = itemGap
        updates.append((range, style))
      }
    }
    for (range, style) in updates {
      value.addAttribute(.paragraphStyle, value: style, range: range)
    }
  }

  /// A line that reads as a list item in plain text: a dash, star, plus or bullet
  /// followed by a space, or a number with "." or ")" and a space. Leading spaces
  /// (nesting) are allowed.
  static func isPlainListLine(_ line: String) -> Bool {
    let trimmed = line.drop { $0 == " " || $0 == "\t" }
    guard let first = trimmed.first else { return false }
    if "-*+\u{2022}".contains(first) {
      return trimmed.dropFirst().first == " "
    }
    let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
    guard !digits.isEmpty, digits.count <= 4 else { return false }
    let rest = trimmed.dropFirst(digits.count)
    guard let marker = rest.first, marker == "." || marker == ")" else { return false }
    return rest.dropFirst().first == " "
  }

  static func applyLineSpacing(
    to value: NSMutableAttributedString,
    fontSize: CGFloat,
    typography: ChatTypography = .current
  ) {
    let spacing = lineSpacing(fontSize: fontSize, typography: typography)
    guard spacing > 0 else { return }
    ChatTypography.applyLineSpacing(spacing, to: value) { range in
      value.attribute(.preCode, at: range.location, effectiveRange: nil) != nil
    }
  }
}
