#if os(macOS)
import AppKit
public typealias PlatformColor = NSColor
#elseif os(iOS)
import UIKit
public typealias PlatformColor = UIColor
#endif

/// Centralized color configuration for rich text elements
public struct RichTextColors {
  
  // MARK: - Color Providers
  
  /// Provides inline code background color based on message direction
  /// - Parameter outgoing: Whether the message is outgoing
  /// - Returns: Transparent background (no background for inline code)
  public static func inlineCodeBackgroundColor(outgoing: Bool) -> PlatformColor {
    // No background color for inline code - just monospace font
    #if os(macOS)
    return NSColor.clear
    #elseif os(iOS)
    return UIColor.clear
    #endif
  }
  
  /// Provides inline code text color based on message direction
  /// - Parameter outgoing: Whether the message is outgoing
  /// - Returns: Appropriate text color for inline code
  public static func inlineCodeTextColor(outgoing: Bool) -> PlatformColor {
    if outgoing {
      // White text for outgoing messages
      #if os(macOS)
      return NSColor.white
      #elseif os(iOS)
      return UIColor.white
      #endif
    } else {
      // System label color for incoming messages (adapts to theme)
      #if os(macOS)
      return NSColor.labelColor
      #elseif os(iOS)
      return UIColor.label
      #endif
    }
  }
  
  /// Provides mention color based on message direction
  /// - Parameter outgoing: Whether the message is outgoing
  /// - Returns: Appropriate color for mentions
  public static func mentionColor(outgoing: Bool) -> PlatformColor {
    if outgoing {
      #if os(macOS)
      return NSColor.white
      #elseif os(iOS)
      return UIColor.white
      #endif
    } else {
      #if os(macOS)
      return NSColor.systemBlue
      #elseif os(iOS)
      return UIColor.systemBlue
      #endif
    }
  }
  
  /// Provides link color based on message direction
  /// - Parameter outgoing: Whether the message is outgoing
  /// - Returns: Appropriate color for links
  public static func linkColor(outgoing: Bool) -> PlatformColor {
    if outgoing {
      #if os(macOS)
      return NSColor.white
      #elseif os(iOS)
      return UIColor.white
      #endif
    } else {
      // On iOS, we'll use theme accent color (this should be provided externally)
      // For now, fallback to system blue for consistency
      #if os(macOS)
      return NSColor.linkColor
      #elseif os(iOS)
      return UIColor.systemBlue // This could be made theme-aware
      #endif
    }
  }
}