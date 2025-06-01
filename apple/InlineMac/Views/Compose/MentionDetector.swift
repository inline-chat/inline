import Foundation
import Logger

struct MentionRange {
  let range: NSRange
  let query: String
  let atSymbolLocation: Int
}

class MentionDetector {
  private let log = Log.scoped("MentionDetector")

  /// Detects if there's an active mention at the cursor position
  /// Returns the mention range and query if found, nil otherwise
  func detectMentionAt(cursorPosition: Int, in text: String) -> MentionRange? {
    guard cursorPosition <= text.count else {
      log.trace("Cursor position \(cursorPosition) is beyond text length \(text.count)")
      return nil
    }

    let nsString = text as NSString
    log.trace("Detecting mention at cursor \(cursorPosition) in text: '\(text)'")

    // Find the last @ symbol before or at the cursor position
    var atSymbolLocation = -1
    var searchPosition = cursorPosition - 1

    while searchPosition >= 0 {
      let char = nsString.character(at: searchPosition)
      log.trace("Checking character at \(searchPosition): '\(Character(UnicodeScalar(char)!))'")

      if char == 64 { // '@' character
        atSymbolLocation = searchPosition
        log.trace("Found @ symbol at position \(atSymbolLocation)")
        break
      }

      // Stop if we hit whitespace or newline - this means we're not in a mention
      if char == 32 || char == 10 || char == 9 { // space, newline, tab
        log.trace("Hit whitespace at \(searchPosition), stopping search")
        break
      }

      searchPosition -= 1
    }

    guard atSymbolLocation >= 0 else {
      log.trace("No @ symbol found before cursor")
      return nil
    }

    // Check if there's a space or beginning of string right before the @
    if atSymbolLocation > 0 {
      let charBeforeAt = nsString.character(at: atSymbolLocation - 1)
      if charBeforeAt != 32, charBeforeAt != 10, charBeforeAt != 9 { // space, newline, tab
        // @ is part of another word, not a mention
        log.trace("@ symbol is part of another word (char before: '\(Character(UnicodeScalar(charBeforeAt)!))')")
        return nil
      }
    }

    // Extract the query after the @ symbol
    let startIndex = atSymbolLocation + 1
    var endIndex = cursorPosition

    // Find the end of the mention (next whitespace or end of string)
    while endIndex < nsString.length {
      let char = nsString.character(at: endIndex)
      if char == 32 || char == 10 || char == 9 { // space, newline, tab
        break
      }
      endIndex += 1
    }

    // Extract the query (text after @)
    let queryRange = NSRange(location: startIndex, length: max(0, endIndex - startIndex))
    let query = nsString.substring(with: queryRange)

    // The complete mention range (including @)
    let mentionRange = NSRange(location: atSymbolLocation, length: endIndex - atSymbolLocation)

    log.trace("Detected mention at \(atSymbolLocation): '@\(query)' (range: \(mentionRange))")

    return MentionRange(
      range: mentionRange,
      query: query,
      atSymbolLocation: atSymbolLocation
    )
  }

  /// Replace a mention range with the selected mention text
  func replaceMention(
    in text: String,
    range: NSRange,
    with mentionText: String
  ) -> (newText: String, newCursorPosition: Int) {
    let nsString = text as NSString
    let newText = nsString.replacingCharacters(in: range, with: mentionText + " ")
    let newCursorPosition = range.location + mentionText.count + 1 // +1 for the space

    log.trace("Replaced mention at \(range) with '\(mentionText)', new cursor: \(newCursorPosition)")

    return (newText, newCursorPosition)
  }

  /// Check if character being typed should trigger mention detection
  func shouldTriggerMentionDetection(for character: String) -> Bool {
    character == "@"
  }

  /// Check if typing should continue mention detection
  func shouldContinueMentionDetection(for character: String) -> Bool {
    // Continue if it's alphanumeric or underscore
    let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
    return character.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
  }

  /// Check if character should cancel mention detection
  func shouldCancelMentionDetection(for character: String) -> Bool {
    // Cancel on whitespace, newline, or special characters
    let cancelCharacters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: " \t\n@#"))
    return character.unicodeScalars.allSatisfy { cancelCharacters.contains($0) }
  }
}
