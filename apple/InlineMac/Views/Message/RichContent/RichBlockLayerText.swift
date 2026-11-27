import AppKit
import CoreText

/// Whether a rich block's text is drawn by Core Text in a layer (`CoreTextMessageView`) instead of a TextKit
/// `NSTextView`, decided the same way where the planner measures it and where the surface draws it, so both use one
/// layout.
///
/// Why: a TextKit text view per block was the costliest part of a rich row coming on screen (text storage edits,
/// layout, selection fix-ups and new views per block shape), and AppKit doesn't draw a view nested in a clipping view
/// while its row is outside the window, so rich rows placed ahead of a fling came on screen without text. A layer
/// marked for display draws wherever it is, in the commit that shows it.
///
/// Part of the "Core Text Message Text" experiment: with it off, rich text stays on TextKit, as plain text does.
enum RichBlockLayerText {
  /// Drawn in a layer: the experiment is on, the text wraps (single lines truncate, which the Core Text layout
  /// doesn't do), has no attachments (inline math images), and its paragraphs align to their writing direction's
  /// start (centred, justified or end-aligned paragraphs stay on TextKit).
  static func draws(_ text: NSAttributedString, singleLine: Bool) -> Bool {
    guard CoreTextMessageText.isEnabled, !singleLine, text.length > 0, CoreTextMessageText.supports(text) else {
      return false
    }
    #if DEBUG
    // A/B in one build (the timeline journey harness): `-debug.richLayerText NO` keeps rich text on TextKit.
    let defaults = UserDefaults.standard
    if defaults.object(forKey: "debug.richLayerText") != nil, !defaults.bool(forKey: "debug.richLayerText") { return false }
    #endif
    var aligned = true
    text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, stop in
      guard let style = value as? NSParagraphStyle else { return }
      let rightToLeft = style.baseWritingDirection == .rightToLeft
      switch style.alignment {
        case .left: aligned = !rightToLeft
        case .right: aligned = rightToLeft
        case .natural: aligned = true
        default: aligned = false
      }
      if !aligned { stop.pointee = true }
    }
    return aligned
  }

  /// The whole text's base direction, from its first paragraph (the planner styles a block's text with one).
  static func isRtl(_ text: NSAttributedString) -> Bool {
    guard text.length > 0 else { return false }
    let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    return style?.baseWritingDirection == .rightToLeft
  }
}
