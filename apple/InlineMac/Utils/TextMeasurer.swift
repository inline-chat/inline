import AppKit
import CoreText

struct TextMeasurer {
  private let attributes: [NSAttributedString.Key: Any]
  private let extraWidth: CGFloat
  private let extraHeight: CGFloat

  init(
    font: NSFont,
    lineBreakMode: NSLineBreakMode = .byWordWrapping,
    extraWidth: CGFloat = 0,
    extraHeight: CGFloat = 0
  ) {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineBreakMode = lineBreakMode

    attributes = [
      .font: font,
      .paragraphStyle: paragraphStyle,
    ]
    self.extraWidth = extraWidth
    self.extraHeight = extraHeight
  }

  func measure(_ text: String, width: CGFloat) -> NSSize {
    let attributedString = NSAttributedString(string: text, attributes: attributes)
    return measure(attributedString, width: width)
  }

  func measure(_ attributedString: NSAttributedString, width: CGFloat) -> NSSize {
    guard attributedString.length > 0 else { return .zero }

    let constraintSize = CGSize(width: max(1, ceil(width)), height: CGFloat.greatestFiniteMagnitude)
    let typesetter = CTTypesetterCreateWithAttributedStringAndOptions(attributedString, nil)
    let frameSize: CGSize
    if typesetter == nil, paragraphsPassLayoutGuard(attributedString) {
      // Core Text can overestimate a long RTL document even when its individual
      // paragraphs are safe to lay out. Match the message view's paragraph-based engine.
      frameSize = measureWithTextKit(attributedString, size: constraintSize)
    } else {
      // Keep the original conservative measurement for a paragraph that itself
      // exceeds the guard. Protected TextKit can omit that paragraph entirely.
      let framesetter = typesetter.map { CTFramesetterCreateWithTypesetter($0) }
        ?? CTFramesetterCreateWithAttributedString(attributedString)
      frameSize = CTFramesetterSuggestFrameSizeWithConstraints(
        framesetter,
        CFRange(location: 0, length: attributedString.length),
        nil,
        constraintSize,
        nil
      )
    }

    return CGSize(
      width: ceil(frameSize.width) + extraWidth,
      height: ceil(frameSize.height) + extraHeight
    )
  }

  private func paragraphsPassLayoutGuard(_ attributedString: NSAttributedString) -> Bool {
    let text = attributedString.string as NSString
    var location = 0
    while location < text.length {
      let range = text.paragraphRange(for: NSRange(location: location, length: 0))
      let paragraph = attributedString.attributedSubstring(from: range)
      guard CTTypesetterCreateWithAttributedStringAndOptions(paragraph, nil) != nil else {
        return false
      }
      location = NSMaxRange(range)
    }
    return true
  }

  private func measureWithTextKit(_ attributedString: NSAttributedString, size: CGSize) -> CGSize {
    // This performs full-document layout and is expensive on a row-height cache
    // miss. Keep ordinary text on Core Text; this is not a scroll-performance fix.
    let contentStorage = NSTextContentStorage()
    let layoutManager = NSTextLayoutManager()
    layoutManager.limitsLayoutForSuspiciousContents = true
    contentStorage.addTextLayoutManager(layoutManager)
    let container = NSTextContainer(size: size)
    container.lineFragmentPadding = 0
    layoutManager.textContainer = container
    contentStorage.textStorage?.setAttributedString(attributedString)
    layoutManager.ensureLayout(for: layoutManager.documentRange)

    var height: CGFloat = 0
    var contentWidth: CGFloat = 0
    layoutManager.enumerateTextLayoutFragments(
      from: layoutManager.documentRange.location,
      options: [.ensuresLayout]
    ) { fragment in
      for line in fragment.textLineFragments where line.characterRange.length > 0 {
        contentWidth = max(contentWidth, line.typographicBounds.width)
      }
      var bottom = fragment.layoutFragmentFrame.maxY
      if fragment.textLineFragments.last?.characterRange.length == 0 {
        // TextKit also lays out a caret-only line after a final newline. It has
        // no message characters and uses editor typing attributes, so exclude it.
        bottom = fragment.layoutFragmentFrame.minY
        for line in fragment.textLineFragments where line.characterRange.length > 0 {
          bottom = max(bottom, fragment.layoutFragmentFrame.minY + line.typographicBounds.maxY)
        }
      }
      height = max(height, bottom)
      return true
    }
    // Unindented text can use its natural line width. Indents and tab stops are
    // relative to the container; shrinking it can change wrapping after sizing.
    var usesContainerRelativeLayout = false
    attributedString.enumerateAttribute(
      .paragraphStyle, in: NSRange(location: 0, length: attributedString.length)
    ) { value, _, stop in
      guard let style = value as? NSParagraphStyle else { return }
      if style.firstLineHeadIndent != 0 || style.headIndent != 0 || style.tailIndent != 0 {
        usesContainerRelativeLayout = true
        stop.pointee = true
      }
    }
    if attributedString.string.contains("\t") { usesContainerRelativeLayout = true }
    return CGSize(width: usesContainerRelativeLayout ? size.width : min(size.width, ceil(contentWidth)), height: height)
  }
}
