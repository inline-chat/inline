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
  /// Converts text and an array of entities to
  ///
  public static func toAttributedString(
    text: String,
    entities: MessageEntities?,
    configuration: Configuration,
  ) -> NSMutableAttributedString {
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [
        .font: configuration.font,
        .foregroundColor: configuration.textColor,
      ],
    )

    guard let entities else {
      return attributedString
    }

    for entity in entities.entities {
      if entity.type == .mention, case let .mention(mention) = entity.entity {
        let range = NSRange(location: Int(entity.offset), length: Int(entity.length))

        // Validate range is within bounds
        if range.location >= 0, range.location + range.length <= text.utf16.count {
          if configuration.convertMentionsToLink {
            attributedString.addAttributes([
              .foregroundColor: configuration.linkColor,
              // TODO: Enable on macOS
              // .cursor: NSCursor.pointingHand,
              .link: "inline://user/\(mention.userID)", // Custom URL scheme for mentions
            ], range: range)
          } else {
            attributedString.addAttributes([
              .foregroundColor: configuration.linkColor,
            ], range: range)
          }
        }
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

    // Extract mention nodes from text
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

    var messageEntities = MessageEntities()
    messageEntities.entities = entities

    return (text: text, entities: messageEntities)
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
