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

  /// Standard URL detector for common protocols
  private static let standardDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

  /// Whitelisted TLDs that should be detected as links
  /// These are modern TLDs that might not be recognized by NSDataDetector
  private static let whitelistedTLDs: Set<String> = [
    "shop", "chat", "info", "app", "dev", "io", "ai", "co", "me", "tv", "fm", "ly", "to", "be", "cc", "gg", "ml", "tk",
    "ga", "cf", "gq", "so", "cm", "cd", "cg", "td", "ne", "bf", "ci", "sn", "gn", "gw", "mr", "ml", "bi", "rw", "km",
    "dj", "sc", "mu", "sz", "ls", "bw", "na", "zm", "mw", "zw", "ao", "mz", "mg", "yt", "re", "pf", "nc", "vu", "fj",
    "pg", "sb", "ki", "tv", "nr", "pw", "fm", "mh", "ws", "to", "ck", "nu", "tk", "nz", "au", "fj", "pg", "sb", "ki",
    "tv", "nr", "pw", "fm", "mh", "ws", "to", "ck", "nu", "tk",
  ]

  /// Regex pattern for detecting URLs with whitelisted TLDs
  /// This pattern matches URLs that start with http/https and have a whitelisted TLD
  private static let whitelistedTLDRegex: NSRegularExpression = {
    let tlds = whitelistedTLDs.joined(separator: "|")
    let pattern = "https?://[\\w.-]+\\.(\(tlds))\\b"
    return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
  }()

  /// Regex pattern for detecting bare domains with whitelisted TLDs (without protocol)
  /// This pattern matches domains like "shopline.shop" or "inline.chat" or "x.ai"
  private static let bareDomainRegex: NSRegularExpression = {
    let tlds = whitelistedTLDs.joined(separator: "|")
    let pattern = "\\b[\\w-]+\\.(\(tlds))\\b"
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

    // First, detect standard URLs using NSDataDetector
    if let standardMatches = detectStandardLinks(in: text) {
      log.debug("🔍 Standard detector found \(standardMatches.count) matches")
      for match in standardMatches {
        matches.append(match)
        handledRanges.insert(match.range)
      }
    }

    // Then detect whitelisted TLD URLs that might have been missed
    let whitelistedMatches = detectWhitelistedTLDLinks(in: text, excluding: handledRanges)
    log.debug("🔍 Whitelisted TLD detector found \(whitelistedMatches.count) matches")
    matches.append(contentsOf: whitelistedMatches)

    // Finally detect bare domains with whitelisted TLDs
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

    for match in matches {
      var attributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: linkColor,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
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

  /// Detects standard URLs using NSDataDetector
  private func detectStandardLinks(in text: String) -> [LinkMatch]? {
    guard let detector = Self.standardDetector else { return nil }

    let range = NSRange(location: 0, length: text.utf16.count)
    let matches = detector.matches(in: text, options: [], range: range)

    return matches.compactMap { match in
      guard let url = match.url else { return nil }

      // Validate that this is actually a URL we want to detect
      guard isValidURL(url) else { return nil }

      return LinkMatch(
        range: match.range,
        url: url,
        isWhitelistedTLD: false
      )
    }
  }

  /// Detects URLs with whitelisted TLDs that might have been missed by NSDataDetector
  private func detectWhitelistedTLDLinks(in text: String, excluding handledRanges: Set<NSRange>) -> [LinkMatch] {
    let range = NSRange(location: 0, length: text.utf16.count)
    let matches = Self.whitelistedTLDRegex.matches(in: text, options: [], range: range)

    log.debug("🔍 Whitelisted TLD regex found \(matches.count) matches in text: '\(text)'")

    return matches.compactMap { match in
      // Skip if this range overlaps with already handled ranges
      let overlaps = handledRanges.contains { NSIntersectionRange($0, match.range).length > 0 }
      guard !overlaps else {
        log.debug("🔍 Skipping overlapping range: \(match.range)")
        return nil
      }

      let urlString = (text as NSString).substring(with: match.range)
      log.debug("🔍 Found whitelisted TLD URL: '\(urlString)' at range \(match.range)")
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
