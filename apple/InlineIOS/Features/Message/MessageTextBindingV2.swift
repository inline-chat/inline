import UIKit

/// Compare canonical input, since UIKit adds fallback-font attributes to its
/// storage. Each binding belongs to one text view and clears with its content.
@MainActor
struct MessageTextBindingV2 {
  private var source: NSAttributedString?

  @discardableResult
  mutating func apply(_ text: NSAttributedString?, to view: UITextView) -> Bool {
    if let source, let text,
       source.string.utf8.elementsEqual(text.string.utf8), source.isEqual(to: text) { return false }
    if source == nil, text == nil { return false }
    source = text?.copy() as? NSAttributedString
    view.attributedText = text
    return true
  }
}

extension UITextView {
  func useManualMessageLayout() {
    // Keep an unbounded text container so the measured plan owns height.
    // isScrollEnabled=false would restore UIKit's intrinsic-height work.
    // The surrounding message list or table viewport owns panning.
    isScrollEnabled = true
    panGestureRecognizer.isEnabled = false
    scrollsToTop = false
    bounces = false
    showsVerticalScrollIndicator = false
    showsHorizontalScrollIndicator = false
    textContainer.heightTracksTextView = false
    textContainer.size.height = .greatestFiniteMagnitude
  }
}
