import UIKit
import TextProcessing

/// Utility class for mention colors in iOS message bubbles
/// This matches the macOS implementation exactly
class MessageRichTextRenderer {
  static func palette(for outgoing: Bool) -> ProcessEntities.Configuration.Palette {
    .init(
      primaryColor: primaryColor(for: outgoing),
      linkColor: linkColor(for: outgoing),
      secondaryColor: secondaryColor(for: outgoing)
    )
  }

  static func cacheKey(for outgoing: Bool) -> String {
    "\(ThemeManager.shared.selected.id)-\(outgoing ? "outgoing" : "incoming")"
  }

  static func primaryColor(for outgoing: Bool) -> UIColor {
    if outgoing {
      UIColor.white
    } else {
      ThemeManager.shared.selected.primaryTextColor ?? .label
    }
  }

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
      UIColor.white
    } else {
      ThemeManager.shared.selected.accent
    }
  }

  static func secondaryColor(for outgoing: Bool) -> UIColor {
    if outgoing {
      UIColor.white.withAlphaComponent(0.7)
    } else {
      ThemeManager.shared.selected.secondaryTextColor ?? .secondaryLabel
    }
  }
}
