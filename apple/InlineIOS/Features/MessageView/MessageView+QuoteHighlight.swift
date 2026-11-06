import InlineKit
import UIKit

extension MessageView {
  private static let quoteHighlightTag = 0x51554F

  /// Briefly shades the line boxes of `quote` with `color`, behind the text so it stays clear.
  /// Returns false when the message doesn't show that text, for example while it is translated.
  func highlightQuote(_ quote: String, color: UIColor) -> Bool {
    clearQuoteHighlight()
    guard let (textView, rects) = quoteLineRects(quote), let container = textView.superview else { return false }

    for rect in rects {
      let mark = UIView(frame: textView.convert(rect.insetBy(dx: -2, dy: -1), to: container))
      mark.tag = Self.quoteHighlightTag
      mark.backgroundColor = color
      mark.layer.cornerRadius = 4
      mark.layer.cornerCurve = .continuous
      mark.isUserInteractionEnabled = false
      mark.alpha = 0
      container.insertSubview(mark, belowSubview: textView)
      UIView.animate(withDuration: MessageCollectionViewCell.focusHighlightFadeIn) {
        mark.alpha = 1
      } completion: { _ in
        UIView.animate(
          withDuration: 0.5,
          delay: MessageCollectionViewCell.focusHighlightHold,
          options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
          mark.alpha = 0
        } completion: { _ in
          mark.removeFromSuperview()
        }
      }
    }
    return true
  }

  /// Where `quote` sits in `target`'s coordinates, for deciding whether to scroll to it.
  func quoteRect(_ quote: String, in target: UIView) -> CGRect? {
    guard let (textView, rects) = quoteLineRects(quote), let first = rects.first else { return nil }
    return textView.convert(rects.dropFirst().reduce(first) { $0.union($1) }, to: target)
  }

  /// The line boxes of `quote` in its text view's coordinates.
  private func quoteLineRects(_ quote: String) -> (MessageTextView, [CGRect])? {
    guard let (textView, range) = quoteTextView(quote, in: bubbleContentView) else { return nil }
    let rects = textView.layout.rects(for: range).map { textView.viewRect(forTextRect: $0) }
    return rects.isEmpty ? nil : (textView, rects)
  }

  func clearQuoteHighlight() {
    while let mark = bubbleContentView.viewWithTag(Self.quoteHighlightTag) {
      mark.removeFromSuperview()
    }
  }

  private func quoteTextView(_ quote: String, in view: UIView) -> (MessageTextView, NSRange)? {
    for subview in view.subviews where !subview.isHidden && subview !== nameView {
      if let textView = subview as? MessageTextView,
         let range = ReplyQuote.range(of: quote, in: textView.layout.text.attributedString.string)
      {
        return (textView, range)
      }
      if let match = quoteTextView(quote, in: subview) { return match }
    }
    return nil
  }
}
