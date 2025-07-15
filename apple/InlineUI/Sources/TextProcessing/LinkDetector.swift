import Foundation
import Logger

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

public struct LinkMatch {
  public let range: NSRange
  public let url: URL
  public let isWhitelistedTLD: Bool
}

public final class LinkDetector: Sendable {
  private let log = Log.scoped("LinkDetector")

  // MARK: - Static Properties

  /// Shared instance for performance
  public static let shared = LinkDetector()

  // We removed the built-in `NSDataDetector` to rely fully on our own regular-expression-based detectors for
  // both performance and flexibility.

  /// Generic regex for detecting any http or https URL (supports very long paths and query strings)
  /// RFC 3986 unreserved + reserved characters are allowed after the scheme delimiter until a whitespace
  private static let fullURLRegex: NSRegularExpression = {
    // This pattern matches "http" or "https", followed by "://", then any combination of
    // unreserved (A–Z a–z 0–9 -._~) and reserved characters (:/?#[]@!$&'()*+,;=%) until it hits
    // a whitespace character. This intentionally excludes angle brackets and other punctuation
    // that typically terminates URLs in plain text.
    let pattern = "https?://[^\\s<>()\\[\\]{}\"']+"
    return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
  }()

  /// Whitelisted TLDs that should be detected as links
  /// These are modern TLDs that might not be recognized by NSDataDetector
  private static let whitelistedTLDs: Set<String> = [
    // Common legacy gTLDs
    "com", "net", "org", "edu", "gov", "mil", "int",

    // Popular generic + brand-new gTLDs
    "app", "blog", "biz", "cloud", "club", "dev", "digital", "live", "news", "online", "page", "site", "shop", "store", "tech", "top", "xyz", "chat",

    // Frequently used two-letter ccTLDs (selection)
    "ac", "ad", "ae", "af", "ag", "ai", "al", "am", "ao", "ar", "as", "at", "au", "aw", "az",
    "ba", "bb", "bd", "be", "bf", "bg", "bh", "bi", "bj", "bm", "bn", "bo", "br", "bs", "bt", "bw", "by", "bz",
    "ca", "cat", "cc", "cd", "cf", "cg", "ch", "ci", "ck", "cl", "cm", "cn", "co", "cr", "cu", "cv", "cw", "cx", "cy", "cz",
    "de", "dj", "dk", "dm", "do", "dz",
    "ec", "ee", "eg", "er", "es", "et", "eu",
    "fi", "fj", "fk", "fm", "fo", "fr",
    "ga", "gb", "gd", "ge", "gf", "gg", "gh", "gi", "gl", "gm", "gn", "gp", "gq", "gr", "gs", "gt", "gu", "gw", "gy",
    "hk", "hm", "hn", "hr", "ht", "hu",
    "id", "ie", "il", "im", "in", "io", "iq", "ir", "is", "it",
    "je", "jm", "jo", "jp",
    "ke", "kg", "kh", "ki", "km", "kn", "kp", "kr", "kw", "ky", "kz",
    "la", "lb", "lc", "li", "lk", "lr", "ls", "lt", "lu", "lv", "ly",
    "ma", "mc", "md", "me", "mg", "mh", "mk", "ml", "mm", "mn", "mo", "mp", "mq", "mr", "ms", "mt", "mu", "mv", "mw", "mx", "my", "mz",
    "na", "nc", "ne", "nf", "ng", "ni", "nl", "no", "np", "nr", "nu", "nz",
    "om",
    "pa", "pe", "pf", "pg", "ph", "pk", "pl", "pm", "pn", "pr", "ps", "pt", "pw", "py",
    "qa",
    "re", "ro", "rs", "ru", "rw",
    "sa", "sb", "sc", "sd", "se", "sg", "sh", "si", "sk", "sl", "sm", "sn", "so", "sr", "ss", "st", "su", "sv", "sx", "sy", "sz",
    "tc", "td", "tf", "tg", "th", "tj", "tk", "tl", "tm", "tn", "to", "tr", "tt", "tv", "tw", "tz",
    "ua", "ug", "uk", "us", "uy", "uz",
    "va", "vc", "ve", "vg", "vi", "vn", "vu",
    "wf", "ws",
    "ye", "yt",
    "za", "zm", "zw",
    // Short thematic gTLDs that can overlap with English words (risk of false positives is acceptable)
    "ai", "io", "me", "fm", "ly", "to",
  ]

