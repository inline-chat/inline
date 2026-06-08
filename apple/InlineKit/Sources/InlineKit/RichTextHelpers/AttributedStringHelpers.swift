#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

import InlineProtocol

/// Helper class for rich text attributed string operations (mentions, bold, etc.)
public class AttributedStringHelpers {
  // MARK: - Mention Attributes

  #if os(macOS)
  public static func mentionAttributes(
    userId: Int64,
    font: NSFont = .systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
  ) -> [NSAttributedString.Key: Any] {
    [
      .mentionUserId: userId,
      .foregroundColor: NSColor.systemBlue,
      .font: font,
    ]
  }

  public static func threadLinkAttributes(
    target: ThreadLinkTarget,
    font: NSFont = .systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
  ) -> [NSAttributedString.Key: Any] {
    [
      .threadLink: target,
      .foregroundColor: NSColor.systemBlue,
      .font: font,
    ]
  }

  #elseif os(iOS)
  public static func mentionAttributes(
    userId: Int64,
    font: UIFont = UIFont.systemFont(ofSize: 17, weight: .regular)
  ) -> [NSAttributedString.Key: Any] {
    [
      .mentionUserId: userId,
      .foregroundColor: UIColor.systemBlue,
      .font: font,
    ]
  }

  public static func threadLinkAttributes(
    target: ThreadLinkTarget,
    font: UIFont = UIFont.systemFont(ofSize: 17, weight: .regular)
  ) -> [NSAttributedString.Key: Any] {
    [
      .threadLink: target,
      .foregroundColor: UIColor.systemBlue,
      .font: font,
    ]
  }
  #endif

  // MARK: - Mention Creation

  public static func createMentionAttributedString(_ text: String, userId: Int64) -> NSAttributedString {
    NSAttributedString(string: text, attributes: mentionAttributes(userId: userId))
  }

  public static func createThreadLinkAttributedString(_ text: String, target: ThreadLinkTarget) -> NSAttributedString {
    let attributedString = NSMutableAttributedString(string: text, attributes: threadLinkAttributes(target: target))
    styleThreadLinkSyntax(in: attributedString, range: NSRange(location: 0, length: attributedString.length))
    return attributedString
  }

  #if os(macOS)
  public static func styleThreadLinkSyntax(
    in attributedString: NSMutableAttributedString,
    range: NSRange,
    linkColor: NSColor = .systemBlue,
    bracketColor: NSColor = .secondaryLabelColor
  ) {
    styleThreadLinkSyntax(
      in: attributedString,
      range: range,
      linkColorValue: linkColor,
      bracketColorValue: bracketColor
    )
  }
  #elseif os(iOS)
  public static func styleThreadLinkSyntax(
    in attributedString: NSMutableAttributedString,
    range: NSRange,
    linkColor: UIColor = .systemBlue,
    bracketColor: UIColor = .secondaryLabel
  ) {
    styleThreadLinkSyntax(
      in: attributedString,
      range: range,
      linkColorValue: linkColor,
      bracketColorValue: bracketColor
    )
  }
  #endif

  private static func styleThreadLinkSyntax(
    in attributedString: NSMutableAttributedString,
    range: NSRange,
    linkColorValue: Any,
    bracketColorValue: Any
  ) {
    let fullRange = NSRange(location: 0, length: attributedString.length)
    let safeRange = NSIntersectionRange(range, fullRange)
    guard safeRange.location != NSNotFound, safeRange.length > 0 else { return }

    attributedString.addAttribute(.foregroundColor, value: linkColorValue, range: safeRange)

    let text = attributedString.string as NSString
    guard safeRange.length >= 4,
          text.substring(with: NSRange(location: safeRange.location, length: 2)) == "[[",
          text.substring(with: NSRange(location: NSMaxRange(safeRange) - 2, length: 2)) == "]]"
    else {
      return
    }

    attributedString.addAttribute(
      .foregroundColor,
      value: bracketColorValue,
      range: NSRange(location: safeRange.location, length: 2)
    )
    attributedString.addAttribute(
      .foregroundColor,
      value: bracketColorValue,
      range: NSRange(location: NSMaxRange(safeRange) - 2, length: 2)
    )
  }

  // MARK: - Mention Manipulation

