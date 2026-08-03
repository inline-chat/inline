import Foundation
import InlineKit

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

public enum ComposeEntityEditing {
  public static func affectedMentionRanges(
    in attributedString: NSAttributedString,
    changeRange: NSRange
  ) -> [NSRange] {
    affectedRanges(
      in: attributedString,
      changeRange: changeRange,
      attributes: [.mentionUserId, .mentionGroupId]
    )
  }

  public static func affectedBotCommandRanges(
    in attributedString: NSAttributedString,
    changeRange: NSRange
  ) -> [NSRange] {
    affectedRanges(
      in: attributedString,
      changeRange: changeRange,
      attributes: [.botCommand]
    )
  }

  public static func stripMentions(
    in attributedString: NSMutableAttributedString,
    ranges: [NSRange],
    textColor: PlatformColor
  ) {
    strip(
      attributes: [.mentionUserId, .mentionGroupId],
      in: attributedString,
      ranges: ranges,
      textColor: textColor
    )
  }

  public static func stripBotCommands(
    in attributedString: NSMutableAttributedString,
    ranges: [NSRange],
    textColor: PlatformColor
  ) {
    strip(
      attributes: [.botCommand, .botCommandTargetUserId],
      in: attributedString,
      ranges: ranges,
      textColor: textColor
    )
  }

  private static func affectedRanges(
    in attributedString: NSAttributedString,
    changeRange: NSRange,
    attributes: [NSAttributedString.Key]
  ) -> [NSRange] {
    guard isValid(changeRange, length: attributedString.length) else { return [] }

    let fullRange = NSRange(location: 0, length: attributedString.length)
    var ranges: [NSRange] = []

    for attribute in attributes {
      attributedString.enumerateAttribute(attribute, in: fullRange, options: []) { value, range, _ in
        guard value != nil,
              affects(changeRange, entityRange: range),
              !ranges.contains(range)
        else {
          return
        }
        ranges.append(range)
      }
    }

    return ranges.sorted { lhs, rhs in
      if lhs.location != rhs.location {
        return lhs.location < rhs.location
      }
      return lhs.length < rhs.length
    }
  }

  private static func strip(
    attributes: [NSAttributedString.Key],
    in attributedString: NSMutableAttributedString,
    ranges: [NSRange],
    textColor: PlatformColor
  ) {
    let fullRange = NSRange(location: 0, length: attributedString.length)
    for range in ranges {
      let safeRange = NSIntersectionRange(range, fullRange)
      guard safeRange.location != NSNotFound, safeRange.length > 0 else { continue }

      for attribute in attributes {
        attributedString.removeAttribute(attribute, range: safeRange)
      }
      attributedString.removeAttribute(.foregroundColor, range: safeRange)
      attributedString.addAttribute(.foregroundColor, value: textColor, range: safeRange)

      #if os(macOS)
      attributedString.removeAttribute(.cursor, range: safeRange)
      #endif
    }
  }

  private static func isValid(_ range: NSRange, length: Int) -> Bool {
    guard range.location != NSNotFound,
          range.location >= 0,
          range.location <= length,
          range.length >= 0
    else {
      return false
    }
    return NSMaxRange(range) <= length
  }

  private static func affects(_ changeRange: NSRange, entityRange: NSRange) -> Bool {
    if changeRange.length == 0 {
      return changeRange.location > entityRange.location &&
        changeRange.location < NSMaxRange(entityRange)
    }
    return NSIntersectionRange(changeRange, entityRange).length > 0
  }
}
