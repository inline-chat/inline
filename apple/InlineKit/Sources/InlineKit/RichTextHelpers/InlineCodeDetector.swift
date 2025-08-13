#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

import Foundation
import InlineProtocol
import Logger

public struct InlineCodeRange {
  public let range: NSRange
  public let contentRange: NSRange // The range without the ` markers
  public let content: String
}

/// Handles `code` pattern detection and conversion to formatted text
/// Note: For entity extraction and application, use ProcessEntities from TextProcessing module
public class InlineCodeDetector {
  private let log = Log.scoped("InlineCodeDetector")

  public init() {}

  /// Detects `code` text patterns and applies formatting
  public func processInlineCode(in attributedText: NSAttributedString, outgoing: Bool = false) -> NSAttributedString {
    let text = attributedText.string
    let mutableAttributedText = attributedText.mutableCopy() as! NSMutableAttributedString

    // Find all `text` patterns
    let codeRanges = findInlineCodeRanges(in: text)

    // Process ranges in reverse order to maintain correct indices
    for codeRange in codeRanges.reversed() {
      // Replace `text` with text and apply inline code formatting
      let codeText = codeRange.content
      let codeAttributes = createInlineCodeAttributes(
        from: mutableAttributedText.attributes(
          at: codeRange.range.location,
          effectiveRange: nil
        ),
        outgoing: outgoing
      )

      let codeAttributedString = NSAttributedString(string: codeText, attributes: codeAttributes)
      mutableAttributedText.replaceCharacters(in: codeRange.range, with: codeAttributedString)
    }

    return mutableAttributedText.copy() as! NSAttributedString
  }

  /// Finds all `text` patterns in the given text
  private func findInlineCodeRanges(in text: String) -> [InlineCodeRange] {
    var ranges: [InlineCodeRange] = []
    let nsString = text as NSString

    // Use shared pattern from RichTextPatterns
    guard let regex = try? NSRegularExpression(pattern: RichTextPatterns.inlineCodePattern, options: []) else {
      log.error("Failed to create inline code regex")
      return ranges
    }

    let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))

    for match in matches {
      let fullRange = match.range // Full `text` range
      let contentRange = match.range(at: 1) // Just the text part

      if contentRange.location != NSNotFound {
        let content = nsString.substring(with: contentRange)

        ranges.append(InlineCodeRange(
          range: fullRange,
          contentRange: contentRange,
          content: content
        ))

        log.trace("Found inline code: '\(content)' at range \(fullRange)")
      }
    }

    return ranges
  }

  /// Creates inline code attributes based on existing attributes
  private func createInlineCodeAttributes(
    from existingAttributes: [NSAttributedString.Key: Any],
    outgoing: Bool
  ) -> [NSAttributedString.Key: Any] {
    var attributes = existingAttributes

    // Set monospace font using shared utility
    #if os(macOS)
    if let existingFont = existingAttributes[.font] as? NSFont {
      attributes[.font] = RichTextPatterns.createMonospaceFont(from: existingFont)
    } else {
      attributes[.font] = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }
    #elseif os(iOS)
    if let existingFont = existingAttributes[.font] as? UIFont {
      attributes[.font] = RichTextPatterns.createMonospaceFont(from: existingFont)
    } else {
      attributes[.font] = UIFont.monospacedSystemFont(ofSize: 17, weight: .regular)
    }
    #endif

    // No background color for inline code - only monospace font
    // Text color remains the same as the surrounding text

    return attributes
  }


  /// Check if there's an active inline code span at the cursor position
  public func detectInlineCodeAt(cursorPosition: Int, in attributedText: NSAttributedString) -> InlineCodeRange? {
    let text = attributedText.string
    guard cursorPosition <= text.count else {
      return nil
    }

    let codeRanges = findInlineCodeRanges(in: text)
    
    // Check if cursor is within any code range
    for codeRange in codeRanges {
      if NSLocationInRange(cursorPosition, codeRange.range) {
        return codeRange
      }
    }
    
    return nil
  }

  /// Escape inline code formatting at cursor position (for Enter key behavior)
  public func escapeInlineCode(
    in attributedText: NSAttributedString,
    at cursorPosition: Int
  ) -> (newAttributedText: NSAttributedString, newCursorPosition: Int)? {
    
    guard let codeRange = detectInlineCodeAt(cursorPosition: cursorPosition, in: attributedText) else {
      return nil
    }

    let mutableText = attributedText.mutableCopy() as! NSMutableAttributedString
    let originalContent = codeRange.content
    let backtickText = "`\(originalContent)`"
    
    // Replace the styled code with backtick format
    let plainAttributes = mutableText.attributes(at: codeRange.range.location, effectiveRange: nil)
    var escapedAttributes = plainAttributes
    
    // Remove code-specific formatting
    escapedAttributes.removeValue(forKey: .backgroundColor)
    #if os(macOS)
    if let existingFont = plainAttributes[.font] as? NSFont {
      escapedAttributes[.font] = NSFont.systemFont(ofSize: existingFont.pointSize)
    }
    escapedAttributes[.foregroundColor] = NSColor.labelColor
    #elseif os(iOS)
    if let existingFont = plainAttributes[.font] as? UIFont {
      escapedAttributes[.font] = UIFont.systemFont(ofSize: existingFont.pointSize)
    }
    escapedAttributes[.foregroundColor] = UIColor.label
    #endif
    
    let escapedString = NSAttributedString(string: backtickText, attributes: escapedAttributes)
    mutableText.replaceCharacters(in: codeRange.range, with: escapedString)
    
    let newCursorPosition = codeRange.range.location + backtickText.count
    
    return (mutableText.copy() as! NSAttributedString, newCursorPosition)
  }
}