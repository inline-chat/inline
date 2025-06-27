#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

import Foundation
import InlineProtocol
import Logger

public struct BoldRange {
  public let range: NSRange
  public let contentRange: NSRange // The range without the ** markers
  public let content: String
}

public class BoldTextDetector {
  private let log = Log.scoped("BoldTextDetector")

  public init() {}

  /// Detects **bold** text patterns and applies formatting
  public func processBoldText(in attributedText: NSAttributedString) -> NSAttributedString {
    let text = attributedText.string
    let mutableAttributedText = attributedText.mutableCopy() as! NSMutableAttributedString

    // Find all **text** patterns
    let boldRanges = findBoldRanges(in: text)

    // Process ranges in reverse order to maintain correct indices
    for boldRange in boldRanges.reversed() {
      // Replace **text** with text and apply bold formatting
      let boldText = boldRange.content
      let boldAttributes = createBoldAttributes(from: mutableAttributedText.attributes(
        at: boldRange.range.location,
        effectiveRange: nil
      ))

      let boldAttributedString = NSAttributedString(string: boldText, attributes: boldAttributes)
      mutableAttributedText.replaceCharacters(in: boldRange.range, with: boldAttributedString)
    }

    return mutableAttributedText.copy() as! NSAttributedString
  }

  /// Finds all **text** patterns in the given text
  private func findBoldRanges(in text: String) -> [BoldRange] {
    var ranges: [BoldRange] = []
    let nsString = text as NSString

    // Regex pattern to match **text** (non-greedy)
    let pattern = #"\*\*([^*]+?)\*\*"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
      log.error("Failed to create bold text regex")
      return ranges
    }

    let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))

    for match in matches {
      let fullRange = match.range // Full **text** range
      let contentRange = match.range(at: 1) // Just the text part

      if contentRange.location != NSNotFound {
        let content = nsString.substring(with: contentRange)

        ranges.append(BoldRange(
          range: fullRange,
          contentRange: contentRange,
          content: content
        ))

        log.trace("Found bold text: '\(content)' at range \(fullRange)")
      }
    }

    return ranges
  }

  /// Creates bold attributes based on existing attributes
  private func createBoldAttributes(from existingAttributes: [NSAttributedString.Key: Any])
    -> [NSAttributedString.Key: Any]
  {
    var attributes = existingAttributes

    #if os(macOS)
    if let existingFont = existingAttributes[.font] as? NSFont {
      let boldFont = NSFontManager.shared.convert(existingFont, toHaveTrait: .boldFontMask)
      attributes[.font] = boldFont
    } else {
      attributes[.font] = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
    }
    #elseif os(iOS)
    if let existingFont = existingAttributes[.font] as? UIFont {
      let boldFont = UIFont.boldSystemFont(ofSize: existingFont.pointSize)
      attributes[.font] = boldFont
    } else {
      attributes[.font] = UIFont.boldSystemFont(ofSize: 17)
    }
    #endif

    return attributes
  }

  /// Extract bold entities from attributed text for sending
  public func extractBoldEntities(from attributedText: NSAttributedString) -> [MessageEntity] {
    var entities: [MessageEntity] = []
    let text = attributedText.string

    // Enumerate through the attributed string looking for bold fonts
    attributedText
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

    log.debug("Extracted \(entities.count) bold entities")
    return entities
  }

  /// Apply bold entities to attributed text (for displaying received messages)
  public func applyBoldEntities(
    _ entities: [MessageEntity],
    to attributedText: NSAttributedString
  ) -> NSAttributedString {
    let mutableAttributedText = attributedText.mutableCopy() as! NSMutableAttributedString

    for entity in entities where entity.type == .bold {
      let range = NSRange(location: Int(entity.offset), length: Int(entity.length))

      // Validate range is within bounds
      guard range.location >= 0, range.location + range.length <= attributedText.length else {
        log.warning("Bold entity range \(range) is out of bounds for text length \(attributedText.length)")
        continue
      }

      // Get existing attributes and make font bold
      let existingAttributes = mutableAttributedText.attributes(at: range.location, effectiveRange: nil)
      let boldAttributes = createBoldAttributes(from: existingAttributes)

      mutableAttributedText.addAttributes(boldAttributes, range: range)
    }

    return mutableAttributedText.copy() as! NSAttributedString
  }
}
