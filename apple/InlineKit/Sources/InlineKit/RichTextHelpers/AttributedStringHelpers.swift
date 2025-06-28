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
  #endif

  // MARK: - Mention Creation

  public static func createMentionAttributedString(_ text: String, userId: Int64) -> NSAttributedString {
    NSAttributedString(string: text, attributes: mentionAttributes(userId: userId))
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

  public static func extractMentionEntities(from attributedString: NSAttributedString) -> [MessageEntity] {
    var entities: [MessageEntity] = []
    let text = attributedString.string

    attributedString.enumerateAttribute(
      .mentionUserId,
      in: NSRange(location: 0, length: text.count),
      options: []
    ) { value, range, _ in
      if let userId = value as? Int64 {
        var entity = MessageEntity()
        entity.type = .mention
        entity.offset = Int64(range.location)
        entity.length = Int64(range.length - 1) // Subtract 1 for trailing space
        entity.mention = MessageEntity.MessageEntityMention.with {
          $0.userID = userId
        }
        entities.append(entity)
      }
    }

    return entities
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
}
