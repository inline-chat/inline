#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

import Foundation
import InlineProtocol
import Logger

public struct MentionRange {
  public let range: NSRange
  public let query: String
  public let atSymbolLocation: Int
}

public class MentionDetector {
  private let log = Log.scoped("MentionDetector")

  public init() {}

  /// Detects if there's an active mention at the cursor position
  /// Returns the mention range and query if found, nil otherwise
  public func detectMentionAt(cursorPosition: Int, in attributedText: NSAttributedString) -> MentionRange? {
    let text = attributedText.string
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

      #if DEBUG
      if let scalar = UnicodeScalar(char) {
        log.trace("Checking character at \(searchPosition): '\(Character(scalar))'")
      } else {
        log.trace("Checking character at \(searchPosition): [invalid unicode: \(char)]")
      }
      #endif // DEBUG

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
        if let scalar = UnicodeScalar(charBeforeAt) {
          log.trace("@ symbol is part of another word (char before: '\(Character(scalar))')")
        } else {
          log.trace("@ symbol is part of another word (char before: [invalid unicode: \(charBeforeAt)])")
        }
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

  /// Replace a mention range with the selected mention text and user ID
  public func replaceMention(
    in attributedText: NSAttributedString,
    range: NSRange,
    with mentionText: String,
    userId: Int64
  ) -> (newAttributedText: NSAttributedString, newCursorPosition: Int) {
    let mentionString = mentionText + " "
    let newAttributedText = AttributedStringHelpers.replaceMentionInAttributedString(
      attributedText,
      range: range,
      with: mentionString,
      userId: userId
    )

    let newCursorPosition = range.location + mentionString.count

    log.trace("Replaced mention at \(range) with '\(mentionText)' for user \(userId), new cursor: \(newCursorPosition)")

    return (newAttributedText, newCursorPosition)
  }

  /// Extract mention entities from attributed text for sending
  public func extractMentionEntities(from attributedText: NSAttributedString) -> [MessageEntity] {
    let entities = AttributedStringHelpers.extractMentionEntities(from: attributedText)
    log.debug("Extracted \(entities.count) mention entities")
    return entities
  }

  /// Check if character being typed should trigger mention detection
  public func shouldTriggerMentionDetection(for character: String) -> Bool {
    character == "@"
  }

  /// Check if typing should continue mention detection
  public func shouldContinueMentionDetection(for character: String) -> Bool {
    // Continue if it's alphanumeric or underscore
    let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
    return character.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
  }

  /// Check if character should cancel mention detection
  public func shouldCancelMentionDetection(for character: String) -> Bool {
    // Cancel on whitespace, newline, or special characters
    let cancelCharacters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: " \t\n@#"))
    return character.unicodeScalars.allSatisfy { cancelCharacters.contains($0) }
  }
}
