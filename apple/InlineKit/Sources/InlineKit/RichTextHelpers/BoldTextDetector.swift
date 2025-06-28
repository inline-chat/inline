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

/// Handles **bold** pattern detection and conversion to formatted text
/// Note: For entity extraction and application, use ProcessEntities from TextProcessing module
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
}
