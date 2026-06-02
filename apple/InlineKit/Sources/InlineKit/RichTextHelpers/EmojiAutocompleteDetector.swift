import Foundation

public struct EmojiAutocompleteRange: Equatable {
  public let range: NSRange
  public let query: String
  public let colonLocation: Int

  public init(range: NSRange, query: String, colonLocation: Int) {
    self.range = range
    self.query = query
    self.colonLocation = colonLocation
  }
}

public final class EmojiAutocompleteDetector {
  public init() {}

  public func detectEmojiAutocompleteAt(
    cursorPosition: Int,
    in attributedText: NSAttributedString
  ) -> EmojiAutocompleteRange? {
    let text = attributedText.string
    let length = text.utf16.count

    guard cursorPosition > 0, cursorPosition <= length else { return nil }

    let nsString = text as NSString
    var location = cursorPosition - 1

    while location >= 0 {
      let char = nsString.character(at: location)

      if char == Self.colon {
        return makeRange(
          colonLocation: location,
          cursorPosition: cursorPosition,
          length: length,
          text: nsString
        )
      }

      if isBoundary(char) || !isQueryChar(char) {
        return nil
      }

      location -= 1
    }

    return nil
  }

  public func replaceEmojiAutocomplete(
    in attributedText: NSAttributedString,
    range: NSRange,
    with emoji: String,
    trailingText: String = ""
  ) -> (attributedText: NSAttributedString, cursorPosition: Int) {
    let mutableText = NSMutableAttributedString(attributedString: attributedText)
    let replacement = emoji + trailingText

    mutableText.replaceCharacters(in: range, with: replacement)

    let newCursorPosition = range.location + replacement.utf16.count

    return (NSAttributedString(attributedString: mutableText), newCursorPosition)
  }

  private func makeRange(
    colonLocation: Int,
    cursorPosition: Int,
    length: Int,
    text: NSString
  ) -> EmojiAutocompleteRange? {
    let queryStart = colonLocation + 1

    guard queryStart < cursorPosition else { return nil }

    if colonLocation > 0 {
      let previousChar = text.character(at: colonLocation - 1)
      guard !isTextChar(previousChar) else { return nil }
    }

    var endLocation = cursorPosition

    while endLocation < length {
      let char = text.character(at: endLocation)

      guard isQueryChar(char) else { break }

      endLocation += 1
    }

    let queryRange = NSRange(location: queryStart, length: cursorPosition - queryStart)
    let query = text.substring(with: queryRange)

    guard !query.isEmpty else { return nil }

    return EmojiAutocompleteRange(
      range: NSRange(location: colonLocation, length: endLocation - colonLocation),
      query: query,
      colonLocation: colonLocation
    )
  }

  private func isBoundary(_ char: unichar) -> Bool {
    switch char {
    case 9, 10, 13, 32:
      return true
    default:
      return false
    }
  }

  private func isQueryChar(_ char: unichar) -> Bool {
    switch char {
    case 43, 45, 48 ... 57, 65 ... 90, 95, 97 ... 122:
      return true
    default:
      return false
    }
  }

  private func isTextChar(_ char: unichar) -> Bool {
    guard let scalar = UnicodeScalar(Int(char)) else { return false }
    return char == 95 || CharacterSet.alphanumerics.contains(scalar)
  }

  private static let colon: unichar = 58
}
