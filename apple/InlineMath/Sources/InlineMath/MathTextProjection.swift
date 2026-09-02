import Foundation

/// A display-only projection for successfully rendered inline formulas.
/// Apply it after slicing a canonical BlockText range. The canonical source
/// and all wire/entity offsets remain unchanged; each replacement is one
/// attachment character in the display string.
public struct MathTextProjection: Sendable {
  public struct Replacement: Sendable {
    public let sourceRange: NSRange
    public let displayRange: NSRange
  }

  public let source: String
  public let text: String
  public let replacements: [Replacement]

  /// Invalid, overlapping, or excessive ranges fail as a unit so callers can
  /// retain the original text. Only pass ranges with prepared image results.
  public init?(source: String, renderedRanges: [NSRange]) {
    guard renderedRanges.count <= 64, source.utf16.prefix(131_073).count <= 131_072 else { return nil }
    let original = source as NSString
    var replacements: [Replacement] = []
    var removed = 0, previousEnd = 0
    for range in renderedRanges.sorted(by: { $0.location < $1.location }) {
      guard range.length > 0, Self.valid(range, in: original), range.location >= previousEnd else { return nil }
      replacements.append(.init(sourceRange: range,
                                displayRange: NSRange(location: range.location - removed, length: 1)))
      removed += range.length - 1
      previousEnd = NSMaxRange(range)
    }
    let display = NSMutableString(string: source)
    for replacement in replacements.reversed() {
      display.replaceCharacters(in: replacement.sourceRange, with: "\u{fffc}")
    }
    self.source = source
    self.text = display as String
    self.replacements = replacements
  }

  /// Selecting an attachment copies its complete canonical TeX body. Invalid
  /// native selections fail rather than splitting a surrogate or clamping.
  public func sourceRange(forDisplayRange range: NSRange) -> NSRange? {
    guard Self.valid(range, in: text as NSString) else { return nil }
    let start = sourceOffset(forDisplayOffset: range.location)
    let end = sourceOffset(forDisplayOffset: NSMaxRange(range))
    return NSRange(location: start, length: end - start)
  }

  public func sourceText(forDisplayRange range: NSRange) -> String? {
    guard let sourceRange = sourceRange(forDisplayRange: range) else { return nil }
    return (source as NSString).substring(with: sourceRange)
  }

  /// A source selection touching part of a formula selects the whole display
  /// attachment. A caret within a formula stays a caret at its leading edge.
  public func displayRange(forSourceRange range: NSRange) -> NSRange? {
    guard Self.valid(range, in: source as NSString) else { return nil }
    let start = displayOffset(forSourceOffset: range.location, trailing: false)
    guard range.length > 0 else { return NSRange(location: start, length: 0) }
    let end = displayOffset(forSourceOffset: NSMaxRange(range), trailing: true)
    return NSRange(location: start, length: end - start)
  }

  private func sourceOffset(forDisplayOffset offset: Int) -> Int {
    var removed = 0
    for replacement in replacements {
      if offset <= replacement.displayRange.location { break }
      removed += replacement.sourceRange.length - 1
    }
    return offset + removed
  }

  private func displayOffset(forSourceOffset offset: Int, trailing: Bool) -> Int {
    var removed = 0
    for replacement in replacements {
      let range = replacement.sourceRange
      if offset <= range.location { break }
      if offset < NSMaxRange(range) {
        return replacement.displayRange.location + (trailing ? 1 : 0)
      }
      removed += range.length - 1
    }
    return offset - removed
  }

  private static func valid(_ range: NSRange, in source: NSString) -> Bool {
    guard range.location >= 0, range.length >= 0, range.location <= source.length,
          range.length <= source.length - range.location else { return false }
    return boundary(range.location, in: source) && boundary(NSMaxRange(range), in: source)
  }

  private static func boundary(_ offset: Int, in source: NSString) -> Bool {
    guard offset > 0, offset < source.length else { return true }
    return !(0xD800...0xDBFF).contains(source.character(at: offset - 1))
      || !(0xDC00...0xDFFF).contains(source.character(at: offset))
  }
}
