import AppKit

/// A view that draws one message's text and answers what the message list's selection and the
/// message view's clicks ask of it. `MessageTextView` (NSTextView) and `CoreTextMessageView`
/// (Inline's Core Text renderer) both provide it.
@MainActor
protocol MessageTextSurface: NSView {
  /// The displayed text. Selection offsets and copy ranges index into it.
  var surfaceText: NSAttributedString { get }
  /// The message list's selection in this view, drawn beneath the text.
  var listSelectionRange: NSRange? { get set }

  var onEntityClick: ((NSPoint, NSEvent) -> Bool)? { get set }
  var onTextLongPress: ((NSPoint, NSEvent) -> Void)? { get set }
  var onPlainSingleClick: ((NSPoint, NSEvent) -> Void)? { get set }

  func entityHit(at point: NSPoint, extraTextRanges: [NSRange]) -> MessageTextEntityHit?
  /// Insertion offset for a selection endpoint at `point`; the end of the text is valid.
  func selectionInsertionIndex(at point: NSPoint) -> Int?
  func codeBlockRange(at point: NSPoint) -> NSRange?
  func inlineCodeRange(at point: NSPoint) -> NSRange?
  /// Whether `point` is on drawn text rather than empty space in the view.
  func renderedTextContains(_ point: NSPoint) -> Bool
  /// The list started a selection drag from this press, so it is no longer a hold.
  func cancelPendingTextHold()
  /// The first line of `range` in screen coordinates, for placing the selection menu.
  func firstLineScreenRect(for range: NSRange) -> NSRect
}

extension MessageTextView: MessageTextSurface {
  var surfaceText: NSAttributedString { textStorage ?? NSAttributedString() }

  func firstLineScreenRect(for range: NSRange) -> NSRect {
    firstRect(forCharacterRange: range, actualRange: nil)
  }
}
