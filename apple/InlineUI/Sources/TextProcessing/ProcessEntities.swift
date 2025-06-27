import Foundation
import InlineKit
import InlineProtocol

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
    var entities: [MessageEntity] = []
    let text = attributedString.string

    // Extract mention entities
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

    // Extract bold entities
    attributedString
      .enumerateAttribute(.font, in: NSRange(location: 0, length: text.count), options: []) { value, range, _ in
        #if os(macOS)
        if let font = value as? NSFont, font.fontDescriptor.symbolicTraits.contains(.bold) {
          var entity = MessageEntity()
          entity.type = .bold
          entity.offset = Int64(range.location)
          entity.length = Int64(range.length)
          entities.append(entity)
        }
        #elseif os(iOS)
        if let font = value as? UIFont, font.fontDescriptor.symbolicTraits.contains(.traitBold) {
          var entity = MessageEntity()
          entity.type = .bold
          entity.offset = Int64(range.location)
          entity.length = Int64(range.length)
          entities.append(entity)
        }
        #endif
      }

    // Sort entities by offset
    entities.sort { $0.offset < $1.offset }

    var messageEntities = MessageEntities()
    messageEntities.entities = entities

    return (text: text, entities: messageEntities)
  }

  // MARK: - Helper Methods

  private static func createBoldFont(from font: PlatformFont) -> PlatformFont {
    #if os(macOS)
    return NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    #elseif os(iOS)
    return UIFont.boldSystemFont(ofSize: font.pointSize)
    #endif
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
