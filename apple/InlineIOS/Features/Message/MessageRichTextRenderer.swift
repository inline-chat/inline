import UIKit

/// Utility class for mention colors in iOS message bubbles
/// This matches the macOS implementation exactly
class MessageRichTextRenderer {
  /// Gets the appropriate mention color based on message direction
  /// - Parameter outgoing: Whether the message is outgoing
  /// - Returns: The color to use for mentions (white for outgoing, blue for incoming)
  static func mentionColor(for outgoing: Bool) -> UIColor {
    if outgoing {
      UIColor.white
    } else {
      ThemeManager.shared.selected.accent
    }
  }

  /// Gets the appropriate link color based on message direction
  /// - Parameter outgoing: Whether the message is outgoing
  /// - Returns: The color to use for links
  static func linkColor(for outgoing: Bool) -> UIColor {
    if outgoing {
      UIColor.red
      // UIColor.white
    } else {
      UIColor.purple
      // ThemeManager.shared.selected.accent
    }
  }
}
