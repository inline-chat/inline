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
