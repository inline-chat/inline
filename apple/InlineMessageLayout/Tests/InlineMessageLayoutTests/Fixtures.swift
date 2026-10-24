import CoreGraphics
import CoreText
import Foundation
@testable import InlineMessageLayout

enum Fixtures {
  static let grid = PixelGrid(scale: 3)
  static var body: CTFont { font(17) }
  static var caption: CTFont { font(11) }

  static func font(_ size: CGFloat) -> CTFont {
    CTFontCreateUIFontForLanguage(.system, size, nil)!
  }

  static func text(_ string: String, font: CTFont = body) -> MessageText {
    MessageText(NSAttributedString(
      string: string,
      attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
    ))
  }

  static let time = text("12:34", font: caption)
  static let reaction = MessageLayoutInput.Reaction(id: "👍", size: CGSize(width: 44, height: 26))

  static func message(
    _ string: String,
    rowWidth: CGFloat = 390,
    outgoing: Bool = false,
    reactions: [MessageLayoutInput.Reaction] = [],
    footer: MessageLayoutInput.Footer.Visibility = .visible,
    direction: TextDirection = .leftToRight,
    tail: BubbleTailSide? = nil,
    avatar: MessageLayoutInput.Avatar = .none,
    emoji: Bool = false
  ) -> MessageLayoutInput {
    MessageLayoutInput(
      rowWidth: rowWidth,
      grid: grid,
      layoutDirection: direction,
      isOutgoing: outgoing,
      tail: tail ?? (outgoing ? .trailing : .leading),
      avatar: avatar,
      body: emoji ? .emoji(text(string, font: font(80))) : .text(text(string)),
      footer: .init(
        time: time,
        statusSize: outgoing ? CGSize(width: 11, height: 11) : nil,
        visibility: footer
      ),
      reactions: reactions
    )
  }

  static func isFinite(_ rect: CGRect) -> Bool {
    rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
      && rect.width >= 0 && rect.height >= 0
  }
}
