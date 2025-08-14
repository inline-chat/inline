import Foundation
import InlineKit
import InlineProtocol
import Logger

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

#if os(macOS)
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
#else
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
#endif

public class ProcessEntities {
  public struct Configuration {
    var font: PlatformFont

    /// Default color for the text
    var textColor: PlatformColor

    /// Color of URLs, link texts and mentions
    var linkColor: PlatformColor

    /// If enabled, mentions convert to in-app URLs
    var convertMentionsToLink: Bool

    public init(
      font: PlatformFont,
      textColor: PlatformColor,
      linkColor: PlatformColor,
      convertMentionsToLink: Bool = true
    ) {
      self.font = font
      self.textColor = textColor
      self.linkColor = linkColor
      self.convertMentionsToLink = convertMentionsToLink
    }
  }

  ///
  /// Converts text and an array of entities to attributed string
  ///
  public static func toAttributedString(
    text: String,
    entities: MessageEntities?,
    configuration: Configuration
  ) -> NSMutableAttributedString {
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [
        .font: configuration.font,
        .foregroundColor: configuration.textColor,
      ]
    )

    guard let entities else {
      return attributedString
    }

    for entity in entities.entities {
      let range = NSRange(location: Int(entity.offset), length: Int(entity.length))

      // Validate range is within bounds
      guard range.location >= 0, range.location + range.length <= text.utf16.count else {
        continue
      }

      switch entity.type {
        case .mention:
          if case let .mention(mention) = entity.entity {
            if configuration.convertMentionsToLink {
              var attributes: [NSAttributedString.Key: Any] = [
                .mentionUserId: mention.userID,
                .foregroundColor: configuration.linkColor,
                .link: "inline://user/\(mention.userID)", // Custom URL scheme for mentions
              ]

              #if os(macOS)
              attributes[.cursor] = NSCursor.pointingHand
              #endif

              attributedString.addAttributes(attributes, range: range)
            } else {
              attributedString.addAttributes([
                .mentionUserId: mention.userID,
                .foregroundColor: configuration.linkColor,
              ], range: range)
            }
          }

        case .bold:
          // Apply bold formatting
          let existingAttributes = attributedString.attributes(at: range.location, effectiveRange: nil)

          let boldFont = createBoldFont(from: existingAttributes[.font] as? PlatformFont ?? configuration.font)

          attributedString.addAttribute(.font, value: boldFont, range: range)

        default:
          break
      }
    }

    return attributedString
  }

  ///
  /// Extract entities from attributed string
  ///
  public static func fromAttributedString(
    _ attributedString: NSAttributedString
  ) -> (text: String, entities: MessageEntities) {
    var text = attributedString.string
    var entities: [MessageEntity] = []

    // Extract mention entities first (before text modification)
    attributedString.enumerateAttribute(
      .mentionUserId,
      in: NSRange(location: 0, length: text.count),
      options: []
    ) { value, range, _ in
      if let userId = value as? Int64 {
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

    // Extract bold entities from **text** markdown syntax and update all entity offsets
    entities = extractBoldFromMarkdown(text: &text, existingEntities: entities)

    // Sort entities by offset
    entities.sort { $0.offset < $1.offset }

    var messageEntities = MessageEntities()
    messageEntities.entities = entities

    return (text: text, entities: messageEntities)
  }

  // MARK: - Helper Methods

  /// Sorts message entities by their offset position
  public static func sortEntities(_ entities: [MessageEntity]) -> [MessageEntity] {
    entities.sorted { $0.offset < $1.offset }
  }

  /// Sorts message entities in place by their offset position
  public static func sortEntities(_ entities: inout [MessageEntity]) {
    entities.sort { $0.offset < $1.offset }
  }

  private static func createBoldFont(from font: PlatformFont) -> PlatformFont {
    #if os(macOS)
    return NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    #elseif os(iOS)
    return UIFont.boldSystemFont(ofSize: font.pointSize)
    #endif
  }

  /// Extract bold entities from **text** markdown syntax
  private static func extractBoldFromMarkdown(
    text: inout String,
    existingEntities: [MessageEntity]
  ) -> [MessageEntity] {
    var allEntities = existingEntities
    var boldEntities: [MessageEntity] = []
    let pattern = "\\*\\*(.*?)\\*\\*"

    do {
      let regex = try NSRegularExpression(pattern: pattern, options: [])
      let nsText = text as NSString
      let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

      // Process matches in reverse order to avoid offset issues when removing ** markers
      var offsetAdjustments: [Int: Int] = [:] // position -> characters removed

      for match in matches.reversed() {
        // Get the full match range (including **)
        let fullRange = match.range(at: 0)

        // Get the content range (excluding **)
        if match.numberOfRanges > 1 {
          let contentRange = match.range(at: 1)

          if fullRange.location != NSNotFound, contentRange.location != NSNotFound {
            // Remove the ** markers from the text first
            let startIndex = text.index(text.startIndex, offsetBy: fullRange.location)

            let endIndex = text.index(text.startIndex, offsetBy: fullRange.location + fullRange.length)

            let contentText = String(text[text.index(text.startIndex, offsetBy: contentRange.location) ..< text.index(
              text.startIndex,
              offsetBy: contentRange.location + contentRange.length
            )])

            text.replaceSubrange(startIndex ..< endIndex, with: contentText)

            // Track that 4 characters were removed at this position (2 ** at start + 2 ** at end)
            offsetAdjustments[fullRange.location] = 4

            // Now create bold entity with the correct position (after ** removal)
            var boldEntity = MessageEntity()
            boldEntity.type = .bold
            boldEntity.offset = Int64(fullRange.location) // Position where content now starts (after ** removed)
            boldEntity.length = Int64(contentRange.length)
            boldEntities.append(boldEntity)
          }
        }
      }

      // Update offsets of all existing entities that come after removed ** markers
      for i in 0 ..< allEntities.count {
        let entityOffset = Int(allEntities[i].offset)
        var adjustment = 0

        // Calculate total adjustment for this entity's position
        for (removalPosition, charsRemoved) in offsetAdjustments {
          if entityOffset > removalPosition {
            adjustment += charsRemoved
          }
        }

        allEntities[i].offset = Int64(entityOffset - adjustment)
      }

      // Add bold entities to the list
      allEntities.append(contentsOf: boldEntities)

    } catch {
      // Handle regex error silently
    }

    return allEntities
  }
}

// MARK: - Integrate with drafts for easier usage

public extension Drafts {
  func update(peerId: InlineKit.Peer, attributedString: NSAttributedString) {
    // Extract entities from attributed string
    let (text, entities) = ProcessEntities.fromAttributedString(attributedString)

    // Update
    update(peerId: peerId, text: text, entities: entities)
  }
}
