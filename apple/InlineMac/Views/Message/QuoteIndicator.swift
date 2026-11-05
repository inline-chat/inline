import AppKit
import InlineKit
import Logger

extension NSView {
  private static let quoteHighlightIdentifier = NSUserInterfaceItemIdentifier("QuoteHighlight")
  private static let quoteLog = Log.scoped("QuoteHighlight")

  /// Briefly shades the line boxes of `quote` with `color`, behind the text so it stays
  /// readable. The boxes come from the layout already on screen; nothing is laid out again.
  /// Returns false when the message doesn't show that text, for example while it is translated.
  func highlightQuote(_ quote: String, color: CGColor) -> Bool {
    guard let (textView, range) = quoteTextView(quote), let container = textView.superview else {
      Self.quoteLog.info("quote not found in message text")
      return false
    }
    let rects = textView.quoteLineRects(range).map { textView.convert($0, to: container) }
    Self.quoteLog.info("quote range \(range) in \(type(of: textView)) rects \(rects)")
    guard !rects.isEmpty else { return false }

    clearQuoteHighlight(in: container)
    for rect in rects {
      let mark = NSView(frame: rect.insetBy(dx: -2, dy: 0))
      mark.identifier = Self.quoteHighlightIdentifier
      mark.wantsLayer = true
      mark.layer?.backgroundColor = color
      mark.layer?.cornerRadius = 4
      mark.layer?.cornerCurve = .continuous
      mark.alphaValue = 0
      container.addSubview(mark, positioned: .below, relativeTo: textView)
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.18
        mark.animator().alphaValue = 1
      } completionHandler: {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
          NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            mark.animator().alphaValue = 0
          } completionHandler: {
            mark.removeFromSuperview()
          }
        }
      }
    }
    return true
  }

  /// Where `quote` sits in `target`'s coordinates, for scrolling it into view.
  func quoteRect(_ quote: String, in target: NSView) -> CGRect? {
    guard let (textView, range) = quoteTextView(quote) else { return nil }
    let rects = textView.quoteLineRects(range)
    guard let first = rects.first else { return nil }
    return textView.convert(rects.dropFirst().reduce(first) { $0.union($1) }, to: target)
  }

  private func clearQuoteHighlight(in container: NSView) {
    for subview in container.subviews where subview.identifier == Self.quoteHighlightIdentifier {
      subview.removeFromSuperview()
    }
  }

  private func quoteTextView(_ quote: String) -> (NSTextView, NSRange)? {
    for subview in subviews where !subview.isHiddenOrHasHiddenAncestor {
      if let textView = subview as? NSTextView,
         let range = ReplyQuote.range(of: quote, in: textView.string)
      {
        return (textView, range)
      }
      if let match = subview.quoteTextView(quote) { return match }
    }
    return nil
  }
}

private extension NSTextView {
  /// One box per line of `range`, in this view's coordinates, from the input client's
  /// `firstRect`, which reads the current layout for TextKit 1 and 2 alike.
  func quoteLineRects(_ range: NSRange) -> [CGRect] {
    guard let window, NSMaxRange(range) <= (string as NSString).length else { return [] }
    var rects: [CGRect] = []
    var remaining = range
    while remaining.length > 0, rects.count < 100 {
      var actual = NSRange(location: NSNotFound, length: 0)
      let screenRect = firstRect(forCharacterRange: remaining, actualRange: &actual)
      guard actual.location != NSNotFound, actual.length > 0 else { break }
      let rect = convert(window.convertFromScreen(screenRect), from: nil)
      if rect.width > 0, rect.height > 0 { rects.append(rect) }
      let consumed = NSMaxRange(actual) - remaining.location
      guard consumed > 0 else { break }
      remaining = NSRange(location: remaining.location + consumed, length: remaining.length - consumed)
    }
    return rects
  }
}
