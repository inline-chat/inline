import Foundation

public enum ComposeAutoPairEditing {
  public struct Replacement: Equatable {
    public let range: NSRange
    public let text: String
    public let selectedRange: NSRange
  }

  private static let pairs: [String: String] = [
    "(": ")",
    "[": "]",
  ]

  public static func insertionReplacement(
    in text: String,
    selectedRange: NSRange,
    replacementRange: NSRange? = nil,
    insertedText: String
  ) -> Replacement? {
    guard let range = effectiveRange(selectedRange: selectedRange, replacementRange: replacementRange, text: text),
          range.length == 0
    else {
      return nil
    }

    if let closer = pairs[insertedText] {
      return Replacement(
        range: range,
        text: insertedText + closer,
        selectedRange: NSRange(location: range.location + (insertedText as NSString).length, length: 0)
      )
    }

    guard pairs.values.contains(insertedText),
          nextCharacter(in: text, at: range.location) == insertedText
    else {
      return nil
    }

    return Replacement(
      range: range,
      text: "",
      selectedRange: NSRange(location: range.location + (insertedText as NSString).length, length: 0)
    )
  }

  public static func deletionReplacement(
    in text: String,
    selectedRange: NSRange
  ) -> Replacement? {
    let nsText = text as NSString
    guard isValid(selectedRange, length: nsText.length),
          selectedRange.length == 0,
          selectedRange.location > 0,
          selectedRange.location < nsText.length
    else {
      return nil
    }

    let opener = nsText.substring(with: NSRange(location: selectedRange.location - 1, length: 1))
    guard let closer = pairs[opener] else { return nil }

    let next = nsText.substring(with: NSRange(location: selectedRange.location, length: 1))
    guard next == closer else { return nil }

    return Replacement(
      range: NSRange(location: selectedRange.location - 1, length: 2),
      text: "",
      selectedRange: NSRange(location: selectedRange.location - 1, length: 0)
    )
  }

  public static func apply(
    _ replacement: Replacement,
    to text: String
  ) -> (text: String, selectedRange: NSRange) {
    let nsText = text as NSString
    guard isValid(replacement.range, length: nsText.length) else {
      return (text, replacement.selectedRange)
    }

    return (
      nsText.replacingCharacters(in: replacement.range, with: replacement.text),
      replacement.selectedRange
    )
  }

  private static func effectiveRange(
    selectedRange: NSRange,
    replacementRange: NSRange?,
    text: String
  ) -> NSRange? {
    let nsText = text as NSString

    if let replacementRange,
       replacementRange.location != NSNotFound
    {
      guard isValid(replacementRange, length: nsText.length) else { return nil }
      return replacementRange
    }

    guard isValid(selectedRange, length: nsText.length) else { return nil }
    return selectedRange
  }

  private static func nextCharacter(in text: String, at location: Int) -> String? {
    let nsText = text as NSString
    guard location >= 0, location < nsText.length else { return nil }
    return nsText.substring(with: NSRange(location: location, length: 1))
  }

  private static func isValid(_ range: NSRange, length: Int) -> Bool {
    guard range.location != NSNotFound,
          range.location >= 0,
          range.location <= length,
          range.length >= 0
    else {
      return false
    }

    return NSMaxRange(range) <= length
  }
}
