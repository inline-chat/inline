import UIKit
import InlineKit

/// Utility class for rich text colors in iOS message bubbles
/// Provides theme-aware colors for different message elements
class MessageRichTextRenderer {
  /// Gets the appropriate mention color based on message direction
  /// - Parameter outgoing: Whether the message is outgoing
  /// - Returns: The color to use for mentions (white for outgoing, theme accent for incoming)
  static func mentionColor(for outgoing: Bool) -> UIColor {
    if outgoing {
      return RichTextColors.mentionColor(outgoing: outgoing)
    } else {
      return ThemeManager.shared.selected.accent
    }
  }

  /// Gets the appropriate link color based on message direction
  /// - Parameter outgoing: Whether the message is outgoing
  /// - Returns: The color to use for links
  static func linkColor(for outgoing: Bool) -> UIColor {
    if outgoing {
      return RichTextColors.linkColor(outgoing: outgoing)
    } else {
      return ThemeManager.shared.selected.accent
    }
  }

  /// Gets the appropriate inline code background color based on message direction
  /// - Parameter outgoing: Whether the message is outgoing
  /// - Returns: The background color to use for inline code
  static func inlineCodeBackgroundColor(for outgoing: Bool) -> UIColor {
    return RichTextColors.inlineCodeBackgroundColor(outgoing: outgoing)
  }

  /// Gets the appropriate inline code text color based on message direction
  /// - Parameter outgoing: Whether the message is outgoing
  /// - Returns: The text color to use for inline code
  static func inlineCodeTextColor(for outgoing: Bool) -> UIColor {
    return RichTextColors.inlineCodeTextColor(outgoing: outgoing)
  }
}
