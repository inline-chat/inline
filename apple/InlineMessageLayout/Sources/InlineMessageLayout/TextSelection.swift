import CoreGraphics
import CoreText
import Foundation

/// Which line a caret belongs to where a soft wrap puts one index at the end of a line and the
/// start of the next: a selection's start sits on the later line, its end on the earlier one.
public enum TextCaretAffinity: Hashable, Sendable {
  case upstream
  case downstream
}

/// Selection geometry for a typeset text, in the layout's coordinates. Indices are UTF-16 offsets
/// into `text`; a caret index lies in `0 ... length`.
extension TextLayout {
  /// Caret nearest `point`: the line under it (the first or last line above or below the text),
  /// then the closest glyph boundary on that line. Never lands after a line's hard break.
  public func closestCaretIndex(to point: CGPoint) -> Int {
    guard let line = line(nearestY: point.y) else { return 0 }
    let index = CTLineGetStringIndexForPosition(line.ctLine, CGPoint(x: point.x - line.frame.minX, y: 0))
    let caret = index == kCFNotFound ? line.range.location : index
    return min(max(caret, line.range.location), caretLimit(of: line))
  }

  /// A zero-width line-height rect at `index`, for drawing a caret or a selection handle.
  public func caretRect(at index: Int, affinity: TextCaretAffinity = .downstream) -> CGRect? {
    guard let line = line(containingCaret: index, affinity: affinity) else { return nil }
    let offset = CTLineGetOffsetForStringIndex(line.ctLine, index, nil)
    return CGRect(x: line.frame.minX + offset, y: line.frame.minY, width: 0, height: line.frame.height)
  }

  /// The word holding the character at `index`, or that character's cluster when it isn't in a
  /// word (a space, punctuation or an emoji).
  public func wordRange(at index: Int) -> NSRange {
    let string = text.attributedString.string as NSString
    guard string.length > 0 else { return NSRange(location: 0, length: 0) }
    let location = min(max(index, 0), string.length - 1)
    let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
    var word: NSRange?
    string.enumerateSubstrings(in: paragraph, options: [.byWords, .substringNotRequired]) { _, range, _, stop in
      if NSLocationInRange(location, range) {
        word = range
        stop.pointee = true
      } else if range.location > location {
        stop.pointee = true
      }
    }
    return word ?? string.rangeOfComposedCharacterSequence(at: location)
  }

  /// The range between two carets, widened to whole grapheme clusters so a selection never
  /// splits an emoji or a combined mark.
  public func selectionRange(from anchor: Int, to focus: Int) -> NSRange {
    let string = text.attributedString.string as NSString
    let lower = min(max(min(anchor, focus), 0), string.length)
    let upper = min(max(max(anchor, focus), 0), string.length)
    guard upper > lower else { return NSRange(location: lower, length: 0) }
    return string.rangeOfComposedCharacterSequences(for: NSRange(location: lower, length: upper - lower))
  }

  /// The word a press at `point` selects: the one under the finger, by glyph rather than by the
  /// nearest caret, so pressing a word's last letter doesn't pick the space after it. Past a
  /// line's end it takes the line's last word.
  public func wordRange(at point: CGPoint) -> NSRange {
    if let index = characterIndex(at: point) { return wordRange(at: index) }
    guard let line = line(nearestY: point.y) else { return NSRange(location: 0, length: 0) }
    let caret = closestCaretIndex(to: point)
    let index = caret >= caretLimit(of: line) ? max(line.range.location, caret - 1) : caret
    return wordRange(at: index)
  }

  /// The selected text, without the attributes.
  public func string(in range: NSRange) -> String {
    let string = text.attributedString.string as NSString
    let clamped = NSIntersectionRange(range, NSRange(location: 0, length: string.length))
    return string.substring(with: clamped)
  }

  // MARK: - Lines

  private func line(nearestY y: CGFloat) -> Line? {
    guard let first = lines.first else { return nil }
    if y < first.frame.minY { return first }
    // A gap between paragraphs belongs to the line below it.
    return lines.first { y < $0.frame.maxY } ?? lines.last
  }

  private func line(containingCaret index: Int, affinity: TextCaretAffinity) -> Line? {
    guard !lines.isEmpty else { return nil }
    if affinity == .upstream {
      if let line = lines.first(where: { $0.range.location < index && index <= caretLimit(of: $0) }) {
        return line
      }
    }
    if let line = lines.first(where: { NSLocationInRange(index, $0.range) }) {
      return line
    }
    return index <= 0 ? lines.first : lines.last
  }

  /// The last caret on `line`: before its hard break, if it ends with one.
  private func caretLimit(of line: Line) -> Int {
    let end = NSMaxRange(line.range)
    guard end > line.range.location else { return end }
    let string = text.attributedString.string as NSString
    let last = string.character(at: end - 1)
    guard last == 0x0A || last == 0x0D || last == 0x2028 || last == 0x2029 else { return end }
    // CR LF is one cluster; the caret goes before both.
    if last == 0x0A, end - 2 >= line.range.location, string.character(at: end - 2) == 0x0D {
      return end - 2
    }
    return end - 1
  }
}
