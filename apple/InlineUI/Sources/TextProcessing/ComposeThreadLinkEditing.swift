import Foundation
import InlineKit

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

public enum ComposeThreadLinkEditing {
  public static func affectedThreadLinkRanges(
    in attributedString: NSAttributedString,
    changeRange: NSRange
  ) -> [NSRange] {
    guard isValid(changeRange, length: attributedString.length) else { return [] }

    let fullRange = NSRange(location: 0, length: attributedString.length)
    var ranges: [NSRange] = []

    attributedString.enumerateAttribute(.threadLink, in: fullRange, options: []) { value, range, _ in
      guard value != nil, affects(changeRange, entityRange: range) else { return }
      ranges.append(range)
    }

    return ranges
  }

  public static func affectedThreadLinkRange(
    in attributedString: NSAttributedString,
    changeRange: NSRange
  ) -> NSRange? {
    affectedThreadLinkRanges(in: attributedString, changeRange: changeRange).first
  }

  public static func stripThreadLinks(
    in attributedString: NSMutableAttributedString,
    ranges: [NSRange],
    textColor: PlatformColor
  ) {
    for range in ranges {
      stripThreadLink(in: attributedString, range: range, textColor: textColor)
    }
  }

  public static func stripThreadLink(
    in attributedString: NSMutableAttributedString,
    range: NSRange,
    textColor: PlatformColor
  ) {
    let fullRange = NSRange(location: 0, length: attributedString.length)
    let safeRange = NSIntersectionRange(range, fullRange)
    guard safeRange.location != NSNotFound, safeRange.length > 0 else { return }

    attributedString.removeAttribute(.threadLink, range: safeRange)
    attributedString.removeAttribute(.foregroundColor, range: safeRange)
    attributedString.addAttribute(.foregroundColor, value: textColor, range: safeRange)

    #if os(macOS)
    attributedString.removeAttribute(.cursor, range: safeRange)
    #endif
  }

  public static func insertPlainText(
    _ text: String,
    into attributedString: NSAttributedString,
    selectedRange: NSRange,
    typingAttributes: [NSAttributedString.Key: Any],
    textColor: PlatformColor
  ) -> (attributedString: NSAttributedString, selectedRange: NSRange) {
    let mutable = NSMutableAttributedString(attributedString: attributedString)
    let range = clamped(selectedRange, length: mutable.length)
    let affectedRanges = affectedThreadLinkRanges(in: mutable, changeRange: range)
    stripThreadLinks(in: mutable, ranges: affectedRanges, textColor: textColor)

    let plain = NSAttributedString(
      string: text,
      attributes: plainTextAttributes(from: typingAttributes, textColor: textColor)
    )
    mutable.replaceCharacters(in: range, with: plain)

    let cursor = range.location + (text as NSString).length
    return (
      NSAttributedString(attributedString: mutable),
      NSRange(location: cursor, length: 0)
    )
  }

  public static func plainTextAttributes(
    from typingAttributes: [NSAttributedString.Key: Any],
    textColor: PlatformColor
  ) -> [NSAttributedString.Key: Any] {
    var attributes = typingAttributes
    attributes.removeValue(forKey: .threadLink)
    attributes.removeValue(forKey: .mentionUserId)
    attributes.removeValue(forKey: .link)
    attributes.removeValue(forKey: .emailAddress)
    attributes.removeValue(forKey: .phoneNumber)
    attributes[.foregroundColor] = textColor

    #if os(macOS)
    attributes.removeValue(forKey: .cursor)
    #endif

    return attributes
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

  private static func clamped(_ range: NSRange, length: Int) -> NSRange {
    if range.location == NSNotFound {
      return NSRange(location: length, length: 0)
    }

    let location = min(max(0, range.location), length)
    let safeLength = min(max(0, range.length), length - location)
    return NSRange(location: location, length: safeLength)
  }
}