  // Note: With the introduction of `fullURLRegex`, we no longer need a dedicated whitelisted TLD
  // regex for URLs that already include a protocol. We still keep bare-domain detection below.

  /// Regex pattern for detecting bare domains with whitelisted TLDs (without protocol)
  /// This pattern matches domains like "shopline.shop" or "inline.chat" or "x.ai"
  private static let bareDomainRegex: NSRegularExpression = {
    let tlds = whitelistedTLDs.joined(separator: "|")
    // Support multiple sub-domain components (e.g. bot.wanver.shop)
    let pattern = "\\b[\\w-]+(?:\\.[\\w-]+)*\\.(\(tlds))\\b"
    return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
  }()

  // MARK: - Initialization

  private init() {}

  // MARK: - Public Interface

  /// Detects all links in the given text and returns them as LinkMatch objects
  /// - Parameter text: The text to scan for links
  /// - Returns: Array of LinkMatch objects containing range, URL, and whether it's a whitelisted TLD
  public func detectLinks(in text: String) -> [LinkMatch] {
    guard !text.isEmpty else { return [] }

    log.debug("🔍 Starting link detection for text: '\(text)'")

    var matches: [LinkMatch] = []
    var handledRanges: Set<NSRange> = []

    // First, detect full http/https URLs using custom regex (handles very long or exotic URLs)
    let fullURLMatches = detectFullURLLinks(in: text, excluding: handledRanges)
    log.debug("🔍 Full URL detector found \(fullURLMatches.count) matches")
    matches.append(contentsOf: fullURLMatches)
    for match in fullURLMatches {
      handledRanges.insert(match.range)
    }

    // Finally, detect bare domains with whitelisted TLDs (e.g. "inline.chat")
    let bareDomainMatches = detectBareDomainLinks(in: text, excluding: handledRanges)
    log.debug("🔍 Bare domain detector found \(bareDomainMatches.count) matches")
    matches.append(contentsOf: bareDomainMatches)

    // Sort matches by range location to maintain order
    matches.sort { $0.range.location < $1.range.location }

    log.debug("🔍 Total detected links: \(matches.count)")
    return matches
  }

  /// Applies link styling to an attributed string
  /// - Parameters:
  ///   - attributedString: The attributed string to style
  ///   - linkColor: The color to use for links
  ///   - cursor: The cursor to use for links (macOS only)
  /// - Returns: Array of detected links with their ranges
  public func applyLinkStyling(
    to attributedString: NSMutableAttributedString,
    linkColor: PlatformColor,
    cursor: Any? = nil
  ) -> [LinkMatch] {
    let text = attributedString.string
    let matches = detectLinks(in: text)
    let underlineColor = linkColor

    for match in matches {
      var attributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: linkColor,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
        .underlineColor: underlineColor,
        .link: match.url,
      ]

      #if os(macOS)
      if let cursor {
        attributes[.cursor] = cursor
      }
      #endif

      attributedString.addAttributes(attributes, range: match.range)
    }

