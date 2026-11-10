import Foundation

/// Immutable attributed text handed to the layout.
///
/// Attributes must already be Core Text compatible: `.font` holds a `CTFont` (a `UIFont` bridges),
/// and run delegates mark attachment slots. Colors do not affect layout.
public struct MessageText: Hashable, @unchecked Sendable {
  // NSAttributedString is immutable and safe to read from any thread; a mutable subclass is
  // copied on init so later mutation by the caller cannot change a cached layout.
  public let attributedString: NSAttributedString

  public init(_ attributedString: NSAttributedString) {
    self.attributedString = attributedString.copy() as! NSAttributedString
  }

  public var string: String { attributedString.string }
  public var length: Int { attributedString.length }
  public var isEmpty: Bool { attributedString.length == 0 }

  public static func == (lhs: MessageText, rhs: MessageText) -> Bool {
    lhs.attributedString === rhs.attributedString || lhs.attributedString.isEqual(to: rhs.attributedString)
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(attributedString.length)
    hasher.combine(attributedString.string)
  }
}

public enum TextDirection: Hashable, Sendable {
  case leftToRight
  case rightToLeft

  /// Direction of the first strong letter, as Unicode's paragraph rule picks it.
  ///
  /// Covers the right-to-left scripts Inline sees (Hebrew, Arabic and its extensions, Syriac,
  /// Thaana, NKo, Samaritan, Mandaic). Text with no letters uses `fallback`.
  public static func firstStrong(in string: NSString, range: NSRange, fallback: TextDirection) -> TextDirection {
    guard range.length > 0 else { return fallback }
    let substring = string.substring(with: range)
    for scalar in substring.unicodeScalars {
      if isRightToLeftLetter(scalar) { return .rightToLeft }
      if scalar.properties.isAlphabetic { return .leftToRight }
    }
    return fallback
  }

  /// Base direction of prose: the direction with more words, a tie going to the first strong
  /// letter.
  ///
  /// Persian and Hebrew prose routinely opens with Latin product names, identifiers and paths,
  /// which the first-strong rule alone reads as left to right. A word is a run of letters with
  /// the marks and joiners Arabic-script words carry inside them; it counts for the direction of
  /// its first letter. Same contract as InlineKit's `BlockContentDirection` and the server's
  /// `blockDirection.ts`. Text with no letters uses `fallback`.
  public static func dominant(in string: NSString, range: NSRange, fallback: TextDirection) -> TextDirection {
    guard range.length > 0 else { return fallback }
    var rightToLeftWords = 0
    var leftToRightWords = 0
    var firstStrong: TextDirection?
    var inWord = false
    for scalar in string.substring(with: range).unicodeScalars {
      switch scalar.properties.generalCategory {
      case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .letterNumber:
        guard !inWord else { continue }
        inWord = true
        let direction: TextDirection = isRightToLeftLetter(scalar) ? .rightToLeft : .leftToRight
        if direction == .rightToLeft { rightToLeftWords += 1 } else { leftToRightWords += 1 }
        if firstStrong == nil { firstStrong = direction }
      case .nonspacingMark, .spacingMark, .enclosingMark:
        continue
      case .format where scalar.value == 0x200C || scalar.value == 0x200D:
        continue
      default:
        inWord = false
      }
    }
    if rightToLeftWords != leftToRightWords {
      return rightToLeftWords > leftToRightWords ? .rightToLeft : .leftToRight
    }
    return firstStrong ?? fallback
  }

  static func isRightToLeftLetter(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x0590 ... 0x08FF, // Hebrew, Arabic, Syriac, Thaana, NKo, Samaritan, Mandaic, Arabic Extended
         0xFB1D ... 0xFDFF, // Hebrew and Arabic presentation forms A
         0xFE70 ... 0xFEFF, // Arabic presentation forms B
         0x10800 ... 0x10FFF, // historic right-to-left scripts
         0x1E800 ... 0x1EFFF: // Mende Kikakui, Adlam, Arabic mathematical symbols
      // Combining marks and digits inside these blocks are not strong letters.
      scalar.properties.isAlphabetic
    default:
      false
    }
  }
}
