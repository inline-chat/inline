import Foundation
import InlineKit
import InlineProtocol

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Semantic styles are separate from incidental link decoration and code backgrounds.
public enum InlineTextStyle: CaseIterable, Sendable {
  case underline, strikethrough, highlight

  public var marker: NSAttributedString.Key {
    switch self {
      case .underline: .richTextUnderline
      case .strikethrough: .richTextStrikethrough
      case .highlight: .richTextHighlight
    }
  }

  public var entityType: MessageEntity.TypeEnum {
    switch self {
      case .underline: .underline
      case .strikethrough: .strikethrough
      case .highlight: .highlight
    }
  }

  public var attributes: [NSAttributedString.Key: Any] {
    var result: [NSAttributedString.Key: Any] = [marker: true]
    switch self {
      case .underline:
        result[.underlineStyle] = NSUnderlineStyle.single.rawValue
      case .strikethrough:
        result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
      case .highlight:
        // Keep the existing foreground color and use the platform's adaptive yellow.
        result[.backgroundColor] = PlatformColor.systemYellow.withAlphaComponent(0.28)
    }
    return result
  }

  public func isEnabled(in text: NSAttributedString, range: NSRange) -> Bool {
    guard range.length > 0 else { return false }
    var enabled = true
    text.enumerateAttribute(marker, in: range) { value, _, stop in
      if value as? Bool != true {
        enabled = false
        stop.pointee = true
      }
    }
    return enabled
  }

  public func settingEnabled(_ enabled: Bool, in current: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
    var result = current
    if enabled {
      result.merge(attributes, uniquingKeysWith: { _, new in new })
    } else {
      for key in attributes.keys { result.removeValue(forKey: key) }
    }
    return result
  }

  public func setEnabled(_ enabled: Bool, in text: NSMutableAttributedString, range: NSRange) {
    if enabled {
      text.addAttributes(attributes, range: range)
    } else {
      for key in attributes.keys { text.removeAttribute(key, range: range) }
    }
  }

  /// Restores intentional styles after link styling or paste normalization.
  public static func reapply(to text: NSMutableAttributedString) {
    let fullRange = NSRange(location: 0, length: text.length)
    for style in allCases {
      text.enumerateAttribute(style.marker, in: fullRange) { value, range, _ in
        guard value as? Bool == true else { return }
        text.addAttributes(style.attributes, range: range)
      }
    }
  }
}
