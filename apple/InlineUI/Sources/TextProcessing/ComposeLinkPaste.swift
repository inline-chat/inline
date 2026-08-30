import Foundation
import InlineKit

public enum ComposeLinkPaste {
  public static func selectionAfterApplyingLink(to range: NSRange) -> NSRange {
    NSRange(location: range.location + range.length, length: 0)
  }

  public static func normalizedURLString(from text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let matches = LinkDetector.shared.detectLinks(in: trimmed)
    guard matches.count == 1, let match = matches.first else { return nil }

    let fullRange = NSRange(location: 0, length: (trimmed as NSString).length)
    guard NSEqualRanges(match.range, fullRange) else { return nil }
    guard LinkDetector.isSupportedLinkURL(match.url) else { return nil }

    return match.url.absoluteString
  }

  public static func normalizedURLString(from url: URL) -> String? {
    normalizedURLString(from: url.absoluteString)
  }

  /// Detect only literal URLs, preserving explicit links, semantic entities and code.
  public static func links(in text: NSAttributedString, range: NSRange) -> [LinkMatch] {
    guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
          range.location <= text.length, range.length <= text.length - range.location
    else { return [] }
    let matches = LinkDetector.shared.detectLinks(in: (text.string as NSString).substring(with: range))
    guard !matches.isEmpty else { return [] }
    let protectedSyntax = backtickRanges(in: text.string) + ProcessEntities.markdownLinkRanges(in: text.string)
    return matches.compactMap { match in
      let fullRange = NSRange(location: range.location + match.range.location, length: match.range.length)
      guard !protectedSyntax.contains(where: { NSIntersectionRange($0, fullRange).length > 0 }) else { return nil }
      var isProtected = false
      text.enumerateAttributes(in: fullRange) { attributes, _, stop in
        if attributes[.inlineCode] != nil || attributes[.preCode] != nil
          || attributes[NSAttributedString.Key("richTextMath")] != nil
          || attributes[.threadLink] != nil
          || attributes[.mentionUserId] != nil || attributes[.mentionAgentId] != nil
          || attributes[.mentionGroupId] != nil || attributes[.botCommand] != nil
        {
          isProtected = true
        }
        if let link = attributes[.link] {
          let target = (link as? URL)?.absoluteString ?? (link as? String)
          if target != match.url.absoluteString { isProtected = true }
        }
        if isProtected { stop.pointee = true }
      }
      guard !isProtected else { return nil }
      return LinkMatch(range: fullRange, url: match.url, isWhitelistedTLD: match.isWhitelistedTLD)
    }
  }

  public static func selectionAfterReplacing(_ range: NSRange, length: Int, selection: NSRange) -> NSRange {
    if selection.location >= NSMaxRange(range) {
      return NSRange(location: selection.location + length - range.length, length: selection.length)
    }
    if NSMaxRange(selection) <= range.location { return selection }
    return NSRange(location: range.location + length, length: 0)
  }

  private static let backticks = try! NSRegularExpression(pattern: "`+")

  private static func backtickRanges(in text: String) -> [NSRange] {
    let source = text as NSString
    var opening: NSRange?
    var ranges: [NSRange] = []
    for match in backticks.matches(in: text, range: NSRange(location: 0, length: source.length)) {
      if match.range.location > 0, source.character(at: match.range.location - 1) == 92 { continue }
      if let start = opening {
        if match.range.length == start.length {
          ranges.append(NSRange(location: start.location, length: NSMaxRange(match.range) - start.location))
          opening = nil
        }
      } else {
        opening = match.range
      }
    }
    if let opening { ranges.append(NSRange(location: opening.location, length: source.length - opening.location)) }
    return ranges
  }
}
