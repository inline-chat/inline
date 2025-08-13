import Foundation

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Shared patterns and utilities for rich text processing
public enum RichTextPatterns {
  
  // MARK: - Regex Patterns
  
  /// Pattern for **bold** text: matches **text** (non-greedy)
  public static let boldPattern = #"\*\*([^*]+?)\*\*"#
  
  /// Pattern for `inline code`: matches `text` (non-greedy, no newlines)
  public static let inlineCodePattern = #"`([^`\n]+?)`"#
  
  // MARK: - Cursor Position Calculation
  
  /// Calculates new cursor position after rich text pattern processing
  /// - Parameters:
  ///   - originalText: Text before processing
  ///   - processedText: Text after processing
  ///   - originalCursor: Original cursor position
  /// - Returns: New cursor position accounting for removed markdown characters
  public static func calculateNewCursorPosition(
    originalText: String,
    processedText: String,
    originalCursor: Int
  ) -> Int {
    let textBeforeCursor = String(originalText.prefix(originalCursor))
    var removedCharacters = 0
    
    // Count **bold** patterns that were processed before the cursor
    if let boldRegex = try? NSRegularExpression(pattern: boldPattern, options: []) {
      let boldMatches = boldRegex.matches(
        in: textBeforeCursor,
        options: [],
        range: NSRange(location: 0, length: textBeforeCursor.count)
      )
      // Each **bold** pattern removes 4 characters (** at start and end)
      removedCharacters += boldMatches.count * 4
    }
    
    // Count `code` patterns that were processed before the cursor
    if let codeRegex = try? NSRegularExpression(pattern: inlineCodePattern, options: []) {
      let codeMatches = codeRegex.matches(
        in: textBeforeCursor,
        options: [],
        range: NSRange(location: 0, length: textBeforeCursor.count)
      )
      // Each `code` pattern removes 2 characters (` at start and end)
      removedCharacters += codeMatches.count * 2
    }
    
    return max(0, originalCursor - removedCharacters)
  }
  
  // MARK: - Font Utilities
  
  #if os(macOS)
  /// Creates a bold font from an existing font (macOS)
  public static func createBoldFont(from font: NSFont) -> NSFont {
    return NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
  }
  
  /// Creates a monospace font from an existing font (macOS) - one size smaller
  public static func createMonospaceFont(from font: NSFont) -> NSFont {
    let smallerSize = max(font.pointSize - 1, 9) // Minimum 9pt font
    return NSFont.monospacedSystemFont(ofSize: smallerSize, weight: .regular)
  }
  
  /// Checks if a font has monospace traits (macOS)
  public static func isMonospaceFont(_ font: NSFont) -> Bool {
    return font.fontDescriptor.symbolicTraits.contains(.monoSpace)
  }
  
  #elseif os(iOS)
  /// Creates a bold font from an existing font (iOS)
  public static func createBoldFont(from font: UIFont) -> UIFont {
    return UIFont.boldSystemFont(ofSize: font.pointSize)
  }
  
  /// Creates a monospace font from an existing font (iOS) - one size smaller
  public static func createMonospaceFont(from font: UIFont) -> UIFont {
    let smallerSize = max(font.pointSize - 1, 9) // Minimum 9pt font
    return UIFont.monospacedSystemFont(ofSize: smallerSize, weight: .regular)
  }
  
  /// Checks if a font has monospace traits (iOS)
  public static func isMonospaceFont(_ font: UIFont) -> Bool {
    return font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
  }
  
  #endif
}