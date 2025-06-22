import Foundation
import InlineKit
import InlineProtocol

public class ProcessEntities {
  /// Converts text and an array of entities to
  public static func toAttributedString(
    text: String,
    entities: MessageEntities?,
    attributes: [NSAttributedString.Key: Any]
  ) -> NSAttributedString {
    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: attributes,
    )

    guard let entities else {
      return attributedString
    }

    for entity in entities.entities {
      if entity.type == .mention, case let .mention(mention) = entity.entity {
        let range = NSRange(location: Int(entity.offset), length: Int(entity.length))

        // Validate range is within bounds
        if range.location >= 0, range.location + range.length <= text.utf16.count {
          attributedString.addAttributes([
            .foregroundColor: mentionColor,
            // .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
            .link: "inline://user/\(mention.userID)", // Custom URL scheme for mentions
          ], range: range)
        }
      }
    }

    return attributedString
  }
}