    return matches
  }

  // MARK: - Private Methods

  // Detects http/https URLs using custom regex (covers very long query strings and exotic cases)
  private func detectFullURLLinks(in text: String, excluding handledRanges: Set<NSRange>) -> [LinkMatch] {
    let nsText = text as NSString
    let searchRange = NSRange(location: 0, length: nsText.length)
    let matches = Self.fullURLRegex.matches(in: text, options: [], range: searchRange)

    return matches.compactMap { match in
      // Skip overlaps with already handled ranges
      let overlaps = handledRanges.contains { NSIntersectionRange($0, match.range).length > 0 }
      guard !overlaps else { return nil }

      var urlString = nsText.substring(with: match.range)

      // Trim common trailing punctuation that should not be part of the URL (e.g. ",", ")", ".")
      let trailingPunctuation = CharacterSet(charactersIn: ",.!?:;)]}'\"")
      while let lastUnicodeScalar = urlString.unicodeScalars.last,
            trailingPunctuation.contains(lastUnicodeScalar) {
        urlString.removeLast()
      }

      // Adjust range length if we trimmed characters
      let trimmedCount = match.range.length - urlString.utf16.count
      let adjustedRange = NSRange(location: match.range.location, length: match.range.length - trimmedCount)

      guard let url = URL(string: urlString), isValidURL(url) else {
        return nil
      }

      // Determine if this URL ends with a whitelisted TLD
      var isWhitelisted = false
      if let host = url.host?.lowercased(),
         let tld = host.components(separatedBy: ".").last {
        isWhitelisted = Self.whitelistedTLDs.contains(tld)
      }

      return LinkMatch(range: adjustedRange, url: url, isWhitelistedTLD: isWhitelisted)
    }
  }

  // Removed `detectStandardLinks` because we no longer rely on `NSDataDetector`.

  /// Detects URLs with whitelisted TLDs that might have been missed by NSDataDetector
  // NOTE: Obsolete – kept for potential future specialised handling. Currently unused.
  private func detectWhitelistedTLDLinks(in text: String, excluding handledRanges: Set<NSRange>) -> [LinkMatch] { [] }

  /// Detects bare domains with whitelisted TLDs (without protocol)
  private func detectBareDomainLinks(in text: String, excluding handledRanges: Set<NSRange>) -> [LinkMatch] {
    let range = NSRange(location: 0, length: text.utf16.count)
    let matches = Self.bareDomainRegex.matches(in: text, options: [], range: range)

    log.debug("🔍 Bare domain regex found \(matches.count) matches in text: '\(text)'")

    return matches.compactMap { match in
      // Skip if this range overlaps with already handled ranges
      let overlaps = handledRanges.contains { NSIntersectionRange($0, match.range).length > 0 }
      guard !overlaps else {
        log.debug("🔍 Skipping overlapping range: \(match.range)")
        return nil
      }

      // Skip domains that are part of an email address (preceded by "@")
      if match.range.location > 0 {
        let precedingRange = NSRange(location: match.range.location - 1, length: 1)
        let precedingChar = (text as NSString).substring(with: precedingRange)
        if precedingChar == "@" {
          log.debug("🔍 Skipping domain preceded by @ (likely an email address): \(match.range)")
          return nil
        }
      }

      let domainString = (text as NSString).substring(with: match.range)
      log.debug("🔍 Found bare domain: '\(domainString)' at range \(match.range)")

      // Add https:// protocol to make it a valid URL
      let urlString = "https://\(domainString)"
      guard let url = URL(string: urlString) else {
        log.debug("🔍 Failed to create URL from: '\(urlString)'")
        return nil
      }

      return LinkMatch(
        range: match.range,
        url: url,
        isWhitelistedTLD: true
      )
    }
  }

  /// Validates if a URL should be detected as a link
  private func isValidURL(_ url: URL) -> Bool {
    // Skip file:// URLs as they're not web links
    if url.scheme == "file" {
      return false
    }

    // Skip data: URLs as they're not web links
    if url.scheme == "data" {
      return false
    }

    // Skip mailto: URLs as they're handled separately
    if url.scheme == "mailto" {
      return false
    }

    // Skip tel: URLs as they're handled separately
    if url.scheme == "tel" {
      return false
    }

    return true
  }

  // MARK: - Testing

  /// Test method to verify regexes are working
  public func testRegexes() {
    let testCases = [
      "https://example.shop",
      "http://test.chat",
      "shopline.shop",
      "inline.chat",
      "https://example.com",
      "Regular text without links",
    ]

    log.debug("🔍 Testing regexes...")

    for testCase in testCases {
      let matches = detectLinks(in: testCase)
      log.debug("🔍 Test case '\(testCase)': \(matches.count) links detected")
      for match in matches {
        log.debug("🔍   - URL: \(match.url), range: \(match.range), whitelisted: \(match.isWhitelistedTLD)")
      }
    }
  }
}