  public static func replaceMentionInAttributedString(
    _ attributedString: NSAttributedString,
    range: NSRange,
    with mentionText: String,
    userId: Int64
  ) -> NSAttributedString {
    let mutableAttributedString = attributedString.mutableCopy() as! NSMutableAttributedString
    let mentionAttributedString = createMentionAttributedString(mentionText, userId: userId)
    mutableAttributedString.replaceCharacters(in: range, with: mentionAttributedString)
    return mutableAttributedString.copy() as! NSAttributedString
  }

  public static func replaceThreadLinkInAttributedString(
    _ attributedString: NSAttributedString,
    range: NSRange,
    with text: String,
    target: ThreadLinkTarget
  ) -> NSAttributedString {
    let mutableAttributedString = attributedString.mutableCopy() as! NSMutableAttributedString
    let threadLinkAttributedString = createThreadLinkAttributedString(text, target: target)
    mutableAttributedString.replaceCharacters(in: range, with: threadLinkAttributedString)
    return mutableAttributedString.copy() as! NSAttributedString
  }

  public static func extractMentionEntities(from attributedString: NSAttributedString) -> [MessageEntity] {
    var entities: [MessageEntity] = []
    let text = attributedString.string as NSString
    attributedString.enumerateAttribute(
      .mentionUserId,
      in: NSRange(location: 0, length: attributedString.length),
      options: []
    ) { value, range, _ in
      if let userId = value as? Int64 {
        guard let range = trimmedEntityRange(in: text, range: range) else { return }
        var entity = MessageEntity()
        entity.type = .mention
        entity.offset = Int64(range.location)
        entity.length = Int64(range.length)
        entity.mention = MessageEntity.MessageEntityMention.with {
          $0.userID = userId
        }
        entities.append(entity)
      }
    }

    return entities
  }

  private static func trimmedEntityRange(in text: NSString, range: NSRange) -> NSRange? {
    guard range.location != NSNotFound,
          range.location >= 0,
          range.length > 0,
          NSMaxRange(range) <= text.length
    else {
      return nil
    }

    var start = range.location
    var end = NSMaxRange(range)

    while start < end, isEntityWhitespace(text.character(at: start)) {
      start += 1
    }
    while end > start, isEntityWhitespace(text.character(at: end - 1)) {
      end -= 1
    }

    guard end > start else { return nil }
    return NSRange(location: start, length: end - start)
  }

  private static func isEntityWhitespace(_ character: unichar) -> Bool {
    guard let scalar = UnicodeScalar(character) else { return false }
    return CharacterSet.whitespacesAndNewlines.contains(scalar)
  }

  // MARK: - Bold Text Processing

  /// Process **bold** text patterns in attributed string
  public static func processBoldText(in attributedString: NSAttributedString) -> NSAttributedString {
    let boldDetector = BoldTextDetector()
    return boldDetector.processBoldText(in: attributedString)
  }

  // MARK: - Combined Entity Processing

  // Note: For extracting/applying all entities (mentions, bold, etc.), use:
  // - ProcessEntities.fromAttributedString() to extract entities
  // - ProcessEntities.toAttributedString() to apply entities to text
  // These methods are in the TextProcessing module and provide centralized entity handling.

  /// Process all rich text patterns (bold, etc.) in attributed string
  public static func processRichText(in attributedString: NSAttributedString) -> NSAttributedString {
    // Process bold text patterns first
    processBoldText(in: attributedString)
  }
}

// MARK: - NSAttributedString.Key Extension

public extension NSAttributedString.Key {
  static let mentionUserId = NSAttributedString.Key("mentionUserId")
  static let threadLink = NSAttributedString.Key("threadLink")
  static let botCommand = NSAttributedString.Key("botCommand")
  static let emailAddress = NSAttributedString.Key("emailAddress")
  static let phoneNumber = NSAttributedString.Key("phoneNumber")
  static let inlineCode = NSAttributedString.Key("inlineCode")
  static let preCode = NSAttributedString.Key("preCode")
  static let italic = NSAttributedString.Key("italic")
  static let codeBlock = NSAttributedString.Key("codeBlock")
  static let codeBlockBackground = NSAttributedString.Key("codeBlockBackground")
  static let inlineCodeBackground = NSAttributedString.Key("inlineCodeBackground")
}
