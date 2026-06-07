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

    let frameSetter = CTFramesetterCreateWithAttributedString(attributedString)
    let constraintSize = CGSize(width: max(1, ceil(width)), height: CGFloat.greatestFiniteMagnitude)
    let frameSize = CTFramesetterSuggestFrameSizeWithConstraints(
      frameSetter,
      CFRange(location: 0, length: attributedString.length),
      nil,
      constraintSize,
      nil
    )

    return CGSize(
      width: ceil(frameSize.width) + extraWidth,
      height: ceil(frameSize.height) + extraHeight
    )
  }
}
